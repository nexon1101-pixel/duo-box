import Combine
import Foundation
import GuestHostCore
import Metal
import SwiftUI
import UIKit

// Android（Kernarium の GuestHost）を 1 回起動して見届けるだけの薄い実装。
// 本元 Andarium/Live/LiveRuntime.swift の launch / runGuest / stopGuest / finished の最小版。
// 入力・向き・バックグラウンド・JIT は段5以降。ここでは gadget（解釈実行）で起動する。

/// 起動前の確認で止めた理由。画面にそのまま出す。
struct AndroidStartError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AndroidRunner: ObservableObject {
    enum Phase: Equatable {
        /// 画面の大きさが決まるのを待っている
        case waiting
        /// ランタイムを回し始めた。ゲストの画面が点くまで
        case booting
        /// ゲストの画面が点いた
        case running
        /// 戻る操作で停止を頼んだ。ランタイムが返るのを待つ
        case stopping
        /// 起動できなかった、または異常終了した。理由つき
        case failed(String)
        /// ゲストが自分で電源を切った、または停止が済んだ
        case ended(byUser: Bool)
    }

    @Published private(set) var phase = Phase.waiting
    /// ゲストのコンソール出力の末尾。起動中の表示と、失敗理由の補助に使う
    @Published private(set) var consoleTail = ""

    /// 本元 LiveRuntime.androidFlavor と同じ値（Android 用ランタイムを選ぶ）
    private static let androidFlavor: UInt32 = 1
    /// 本元と同じバンドル内フォルダ名（project.yml が ../vendor/kernarium/.build/andarium-system を入れる）
    private static let systemFolderName = "andarium-system"
    private static let consoleTailLimit = 4096

    private var runStop: RunStop?
    private var started = false
    private let stopQueue = DispatchQueue(label: "duo-box.android.stop")
    private var displayPoll: DispatchSourceTimer?

    // MARK: 起動

