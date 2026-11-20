# DuoBox Debug に Android（Kernarium ランタイム）を入れる計画

状態：計画のみ（実装前）。読んだもの：Kernarium（`~/workspace/kernarium-ref`、`origin` は `imxieyi/Kernarium`、調査時点の先頭は `b14aa9e`）と、この作業ツリーの `ios/project.yml`、`ios-build.yml`、`ios/DuoBoxDebug/`。

## 0. 先に結論

- 入れるのは **Kernarium の「ランタイム框架（KernariumRuntime）」と、`GuestHost/`（共有の Swift/ObjC ソース）** です。Kernarium の `Andarium/`（完成アプリ）は丸ごとは使いません。
- duo-box に置くのは、箱の画面から Android 画面を開く接着コードと、CI・project.yml の設定だけです。Kernarium のソースは `vendor/kernarium` にピン留めで取得し、コピーも改変もしません。
- 一番の不明点は **Kernarium の Releases に、出来合いのカーネルバンドルと LineageOS イメージが実際にあるか** です（§4、手順 0 で最初に確認）。調査した限り、リポジトリ内には、それらを Releases から取る仕組みも、`.github/` も、タグもありませんでした。

## 1. 組み込みの方式

### 1.1 Kernarium 側で何があるか（読んで分かったこと）

| もの | 中身 | この計画での扱い |
| --- | --- | --- |
| `KernariumRuntime`（CMake ターゲット） | iOS 用ランタイム框架。Android 用は `UML_KERNEL_PRODUCT=android-17`、**カーネル ELF を框架の `__TEXT` に抱える** | CI で CMake ビルド。プリセットは `kernarium-ios-device-android`（通常版。App Store 版や automation 版は使わない） |
| `Kernarium/scripts/package-ios-frameworks.sh --runtimes android` | 框架を XCFramework にまとめ `.build/kernarium-xcframeworks` に出す（Android だけなら Linux ランタイムは不要） | CI で実行 |
| `Andarium/scripts/stage-system-image.py` | 承認済み Android リリース（system.img、partition-layout.json、kernel-command-line.txt、release-manifest.json）を `.build/andarium-system` に置く | CI で実行。入力は `.build/android/releases` の出来合いリリース |
| `GuestHost/Sources` | ランタイムのローダー（`KernariumRuntimeLoader.h/.mm`）、ゲスト画面（Metal）、タッチ/キーボード/ポインタ入力、zstd、シェーダキャッシュなど。**「Kernarium と Andarium が各自のモジュールにそのまま取り込む」前提の作り** | DuoBoxDebug のターゲットに、vendor のパスを指して取り込む（コピーしない） |
| `GuestHost/Core`（`GuestHostCore`） | UIKit 無しの Swift パッケージ（サイズ、空き容量、停止処理など） | 他の vendor パッケージと同じく `packages:` にパス指定 |
| `Andarium/AndariumCore` | 本体の Swift パッケージ（ゲスト管理・ストレージ・ブート進行・adb クライアント。UIKit 無し。GuestHostCore を再公開） | 段階 2 で採用を検討（§1.3） |
| 依存ライブラリのプレフィックス（Mesa/KosmicKrisp、network、zstd、GPTFDisk） | `dependencies/prepare.sh` と各 `build-*.sh` が作る `.build/dependencies/...`。ランタイムのビルドに必要 | 出来合いがあれば取得、なければ CI で作る（§4 のリスク） |

### 1.2 `tests/consumer` と「外部利用」の想定

`tests/consumer/apple/` は `main.c`/`main.cpp` と CMake だけで、**UMLEmulator（`uml_emulator`）という C API のパッケージ/XCFramework を外部の C/C++/ObjC から使えるかの確認用**です。iOS アプリ向けではなく、層が一段低い（エミュレータ本体で、ディスプレイ・ストレージ・ブートはない）。`AGENTS.md` も「ホストプロジェクトの C 実装は `tests/consumer/apple/main.c` だけ例外」と書いています。

したがって、**外部アプリが使う想定の入口は、ランタイム框架 ＋ `GuestHost`（ローダー経由）** と判断しました。実際、`GuestHost` は 2 つのアプリで共有される前提で書かれているので、DuoBoxDebug が 3 つ目の利用者になる形が自然です。`tests/consumer` は流用しません。

### 1.3 アプリ側の構成（Andarium をどう流用するか）

