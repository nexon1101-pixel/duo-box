# DuoBox（採用箱）

採用した機能を1つのアプリに集める「箱」。アプリ本体はホーム（ランチャー）だけで、機能はそれぞれのリポジトリの Swift パッケージを取り込んで使う。

- リモート：duo-remote リポジトリの DuoRemoteCore パッケージ
- キーボード（DuoFlick）：DuoFlick リポジトリの DuoFlickKeyboardCore パッケージ（キーボード拡張として同梱）

アプリのIDは DuoRemote 時代と同じ（com.duoremote.app）なので、今の DuoRemote に上書きして入れられ、接続先やトークンは引き継がれる。

ビルドは GitHub Actions（ios-build）で、ビルド時に両リポジトリを vendor/ へ取得する。ipa は「latest」リリースに置かれる。

デバッグ版（DuoBox Debug）は、同じ作りの別アプリ。専用のソース（ios/DuoBoxDebug/）を持ち、中身を本番と別々に変えられる。IDが違う（com.duoremote.app.debug）ので本番と並べて入れられ、データは本番と共有しない。見た目は赤系で、アイコンも赤い箱。