    /// 表示ビューのレイアウトごとに呼ばれる。最初に大きさが決まったときだけ起動する
    func viewDidLayout(_ view: GuestMetalView, _ geometry: GuestDisplayGeometry) {
        guard !started, phase == .waiting else { return }
        guard geometry.pixelSize.width > 0, geometry.pixelSize.height > 0 else { return }
        started = true
        do {
            try launch(view: view, geometry: geometry)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func launch(view: GuestMetalView, geometry: GuestDisplayGeometry) throws {
        // 1. 端末の確認（ゲストの描画は Metal 4 前提）
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
            throw AndroidStartError(message: "この端末は Metal 4 に対応していないため、Android を起動できません（A14 以降が必要）")
        }

        // 2. バンドル内のシステムイメージ（リリースのフォルダ）
        guard let release = Bundle.main.url(forResource: Self.systemFolderName, withExtension: nil) else {
            throw AndroidStartError(message: "アプリに Android のシステムイメージ（\(Self.systemFolderName)）が入っていません")
        }
        for file in ["release-manifest.json", "boot/kernel-command-line.txt",
                     "guest/partition-layout.json", "guest/system.img"] {
            guard FileManager.default.fileExists(atPath: release.appendingPathComponent(file).path) else {
                throw AndroidStartError(message: "システムイメージに \(file) がありません")
            }
        }

        // 3. ゲストのデータ置き場。Library/Guest/（Application Support は名前に空白があり、カーネルに渡せない）
        let library = try FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let guestDirectory = library.appendingPathComponent("Guest", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: guestDirectory, withIntermediateDirectories: true)
        } catch {
            throw AndroidStartError(message: "ゲストの保存先を作れませんでした: \(error.localizedDescription)")
        }
        let dataDisk = guestDirectory.appendingPathComponent("data.img")
        let sessionRecord = guestDirectory.appendingPathComponent("session.txt")
        for path in [release.path, dataDisk.path] where !Self.isUsableDiskPath(path) {
            throw AndroidStartError(message: "\(path) は空白・カンマ・コロン・引用符を含むため、ゲストのカーネルに渡せません")
        }

        // 4. ランタイムを読む
        guard kernarium_runtime_loader_select(Self.androidFlavor) == 0 else {
            throw AndroidStartError(message: "Android のランタイム（KRuntime_Android）を読み込めませんでした。框架が埋め込まれているか確認してください")
        }

        // 5. メモリと vCPU は本元の既定の求め方に従う
        let launchSet = kernarium_runtime_loader_launch_memory_set()
        let vcpus = UInt32(GuestProcessorLimit.vCPUs(physicalProcessorCount: ProcessInfo.processInfo.processorCount))
        let memoryMiB = kernarium_runtime_loader_default_guest_memory_mib(vcpus, launchSet)
        guard kernarium_runtime_loader_guest_memory_admitted(memoryMiB) != 0 else {
            let ceiling = kernarium_runtime_loader_guest_memory_ceiling_mib()
            throw AndroidStartError(message: "この端末ではゲストのメモリ \(memoryMiB) MiB を確保できません（上限 \(ceiling) MiB）")
        }

        // 6. 表示の大きさ
        let size = GuestInputCoordinateSpace.boundedDisplaySize(geometry.pixelSize)
        let width = UInt32(size.width.rounded(.down))
        let height = UInt32(size.height.rounded(.down))
        view.setGuestDisplay(width: width, height: height)
        let dotsPerInch = geometry.dotsPerInch
        let timeZone = TimeZone.current.identifier

        // 7. コンソールと再起動の通知（どちらもメインキューに届く）
        kernarium_runtime_loader_set_console_output_handler { [weak self] data in
            MainActor.assumeIsolated { self?.appendConsole(data) }
        }
        kernarium_runtime_loader_set_restart_handler { _, _ in }

        // 8. ランタイムを専用スレッドで回す（ゲストの寿命のあいだ戻らないので、メインでも協調プールでもない）
        let stop = RunStop()
        runStop = stop
        phase = .booting
        UIApplication.shared.isIdleTimerDisabled = true
        startDisplayPolling()
        let releasePath = release.path
        let dataPath = dataDisk.path
        let recordPath = sessionRecord.path
        let worker = Thread {
            // 起動前に停止が頼まれていたらランタイムに入らない（ランタイムは開始前の停止を捨てる）
            guard stop.enter() else {
                stop.end()
                Task { @MainActor in self.finished(result: 0) }
                return
            }
            let result = Self.runGuest(
                view: view, releasePath: releasePath, dataDiskPath: dataPath, sessionRecordPath: recordPath,
                width: width, height: height, dotsPerInch: dotsPerInch, memoryMiB: memoryMiB,
                processorCount: vcpus, timeZone: timeZone)
            stop.end()
            Task { @MainActor in self.finished(result: result) }
        }
        worker.name = "duo-box-android-runtime"
        worker.start()
    }

    /// 本元 LiveRuntime.runGuest の最小版。JIT・カメラ・触覚・adb 鍵は指定しない（0 / nil）
    private nonisolated static func runGuest(
        view: GuestMetalView, releasePath: String, dataDiskPath: String, sessionRecordPath: String,
        width: UInt32, height: UInt32, dotsPerInch: UInt32, memoryMiB: UInt32,
        processorCount: UInt32, timeZone: String
    ) -> Int32 {
        releasePath.withCString { release in
            dataDiskPath.withCString { dataDisk in
                sessionRecordPath.withCString { record in
                    timeZone.withCString { zone in
                        var request = kernarium_runtime_boot()
                        request.struct_size = UInt32(MemoryLayout<kernarium_runtime_boot>.size)
                        request.width = width
                        request.height = height
                        request.dots_per_inch = dotsPerInch
                        request.guest_memory_mib = memoryMiB
                        request.guest_processor_count = processorCount
                        request.android_boot_mode = UInt32(KERNARIUM_RUNTIME_ANDROID_BOOT_NORMAL)
                        request.auto_resize_guest = 1
                        request.android_data_disk_path = dataDisk
                        request.android_release_path = release
                        request.android_data_gib = 0 // リリースの既定の大きさ
                        let parameters = kernarium_runtime_loader_launch_memory_set()
                        request.gpu_budget_application_mib = parameters.application_mib
                        request.gpu_budget_engine_mib = parameters.engine_mib
                        request.gpu_budget_headroom_mib = parameters.headroom_mib
                        request.android_time_zone = zone
                        request.session_record_path = record
                        request.use_jit = 0 // gadget（解釈実行）。JIT は段6
                        return withUnsafePointer(to: &request) { kernarium_runtime_loader_run(view, $0) }
                    }
                }
            }
        }
    }