Andarium の `Shared/`・`Live/`（画面とライブ実行）は、`@main`／UIKit のシーンデリゲート（Info.plist の `UIApplicationSceneManifest` と `AndariumSceneDelegate`）／ホスティングコントローラーに強く結びついていて、「1 プロセス 1 シーン 1 ゲスト」の前提でもあります。DuoBox の SwiftUI `WindowGroup` の中へ一画面として埋め込むのは難しく、内部型は `internal` で本元の改修で壊れやすいです。そこで次の 2 段階にします。

- **段階 1（最小）**：`GuestHost/Sources` ＋ `GuestHostCore` だけを使い、DuoBoxDebug 側に薄い画面を書く。
  - ローダーでランタイムを読む → ブート要求を作る → 画面（`GuestDisplay`）を出す → 停止、まで。
  - ゲストのデータ置き場は `Library/Guest/`（Andarium と同じ、パスに空白や特殊文字を含めない制約あり）。
- **段階 2（必要になれば）**：`AndariumCore` を `packages:` に足し、ゲストの寿命・ストレージ・更新判定・adb を任せて接着コードを減らす。段階 1 で足りるなら入れない。

duo-box に書くファイル（接着だけ）：

```text
ios/DuoBoxDebug/Android/
  AndroidModule.swift        箱のホームに出すカード（「Android」）と、そこから画面を開く導線
  AndroidSessionView.swift   GuestDisplay を載せる SwiftUI 画面、起動中/エラー/停止の表示
  AndroidRunner.swift        ローダー呼び出し、ブート要求、ゲストのデータ置き場、停止処理
ios/DuoBoxDebug/DuoBoxDebug.entitlements   Increased Memory Limit / Extended Virtual Addressing
ios/DuoBoxDebug/PrivacyInfo.xcprivacy      本元の Andarium 側の内容を見て最小限（§2.2）
ios/kernarium.pin            ピン（§5）
scripts/ci/（または .github/scripts/） 取得・検証・ビルドの shell
```

`HomeView.swift` は「まだ何も入っていません」の下に Android カードを足すだけにします。

## 2. CI と project.yml の変更

### 2.1 `ios-build.yml`

現在：`xcode-27` ランナーで duo-remote と DuoFlick を `vendor/` に checkout し、`xcodegen` → 本番とデバッグの 2 回 `xcodebuild` → ipa 2 つをリリース `latest` に置く。

変更（デバッグ版にだけ関係する部分を、別ジョブに分けることを推奨）：

1. **ジョブ分割**
   - `android-runtime`：Kernarium の取得、依存、ランタイム、システムイメージの準備（重い）。成果物（`.build/kernarium-xcframeworks`、`.build/andarium-system`）をキャッシュ/アーティファクトにする。
   - `build`：本番 DuoBox は今のまま。**本番側の所要時間と成功を Android 部分に巻き込まない**（`DuoBox` 本番は Android 無し）。DuoBoxDebug だけ `needs: android-runtime`。
2. **Kernarium の取得**：`actions/checkout@v4` で `repository: imxieyi/Kernarium`、`ref: ${{ steps.pin.outputs.ref }}`、`path: vendor/kernarium`。ピンは `ios/kernarium.pin` から読む（コミット SHA、ブランチ名や `latest` 禁止）。
3. **出来合い成果物の取得**（`gh release download`、タグはピンファイルに書く）：
   - カーネルバンドル → `vendor/kernarium/.build/kernel/artifacts/<accepted-android-4k.env の UML_KERNEL_ARTIFACT_DIRECTORY_NAME>`
   - LineageOS リリース → `vendor/kernarium/.build/android/releases/<accepted-release.env の LINEAGE24_ACCEPTED_DIRECTORY_NAME>`（`install-release.py` で検証付きインストールする運用が本元の想定。AOT があれば `--aot-artifact`）
   - 取得後に、**ピン先の `accepted-*.env` の ID・ディレクトリ名と照合して、合わなければ失敗**させる（ピンと成果物のズレを CI で検出する）。
4. **依存プレフィックス**：Releases にあれば取得。なければ `dependencies/prepare.sh --product ...` と `build-apple-gpu.sh --platform ios`、`build-ios-network.sh`、`build-ios-storage.sh`、`build-ios-zstd.sh` を実行（最も重く、Metal Toolchain も要る。§4）。
5. **ランタイム**：
   ```sh
   cd vendor/kernarium
   cmake --preset kernarium-ios-device-android
   cmake --build --preset kernarium-ios-device-android
   Kernarium/scripts/package-ios-frameworks.sh --runtimes android
   Andarium/scripts/stage-system-image.py
   ```
   通常版（App Store 版でも automation 版でもない）を使う。JIT と、サイドロード向けの準備入口があるのは通常版だけ。
