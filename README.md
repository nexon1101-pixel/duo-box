# DuoBox（採用箱）

採用した機能を1つのアプリに集める「箱」。アプリ本体はホーム（ランチャー）だけで、機能はそれぞれのリポジトリの Swift パッケージを取り込んで使う。

- リモート：duo-remote リポジトリの DuoRemoteCore パッケージ
- キーボード（DuoFlick）：DuoFlick リポジトリの DuoFlickKeyboardCore パッケージ（キーボード拡張として同梱）

アプリのIDは DuoRemote 時代と同じ（com.duoremote.app）なので、今の DuoRemote に上書きして入れられ、接続先やトークンは引き継がれる。

ビルドは GitHub Actions（ios-build）で、ビルド時に両リポジトリを vendor/ へ取得する。ipa は「latest」リリースに置かれる。

サンドボックス版（DuoBox Sandbox）は、同じ作りの別アプリで、今は中身を入れていない「箱だけ」の状態。IDが違う（com.duoremote.app.debug）ので本番と並べて入れられる。見た目は赤系で、アイコンも赤い箱。

試したいモジュールが出てきたら、まずサンドボックス版へ入れる。そのモジュールはモジュール側の sandbox ブランチから取り込む（本番は main）。サンドボックス版で具合がよければ、モジュール側で sandbox を main に取り込み、本番の箱へも載せる。