    // MARK: 停止

    /// 戻る操作。停止を頼み、ランタイムが返ったら `finished` が .ended にする。
    /// 起動前ならそのまま終わる
    func stop() {
        switch phase {
        case .waiting:
            phase = .ended(byUser: true)
        case .booting, .running:
            guard let stop = runStop else { return }
            phase = .stopping
            if stop.request() {
                // ゲストの書き戻しを先にしてからホストの停止。ランタイムが返るまで 1 秒おきに繰り返す
                GuestStopDelivery.deliver(
                    stop, on: stopQueue,
                    settle: { GuestStopDelivery.settleBeforeStop(for: stop, logPrefix: "DuoBox Android: ") },
                    request: { kernarium_runtime_loader_request_stop() })
            }
        case .stopping, .failed, .ended:
            break
        }
    }

    private func finished(result: Int32) {
        displayPoll?.cancel()
        displayPoll = nil
        kernarium_runtime_loader_set_console_output_handler(nil)
        kernarium_runtime_loader_set_restart_handler(nil)
        runStop = nil
        UIApplication.shared.isIdleTimerDisabled = false
        print("DuoBox Android: runtime returned \(result)")
        let byUser = phase == .stopping
        if result == 0 || byUser {
            phase = .ended(byUser: byUser)
        } else {
            fail(Self.describe(result: result))
        }
    }

    private func fail(_ reason: String) {
        print("DuoBox Android: \(reason)")
        phase = .failed(reason)
    }

    // MARK: 補助

    /// ゲストの画面が点いたら .booting → .running にする。1 秒おきに背景キューで確かめる
    private func startDisplayPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "duo-box.android.poll"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard kernarium_runtime_loader_guest_display_active() == 1 else { return }
            Task { @MainActor in
                guard let self, self.phase == .booting else { return }
                self.phase = .running
            }
        }
        displayPoll = timer
        timer.resume()
    }

    private func appendConsole(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        var tail = consoleTail + text
        if tail.count > Self.consoleTailLimit { tail = String(tail.suffix(Self.consoleTailLimit)) }
        consoleTail = tail
    }

    private nonisolated static func isUsableDiskPath(_ path: String) -> Bool {
        // 本元 AndariumCore.DiskPath.isUsable と同じ禁止文字（空白類・NBSP・" , :）
        let refused: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0xa0, 0x22, 0x2c, 0x3a]
        return !path.isEmpty && !path.utf8.contains { refused.contains($0) }
    }

    private nonisolated static func describe(result: Int32) -> String {
        switch result {
        case -100: return "ゲストが再起動を繰り返したため止めました（-100）"
        // 本元 darwin/api/include/uml/emulator.h の uml_emulator のエラー値の符号を反転したもの
        case -1: return "ランタイムが起動要求を受け付けませんでした（-1 INVALID_ARGUMENT。パス・サイズ・フィールドの不備）"
        case -2: return "メモリが足りず起動できませんでした（-2 OUT_OF_MEMORY）"
        case -3: return "この端末・ランタイムでは未対応の起動です（-3 UNSUPPORTED）"
        case -4: return "ランタイムの実行中にエラーが出ました（-4 RUNTIME_ERROR）。コンソール出力を確認してください"
        default: return "ランタイムが終了コード \(result) で終了しました"
        }
    }
}