6. **デバッグ版のビルド**：`DuoBoxDebug` のスキームは、今と同じ未署名ビルド。`xcodegen` はそのまま。
7. **entitlement**：未署名ビルドでは、entitlements ファイルは署名時に付かない。サイドロード時に SideStore 側で付く前提ならそのままでよいが、**ipa 側に擬似署名（`ldid -S`）で entitlement を埋めておく**手も用意しておく（§4）。
8. **ipa の置き場**：`DuoBoxDebug.ipa` はシステムイメージを含み大きくなる見込み。リリースの 1 ファイル上限（2 GiB）に収まるか要確認（§4）。`latest` のリリースに置く現行の流れは維持。
9. **トリガー**：`paths` に `ios/kernarium.pin` を含める（`ios/**` に含まれるので追加不要）。

### 2.2 `project.yml`

- `packages:` に `GuestHostCore: path: ../vendor/kernarium/GuestHost/Core` を追加（段階 2 では `AndariumCore: path: ../vendor/kernarium/Andarium/AndariumCore`）。duo-remote や DuoFlick と同じ書き方。
- **DuoBoxDebug ターゲットだけ**に次を足す（本番 `DuoBox` と `DuoBoxKeyboard` は触らない）。
  - `sources:` に `../vendor/kernarium/GuestHost/Sources`（`type: group`、ビルド対象として取り込み）。
  - `dependencies:` に `package: GuestHostCore`、`framework:` で `KernariumRuntime`/`LibZstd`/`GPTFDisk` などの XCFramework（`vendor/kernarium/.build/kernarium-xcframeworks/...`、必要な一覧は `package-ios-frameworks.sh` の出力で確定）。KosmicKrisp は本元が「ラッパースクリプトで埋め込む」方式なので、`embed-device-framework.sh` を `postBuildScripts` で使う（デバイス専用、Simulator では何もしない）。
  - システムイメージ（`.build/andarium-system`）をリソースとして同梱（フォルダ参照）。
  - 設定：`SWIFT_OBJC_BRIDGING_HEADER` に、`#import ".../GuestHost/Sources/KernariumRuntimeLoader.h"` だけを書いた duo-box 側のヘッダー（`ios/DuoBoxDebug/DuoBoxDebug-Bridging-Header.h`）を指す。Swift 5 モード、`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`、approachable concurrency（GuestHost の README が両アプリで揃える前提と書いている）。`CODE_SIGN_ENTITLEMENTS` に新しい entitlements ファイル。
  - `info.properties` に追加：`UIRequiredDeviceCapabilities`（`arm64`、`metal`）、`GCSupportedGameControllers`（ExtendedGamepad）、`ITSAppUsesNonExemptEncryption: false`、マイク/カメラ/位置情報を使うなら対応する説明文（段階 1 では使わないので入れず、ローダーが要求しないか確認）。
- 本元の `Andarium/Config/Info.plist` と見比べて、必要なキーが抜けていたら CI の確認ステップで警告を出す（キーの値は写さず、キー名だけ比較）。
- 本元は **Xcode 27 の JSON 形式プロジェクト**と**アイコン形式（.icon）**を使うが、duo-box は XcodeGen で別に作るので影響しない。本元の `.xcodeproj` は使わない。

## 3. 実装の手順と、各段で確認すること

