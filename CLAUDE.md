# CLAUDE.md

- 返事は日本語で。普通の言葉で書く
- push はローカル git のみ（GitHub コネクタの push-files は使わない）。PR の作成・マージは GitHub コネクタで行う
- このリポジトリは「採用箱」のアプリ本体だけを持つ。機能の本体は各モジュールのリポジトリ（duo-remote の DuoRemoteCore、DuoFlick の DuoFlickKeyboardCore）にあり、ビルド時に vendor/ へ取得して取り込む
- アプリのID（com.duoremote.app）は変えない。上書きインストールでデータが引き継がれることが前提
- サーバーのトークンや自宅のIPなど、秘密にあたる値はコミットしない
- Linux クラウドでは iOS ビルド確認は GitHub Actions で行い、残りは実機確認を頼む（docs/iphone-check.md）
