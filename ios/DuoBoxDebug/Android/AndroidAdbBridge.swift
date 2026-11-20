import Darwin
import Foundation
import GuestHostCore
import Network

/// パソコンの `adb connect <iPhoneのIP>:5555` を、ゲストの adbd へ中継する。
/// ゲストの adbd には、ランタイムの kernarium_runtime_loader_connect_vsock が返す
/// 接続済みディスクリプタ経由でしか届かない（端末に listen ソケットは無い）。
/// 本元 Andarium/Live/GuestAdb.swift の VsockConnector.openStream と同じ呼び方で、
/// 1 接続ごとにゲスト側ストリームを開き、NWConnection ⇄ fd のバイトポンプを行う。
/// どちらかが閉じたら両方を閉じる。
nonisolated final class AndroidAdbBridge: @unchecked Sendable {
    static let port: UInt16 = 5555
    private static let guestPort: UInt32 = 5555
    /// 本元 VsockConnector.networkAttemptTimeoutMilliseconds と同じ
    private static let connectTimeoutMilliseconds: UInt32 = 5000
    private static let chunk = 64 * 1024
    /// PC 1 台＋adb サーバーの再接続程度。これを超える接続は断る
    private static let maxConnections = 4

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "duo-box.android.adb-bridge")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var generation = 0
    /// 状態が変わるたびに、画面・報告用の 1 行（任意のスレッドから呼ばれる）
    private let onStatus: @Sendable (String) -> Void

    init(onStatus: @escaping @Sendable (String) -> Void) {
        self.onStatus = onStatus
    }

    // MARK: 起動・停止

    func start() {
        lock.lock()
        guard listener == nil else { lock.unlock(); return }
        generation += 1
        let mine = generation
        lock.unlock()

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            onStatus("adb 中継: 開始できません（\(error.localizedDescription)）")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.isCurrent(mine) else { return }
            switch state {
            case .ready:
                self.onStatus("adb 中継: TCP \(Self.port) で待機中")
            case .waiting(let error):
                // ローカルネットワークの許可が無いときなどもここに来る
                self.onStatus("adb 中継: 待機できません（\(error.localizedDescription)）。設定でローカルネットワークを許可してください")
            case .failed(let error):
                self.onStatus("adb 中継: 失敗（\(error.localizedDescription)）")
                self.stop()
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        lock.lock()
        self.listener = listener
        lock.unlock()
        onStatus("adb 中継: 開始中…")
        listener.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        generation += 1
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        listener?.cancel()
        for session in active { session.close() }
        if listener != nil { onStatus("adb 中継: 停止") }
    }

    private func isCurrent(_ mine: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == mine
    }

    // MARK: 接続

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let full = sessions.count >= Self.maxConnections
        lock.unlock()
        if full {
            connection.cancel()
            return
        }
        let session = Session(connection: connection) { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            self.sessions.removeValue(forKey: ObjectIdentifier(finished))
            self.lock.unlock()
        }
        lock.lock()
        sessions[ObjectIdentifier(session)] = session
        lock.unlock()
        session.start()
    }

    /// 1 本の接続。fd は読み取りスレッドが最後に close する
    private final class Session: @unchecked Sendable {
        private let connection: NWConnection
        private let connectionQueue = DispatchQueue(label: "duo-box.android.adb-bridge.conn")
        private let onEnd: (Session) -> Void
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var closed = false

        init(connection: NWConnection, onEnd: @escaping (Session) -> Void) {
            self.connection = connection
            self.onEnd = onEnd
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.openGuest()
                case .failed, .cancelled: self.close()
                default: break
                }
            }
            connection.start(queue: connectionQueue)
        }

        /// ゲスト側ストリームを開く（最長 5 秒ブロックするので別スレッド）
        private func openGuest() {
            let thread = Thread { [self] in
                let result = kernarium_runtime_loader_connect_vsock(
                    AndroidAdbBridge.guestPort, AndroidAdbBridge.connectTimeoutMilliseconds)
                guard result >= 0 else {
                    print("DuoBox Android: adb bridge: guest connect failed (\(result))")
                    close()
                    return
                }
                var on: Int32 = 1
                setsockopt(result, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                lock.lock()
                if closed {
                    lock.unlock()
                    Darwin.close(result)
                    return
                }
                fd = result
                lock.unlock()
                receiveFromNetwork()
                pumpGuestToNetwork(fd: result)
            }
            thread.name = "duo-box-android-adb-bridge"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        /// PC → ゲスト。書き終えてから次を受ける（背圧）
        private func receiveFromNetwork() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: AndroidAdbBridge.chunk) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    guard self.writeAll(data) else { self.close(); return }
                }
                if error != nil || isComplete {
                    self.close()
                } else {
                    self.receiveFromNetwork()
                }
            }
        }

        private func writeAll(_ data: Data) -> Bool {
            lock.lock()
            let target = fd
            let isClosed = closed
            lock.unlock()
            guard !isClosed, target >= 0 else { return false }
            return data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(target, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += n
                }
                return true
            }
        }

        /// ゲスト → PC。この関数が戻るとき、ディスクリプタを閉じる
        private func pumpGuestToNetwork(fd: Int32) {
            var buffer = [UInt8](repeating: 0, count: AndroidAdbBridge.chunk)
            let sent = DispatchSemaphore(value: 0)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                var failed = false
                connection.send(content: Data(buffer[0..<n]), completion: .contentProcessed { error in
                    failed = error != nil
                    sent.signal()
                })
                sent.wait()
                if failed { break }
            }
            close()
            lock.lock()
            self.fd = -1
            lock.unlock()
            Darwin.close(fd)
        }

        /// 両方を閉じる。fd は shutdown で読み取りスレッドを起こし、close はそのスレッドに任せる
        func close() {
            lock.lock()
            if closed { lock.unlock(); return }
            closed = true
            let target = fd
            lock.unlock()
            if target >= 0 { shutdown(target, SHUT_RDWR) }
            connection.cancel()
            onEnd(self)
        }
    }

    // MARK: 接続先の表示

    /// 端末の Wi-Fi（en0）の IPv4 アドレス。取れなければ nil
    static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            if result == 0 { return String(cString: host) }
        }
        return nil
    }

    /// 画面に出す 1 行
    static func connectHint() -> String {
        if let ip = wifiAddress() { return "adb connect \(ip):\(port)" }
        return "Wi-Fi の IP アドレスを取得できませんでした（Wi-Fi に接続してください）"
    }
}