| 段 | やること | 次へ進む条件 |
| --- | --- | --- |
| 0 | **調査の穴埋め**：Kernarium の Releases に何があるか（カーネルバンドル、LineageOS リリース、依存プレフィックス、XCFramework の有無とサイズ、タグ名）を確認。無い場合の代替（§4）を決める | 取得元と、ピンファイルに書く項目が決まる |
| 1 | `ios/kernarium.pin` と取得スクリプトを作り、CI で取得→照合までだけ動かす（Xcode ビルドはしない）。duo-box への Kernarium コピーが無いことを確認 | CI が「ピン先の `accepted-*.env` と成果物が一致」で緑、わざと間違えると赤 |
| 2 | 依存プレフィックスとランタイムのビルド（`cmake --preset kernarium-ios-device-android`）、`package-ios-frameworks.sh --runtimes android`、`stage-system-image.py` を CI に載せる（別ジョブ、キャッシュ） | XCFramework とシステムイメージが出る。**所要時間とサイズを記録**して段 3 以降のキャッシュ戦略を決める |
| 3 | `project.yml` に GuestHost・XCFramework・イメージ同梱・設定を足し、**画面は何も変えず**ビルドだけ通す（`HomeView` は今のまま） | DuoBoxDebug の未署名 ipa ができ、本番 DuoBox は無変更で成功。ipa サイズが上限内 |
| 4 | 接着コード段階 1（`Android/` 配下）：ホームのカードと画面。ブート要求を作り、ブートして画面を出すところまで。JIT は使わず gadget（解釈実行）で | 実機で Android のブート画面→ホームが出る（遅くてよい）。`docs/iphone-check.md` に確認項目を足し、ユーザーに実機確認を頼む |
| 5 | 入力（タッチ、画面の向き、キーボード）、停止/復帰、アプリがバックグラウンドへ行ったとき（Andarium は「前面にいる間だけ動く」）、エラーの表示 | 実機で操作でき、閉じて開き直しても壊れない。DuoBox ホームへ戻れる |
| 6 | JIT の準備（ローダーの `prepare_jit` と StikDebug 連携。Andarium の `AppModel.prepareJitAtLaunch` 相当を、こちらの接着コードで書く）。使えないとき gadget に落ちる | JIT 有りで起動でき（起動自体は gadget より遅くなる見込み）、JIT が使えないときは gadget で落ちずに動く。入れる価値があるかをここで判断 |
| 7 | 必要なら段階 2（AndariumCore）へ。ピン上げの手順書（§5）で実際に 1 回上げて試す | ピン上げだけでビルドと起動が通る |

各段で、`CLAUDE.md` の決まり通り、iOS のビルド確認は GitHub Actions、実機で見る部分は `docs/iphone-check.md` にまとめてユーザーに頼みます。

## 4. リスク・不明点

調査していて**確かめられなかったこと**を先に並べます。

