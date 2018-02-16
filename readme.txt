==================================================================
 FTPサーバファイルのダウンロードプログラム   ver0.5 : 2018-02-07
==================================================================
■ プログラム名 :  ftp_download32.exe

  データマルのFTPサーバ機能を使って、FTPルートである
  SDカードのデータを 丸ごとカレントフォルダにダウンロードします
  ダウンロードは差分のみとなります。
  実行結果ログは ftp_download.log として出力されます。

■ プログラム構成  (ver0.5)

   ftp_download.pl    …  プログラム本体
   ftp_download.exe   …  64bit版実行プログラム (pp -o ftp_download.exe ftp_download.pl)
   ftp_download32.exe …  32bit版実行プログラム (pp -o ftp_download.exe ftp_download.pl)

   sample_64bit.bat   …  64bit版実行プログラムでの実行例 (バッチファイル)
   sample_32bit.bat   …  32bit版実行プログラムでの実行例 (バッチファイル)
   sample_debug.bat   …  デバッグ用バッチファイル


■ タスク登録用バッチファイル :  download_sample.bat

  このバッチを、タスクスケジューラに登録してあります
  毎日、１時間ごとに実行するようスケジュールしました
  
■プログラムソース : ftp_download.pl

  このソースプログラムを StrawberryPerl処理系 (32bit) にて
  CPAN PAR::Packer モジュールをインストール後
  pp -o  ftp_download32.exe  ftp_download(ver0.1).pl
  などとして、実行ファイルを生成します

  ※注
    運用中のIoTサーバでは、64bit処理系で生成した実行プログラムが
    正常に動かない事例が確認されたため、32bit処理系での運用とします

■ 動作確認済みの FTPサーバ
  o データマル機器 (エムシステム技研製) の FTPサーバ
  o Raspberry Pi (Raspbian OS) の FTPサーバ (vsFTPd)

■ 開発環境
   Strawberry Perl (x64版 x86版)
   PAR::Packer モジュール (CPANよりインストール)

■ 備考
  この手のプログラムは、ネットで検索すれば入手できると思い
  あれこれ探してみましたが、階層ディレクトリに対応し、かつ
  差分をとれるサンプルが見つからず、やむを得ず自作しました