1. **Kernarium の Releases の中身**：`gh release list` は承認待ちで実行できず未確認。ローカルのクローンにタグも `.github/` も無く、本元の README/AGENTS は「カーネルは Mac でビルドして `.build/kernel/artifacts` に publish、Android リリースは x86_64 Linux で作って `.build/android/releases` に install する」とだけ書いている。**Releases に出来合いがなければ、この計画の前提（ピンを上げるだけ）が成り立たない**。その場合は、(a) 自前の Release を duo-box 側で作る（ただし成果物を別に管理することになる）、(b) 本元に Releases を作ってもらう、のどちらかをユーザーと決める。
2. **依存プレフィックスの出来合い**：Mesa/KosmicKrisp は LLVM を含む大きなビルドで、Metal Toolchain の導入（`xcodebuild -downloadComponent MetalToolchain`）が要る。出来合いが無ければ CI 時間が大きい（数時間級の可能性。未計測）。キャッシュ必須。
3. **`accepted-aot.env` が無い**：AGENTS には Android リリースの AOT 成果物の記述があるが、この時点のツリーの `android/lineage-24/metadata/` には `accepted-release.env` 等しかない。AOT 無しでも動くか、AOT が必要なら Releases にあるかを確認する。
4. **ipa サイズ**：`system.img` が入る。サイズは未確認。GitHub リリースの 1 ファイル 2 GiB 上限、Actions のアーティファクト/キャッシュの容量（リポジトリ全体 10 GiB のキャッシュ上限）、ランナーのディスクを超えないか。超える場合は、イメージを ipa に入れず初回起動時にダウンロードする形（接着コード側で）も検討。
5. **本元のライセンス**：Kernarium は GPL-2.0-or-later（Android 側は Apache-2.0）。取り込んだ DuoBoxDebug の ipa を配ると GPL の義務（ソース提供）が及ぶ可能性が高い。デバッグ版を自分の機体にだけ入れる範囲なら実質問題は小さいが、配布するなら要整理。duo-box の接着コードの扱い（リンクの形）も同じ。**この点は法的な判断なので、配布前に確認**。
6. **entitlement と署名**：Increased Memory Limit / Extended Virtual Addressing は Apple の Capability で、通常は App ID に紐づく。SideStore の署名で実際に付くか、無料アカウントで付けられるかは未確認（ユーザーは付く前提）。付かないと、メモリ上限で落ちる/アドレス空間が足りない可能性が高い。ipa 側でやることは、(a) entitlements ファイルをリポジトリに置く、(b) 必要なら `ldid -S` で擬似署名する、(c) `UIRequiredDeviceCapabilities` に `metal`、くらい。
7. **JIT**：本元の JIT は、デバッガ（StikDebug）が付いたときだけ使える。サイドロードのアプリがデバッグ可能であること（`get-task-allow` 相当）が前提で、署名で付くかは未確認。無いと gadget 実行になる。Andarium の README によると、JIT はブートやアプリ起動が gadget より数倍遅く、長い単一プロセスの計算だけが速くなる。つまり JIT は必須ではなく、gadget が基準。まず gadget で動かす（段 4）ので、JIT が使えなくても進められる。
8. **Metal 4 が要る**：ゲスト描画は Metal 4（A14 以降）。実機が対応していなければ起動を拒否する設計。`UIRequiredDeviceCapabilities: metal` だけでは足りないので、接着コードで事前チェックして分かりやすく断る。
9. **デバイス要件の差**：DuoBox は iOS 17 対応、Kernarium 側の要件が iOS 27 SDK 前提かもしれない（Duo の内側画面の件で Xcode 27 は既に使用中）。`IPHONEOS_DEPLOYMENT_TARGET` を、本元の最小値と照らして合わせる。
10. **メモリ**：ゲスト RAM は既定で 1.5〜4 GiB。上限を超えると iOS に落とされる。ローダーが返す上限（`kernarium_runtime_loader_maximum_guest_memory_mib`）に従う実装にする。
11. **CI 所要時間**：キャッシュが効くとき（ピンが変わらないとき）は、取得＋Xcode ビルドだけにしたい。キャッシュキーはピン（Kernarium の SHA と Releases のタグ）にする。
12. **本元の内部 API の変化**：`GuestHost` の型は `internal`（モジュールに取り込む前提）。本元の改修で型名や引数が変わると、接着コードのビルドが壊れる。ピン上げのたびに必ず CI で確認する（§5）。
13. **公開リポジトリの注意**：本元は個人情報（チーム ID、署名、端末 ID 等）をコミットしない方針。duo-box でも CLAUDE.md の通り、トークンや自宅 IP は入れない。取得スクリプトにトークンを書かず、`GITHUB_TOKEN` を使う。

## 5. 本元追従の手順（ピン上げ）

ピンは `ios/kernarium.pin` 1 ファイルに集約します（案）。

```text
KERNARIUM_REF=<Kernarium のコミット SHA>
KERNARIUM_RELEASE_TAG=<成果物（カーネル/Android/依存）の Releases タグ>
```

ピンを上げる操作：

1. 本元の新しいコミットと Releases を確認：
   ```sh
   git -C ~/workspace/kernarium-ref fetch origin
   git -C ~/workspace/kernarium-ref log --oneline <今のピン>..origin/main -- GuestHost Andarium/AndariumCore Kernarium/Runtime Kernarium/scripts darwin/api kernel/common/abi android/lineage-24/metadata kernel/mainline-6.18/artifacts
   gh release list --repo imxieyi/Kernarium
   ```
   `GuestHost/`、`kernel/common/abi/identity.env`（ABI）、`accepted-*.env` の変更が、接着コードに影響するかを見る。
2. 新しい Releases のタグを選び（そのタグが、選ぶ Kernarium コミットの `accepted-*.env` と一致するものであること）、`ios/kernarium.pin` を 2 行書き換える。
3. ブランチを切って push（ローカル git のみ）。CI が、取得→照合→ビルドまで通るか見る。
   - 照合で赤：Kernarium のコミットと Releases の成果物がずれている。タグか SHA を合わせ直す。
   - Swift のビルドが赤：`GuestHost` の API 変更。duo-box の `ios/DuoBoxDebug/Android/` だけを直す（本元は触らない）。
4. 緑になったら、`docs/iphone-check.md` の Android の項を実機で確認してもらい、PR を作る（GitHub コネクタ）。
5. うまくいかなければ、ピンを元に戻せば元のビルドが再現できる（成果物はタグ固定のため）。

自動化したくなったら、後から「`git ls-remote` で新しいタグを見つけてピン上げ PR を作る」週次の Actions を足せる（最初は手動で十分）。
