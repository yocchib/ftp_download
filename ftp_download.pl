#==============================================================================
#!/usr/bin/perl -w
#!c:\Strawberry\perl\bin\perl.exe
#------------------------------------------------------------------------------
# ftp_download.pl : 
#
# 指定ftpサーバより、ftpルートを起点とするフォルダ階層から構成されるファイル群
# をまとめてローカルフォルダにダウンロードする。
# 既にダウンロード済みのファイルはスキップする（差分ダウンロード）
#
#-------------------------------------------------------------------------------
# ※ テスト済み FTPサーバ
#    o データマル (MSYSTEM 製) に搭載の FTPサーバ
#    o Raspberry Pi OS (raspbian)       FTPサーバ (vsFTPd 2.3.5)
# -----------+--------+---------------------------------------------------------
# 2018-01-31 | ver0.1 | 新規 
# 2018-02-05 | ver0.2 | -l オプション (ローカルフォルダ基点を指定可能とした)
# 2018-02-05 | ver0.3 | -r オプション (リモートFTPサーバフォルダ基点指定可能とした)
# 2018-02-06 | ver0.4 | -h <FTPサーバIP> -u <ユーザ> -p <パスワード>  対応
# 2018-02-07 | ver0.5 | システムコール系のエラー処理 (mkpath, ftpコマンド発行時など)
#---------------------+---------------------------------------------------------
# ※ 制限事項
#  o ファイルが更新されたかの判定は、ファイルサイズで実施しているため
#    ファイルサイズが変化しない更新があった場合、差分ダウンロードの対象から
#    外れてしまいます。
#    (データマルの dirコマンド出力では年月日レベルしか分からないため)
#  o  FTPサーバ側で対象フォルダ内のファイルが削除されても
#     差分ダウンロードの際、ローカル側での削除対象ファイルは そのまま残ります
#
# <ペンディング>
#   データマル以外の FTPサーバにも利用できるように汎用化せよ
#   dirコマンド出力仕様の違いを吸収せよ
#-------------------------------------------------------------------------------
# <実行例>
#  ftp_download.exe
#  ftp_download.exe -l ./SD_CARD                 # ダウンロード格納フォルダ(./SD_CARD) を指定
#  ftp_download.exe -r /2018_02 -l ./SD_201802   # ftpサーバの /2018_02 フォルダを差分ダウンロード
#  ftp_doenload.exe -h 192.168.**.** -u  taro  -p **  -l ./raspi -r /home/taro/test
#===============================================================================
use strict;

use Getopt::Std ; # getopts
use Net::FTP;
use Data::Dumper;
use File::Find;
use File::Path ;

# コマンド引数
my %args ;
getopts("l:r:h:u:p:", \%args); # -l <格納フォルダ相対パス> -r <FTPサーバのフォルダパス> 
                               # -h <FTPサーバIP> -u <ユーザ> -p <パスワード> 

my $today =   today_stamp();   # $today->{ year => 2018, month => 2, day => 6, hour => 11, min => 23 sec => 59)
my $mon2num = mon2idx();       #  { Jan => '01', Feb => '02', .. Dec => '12'}

my $host = {	# デフォルトは 制御装置のデータマル (Msystem製 IoT機器)
  ip   => $args{h}, 	# -h <FTPサーバIP>
  user => $args{u}, 	# -u <ユーザ>
  pass => $args{p},		# -p <パスワード> 
};

local(*LOG);
my $err_message = "";
open(LOG, "> ./ftp_download.log") or die $! ;

my $local_dir = $args{l} || '.';  # ダウンロード格納する基点フォルダ (例) -l ./SD_CARD

# (1) 最初にダウンロード格納フォルダ(ローカルフォルダ) のファイル構成をを解析する

my $local = local_dir_scan( $local_dir );
my ($localF, $localD) = local_path2size($local, $local_dir); # $fileH->{'/2017_11/D28.CSV'} = 3101,   $dirH->{'/2017_11'} = 1

# (2) 次に FTPサーバ側の対象フォルダのファイル構成を解析する

my $host_dir = $args{r} ||  "/" ;
$host_dir =~ s|/$|| ;               # ディレクトリパスの末尾に '/' があれば一旦削除
$host_dir .= '/'    ;               # ディレクトリパスの末尾に '/' を改めて付加

my $remote = ftp_dir_scan($host_dir);  # FTPサーバ側の指定ディレクトリを走査する
unless ($remote) {
	print LOG  "Error at ftp_dir_scan() \n" . $err_message . "\n";
	close(LOG);
	print "Error at ftp_dir_scan() \n";
	exit(1);
}
print LOG Data::Dumper->Dump([$remote, $localF, $localD], [qw(remote  localF localD)]);

# (3) ローカル側とFTPサーバ側のファイル構成を比較して、ダウンロードが必要な
#     差分ファイルのリスト作成

my($needFiles, $needDirs) = download_need_files($localF, $localD, $remote); # $localF->{'/2017_11/D28.CSV'} = 3101, $localD->{'/2017_11'} = 1

print LOG Data::Dumper->Dump([$needFiles, $needDirs], [qw(needFiles needDirs)]);

# (4) 差分ファイルのリストに基づき、ファイルをFTPダウンロードする
#    
my $dl_info = download_exec($host, $needFiles, $needDirs, $local_dir);
unless ($dl_info) {
	print LOG  "Error at download_exec() \n" . $err_message . "\n";
	close(LOG);
	print "Error at download_exec() \n";
	exit(1);
}
print LOG Data::Dumper->Dump([$dl_info], [qw($dl_info)]);
close(LOG);

#-------------------------------------------------------
# FTPサーバ側の指定ディレクトリを走査する
#-------------------------------------------------------
sub ftp_dir_scan {
  my $host_dir = shift ;
  my $ftp ;

  unless ( $ftp = Net::FTP->new($host->{ip}) ) { # FTPサーバへの接続(ホスト名でもIPアドレスでもOK)
	$err_message = "Cannot Open $host->{ip} \n" ;
	return undef ;
  }
  # ユーザ名とパスワードを指定してログイン
  unless ( $ftp->login($host->{user}, $host->{pass}) ) {
	$err_message = "Cannot login $host->{ip} :" . $ftp->message;
	return undef ;
  }
  my $remote = dir_scan($ftp, $host_dir);  # FTPサーバ側の指定ディレクトリを走査する
  $ftp->quit; # 接続を終了する
  return $remote ;
}
 
#------------------------------------------------------------------------------
# ダウンロードすべき FTPサーバ上の最新ファイルのリストを作成する
# ダウンロード対象は、ローカルにないファイル、および 更新されているファイル
# 更新されているかの判断は、ファイルサイズが変化(大きくなっているか) で判断する
#
# ($needFiles, $needDirs) = download_need_files($localF, $localD, $remote)
#------------------------------------------------------------------------------
sub remote_trace {
  my ($remote, $func) = @_;

  my ($dir_path, @cdr) = @{$remote};
  &$func($dir_path);                  # 先頭要素がディレクトリパス
                                      # そのあとに [ファイルパスとファイルサイズをスペースで区切った文字列]
  for my $entry (@cdr) {              # または [サブディレクトリ要素配列] が続く

	if ( ref($entry) eq 'ARRAY' ) {   #  [サブディレクトリ要素配列] の場合
		remote_trace($entry, $func);  #  サブディレクトリを引数に再帰呼び出し

	} else {   # [ファイルパスとファイルサイズをスペースで区切った文字列]

  		&$func($entry);               # 先頭要素がディレクトリパス
	}
  }
}
sub  download_need_files {
  my ($localF, $localD, $remote) = @_; # $localF->{'/2017_11/D28.CSV'} = 3101, $localD->{'/2017_11'} = 1

  my $needFiles = undef ;
  my $needDirs  = undef ;

  # 無名コールバック関数を定義 (引数で渡されるファイルエントリの処理) 
  remote_trace( $remote, sub {
    my $entry = shift ;       

	if (my($path, $size) = ($entry =~ m/(.*?)\s+(\d+)$/)) { # 例 '/2017_11/D21.CSV  31166', 

		if ( my $localFsize = $localF->{$path} ) {
			
			if ( $localFsize == $size ) {
  				push(@{$needFiles->{exists}}, $path);

			} else {
  				push(@{$needFiles->{update}}, $path);
			}
		} else {  # ローカルフォルダにない新しいファイル
			
  			push(@{$needFiles->{new}}, $path);   # '/2017_11/D21.CSV', 
		}

	} else { # ディレクトリである (例) '/LOG/AI/'
		if (  $localD->{$entry} ) {
			
  			push(@{$needDirs->{exists}}, $entry);
			
		} elsif ( $entry =~ m|(.*)/$|  &&  $localD->{$1} ) {
  			push(@{$needDirs->{exists}}, $1);

		} else {  # ローカルフォルダにない新しいフォルダ
			
  			push(@{$needDirs->{new}}, $entry);
		}
	}

  } );
  return ($needFiles, $needDirs) ;
}

#------------------------------------------------------------------------------
# ローカルフォルダにない FTPサーバ上の最新ファイルを get(ダウンロード) する
# 合わせて、ローカルサブフォルダも必要に応じて生成する
# 引数でダウンロード対象となるのは $needFiles->{'new'}  $needFiles->{'update'}
# ディレクトリ作成対象は  $needDirs->{new}
#
# $hash = download_exec($host, $needFiles, $needDirs);
# 
# 戻り値 {newdir => $newdir_cnt, new_file => $new_files, upd_file => $upd_files}
#        undef (エラー時)
#------------------------------------------------------------------------------
sub download_exec {
  my ($host, $needFiles, $needDirs, $local_dir) = @_;

  # まずローカルフォルダ上にフォルダを準備する
  my $newdir_cnt = make_local_dirs( $needDirs->{new}, $local_dir );
  if ( $newdir_cnt == -1 ) { 
	return undef ;
  }
  my $ftp ;
  unless ( $ftp = Net::FTP->new($host->{ip}) ) { # FTPサーバへの接続 (ホスト名 or IPアドレス)
	$err_message = "Cannot Open $host->{ip} \n" ;
	return undef ;
  }
  unless ( $ftp->login($host->{user}, $host->{pass}) ) {
	$err_message = "Cannot login $host->{ip} :" . $ftp->message;
	return undef ;
  }

  my $new_files = get_files($ftp, $needFiles->{'new'},  $local_dir );
  my $upd_files = get_files($ftp, $needFiles->{update}, $local_dir );
  
  $ftp->quit; # 接続を終了する
  return {newdir => $newdir_cnt, new_file => $new_files, upd_file => $upd_files} ; 
}

#----------------------------------------------------------
# まずローカルフォルダ上にフォルダを準備する
#
#----------------------------------------------------------
sub  make_local_dirs {
  my ($dir_list, $local_base) = @_;   # ( ['/LOG/AI/', ..]  , '.' )
  my $cnt = 0;
  my $error_mkpath = undef ;

  return undef unless ( ref($dir_list) eq 'ARRAY' );

  $local_base =~ s|/$|| ;  # 末尾の '/' があれば 除く

  for my $dir_path (@{$dir_list}) {  # '/LOG/AI/'
	$dir_path   =~ s|^/|| ;  # 先頭の '/' を除く

	my $local_dir = $local_base . '/' . $dir_path ;

    eval { mkpath($local_dir) };  # 2018-02-07
	if ($@) {
		my $err = "Couldn't create $local_dir: $@" . "\n";
  		$error_mkpath .= $err ;
		print  $err ;
	} else {
		$cnt++ ;
	}
  }
  if ( $error_mkpath ) {
	$err_message = $error_mkpath ;
	return -1 ;
  }
  return $cnt ;
}
#----------------------------------------------------------
# ftpサーバより、引数パスのファイルをダウンロードする
#----------------------------------------------------------
sub get_files {
  my ($ftp, $path_list, $local_base) = @_;

  return undef unless ( ref($path_list) eq 'ARRAY' );

  my $new_files = undef ;
  $local_base  =~ s|/$|| ;  # 末尾の '/' があれば 除く

  for my $path (@{$path_list}) {  # '/2017_11/D21.CSV', 
	my $local_path = $path ;

	$local_path  =~ s|^/|| ;  # 先頭の '/' を除く

	$local_path = $local_base . '/' . $local_path ;

    $ftp->get($path, $local_path);   # $ftp->get('/2017_11/D28.CSV', './2017_11/D28.CSV');
    push(@{$new_files}, $local_path);
  }
  return $new_files ;
}

#------------------------------------------------------------------------------
# FTPサーバの指定ディレクトリを走査し, [ディレクトリ要素配列] を作成する
#
# [ディレクトリ要素配列] の構造定義
#   先頭要素がディレクトリパスで、
#   そのあとに [ファイルパスとファイルサイズをスペースで区切った文字列]
#   または [サブディレクトリ要素配列] が続く
#   ※ [サブディレクトリ要素配列] は [ディレクトリ要素配列] と同じ構造をもつ (再帰構造)
#
# 戻り値 $remote = [    # [ディレクトリ要素配列] 
#         '/',                                # 先頭要素がディレクトリパス
#         [ '/TEMP/' ],                       # [サブディレクトリ要素配列]  先頭要素がディレクトリパス
#         [ '/2017_11/',                      # [サブディレクトリ要素配列]  先頭要素がディレクトリパス
#           '/2017_11/D21.CSV  31166',        #    ファイルパスとファイルサイズを空白で
#              …                             #     区切った文字列が続く
#           '/2017_11/D30.CSV  3124'          #
#         ],
#         [ '/LOG/',                          # [サブディレクトリ要素配列]  先頭要素がディレクトリパス
#           [ '/LOG/AI/',                     # サブ [サブディレクトリ要素配列]  先頭要素がディレクトリパス
#             '/LOG/AI/AI01LOG.TXT  21343',   #      ファイルパスとファイルサイズを空白で
#             '/LOG/AI/AI05LOG.TXT  1720'     #      区切った文字列が続く
#           ],
#           [ '/LOG/DI/',                     # サブ [サブディレクトリ要素配列]  先頭要素がディレクトリパス
#             '/LOG/DI/DI02LOG.TXT  32068',
#             '/LOG/DI/DI01LOG.TXT  10693'
#           ],
#           [ '/LOG/PI/' ],                   # サブ [サブディレクトリ要素配列]  先頭要素がディレクトリパス
#           [ '/LOG/DO/',
#             '/LOG/DO/DO01LOG.TXT  1670',
#             '/LOG/DO/DO15LOG.TXT  588'
#           ],
#           '/LOG/ELOG.TXT  98197'
#         ],
#         …
#------------------------------------------------------------------------------
sub dir_scan {
  my ($ftp, $host_dir) = @_;

  my @file_infos = $ftp->dir($host_dir);  # dirコマンドはOS依存です。そのOSで「ls -l」を実行した出力結果が得られます。たとえば私の現在使用しているFedora7の場合は次のような出力になります。
  # データマルの場合
  #  DB<1> x @file_infos
  # 0  'drwxr-xr-x  1     0     0         0 Nov 14  2017 TEMP'
  # 1  'drwxr-xr-x  1     0     0         0 Nov 14  2017 LOG'
  # 2  'drwxr-xr-x  1     0     0         0 Nov 21  2017 2017_11'
  # 3  'drwxr-xr-x  1     0     0         0 Dec  1 00:00 2017_12'
  # 4  'drwxr-xr-x  1     0     0         0 Jan  5 10:00 2018_01'
  #
  #    DB<1> x @file_infos
  #  0  'drwxr-xr-x  1     0     0         0 Nov 21  2017 .'
  #  1  'drwxr-xr-x  1     0     0         0 Nov 21  2017 ..'
  #  2  '-rw-r--r--  1     0     0     31166 Nov 21  2017 D21.CSV'
  #  3  '-rw-r--r--  1     0     0     90490 Nov 22  2017 D22.CSV'
  #   …                                                …
  #  10 '-rw-r--r--  1     0     0      3124 Nov 30  2017 D30.CSV'
  #ラズパイの場合
  #   DB<2> x @file_infos
  # 0  'drwxr-xr-x    2 0        0            4096 Sep 30  2014 bin'
  # 1  'drwxr-xr-x    3 0        0            4096 Sep 24  2014 boot'
  # 2  'drwxr-xr-x   13 0        0            3100 Jan 06 14:19 dev'
  # 3  'drwxr-xr-x   82 0        0            4096 Oct 31  2014 etc'
  # 4  'drwxr-xr-x    4 0        0            4096 Oct 30  2014 home'
  #   …                                                …
  # 7  'drwxr-xr-x   14 0        0           12288 Sep 24  2014 lib'
  # 8  'drwx------    2 0        0           16384 Sep 14  2012 lost+found'
  #
  my $res_arr = [ $host_dir ];
  my $res ;
  for my $row ( @file_infos ) {
	my $fobj = file_info($row);
	next if $fobj->{name} =~ /^\.\.?$/ ; # . と .. をスキップする

	if ( $fobj->{isDir} ) {
		my $sub_dir = $host_dir . $fobj->{name} . '/';
		$res = dir_scan($ftp, $sub_dir);
	} else {
		$res = file_process($fobj, $host_dir);
	}
	push(@{$res_arr}, $res);
  }
  return $res_arr ;
}

#==========================================================================
# $res = file_process($fobj, $host_dir);
#
#==========================================================================
sub file_process {
  my ($fobj, $host_dir) = @_;

  $fobj->{path} =  $host_dir . $fobj->{name};

  return $fobj->{path} . '  ' . $fobj->{size} ;
}

#--------------------------------------------------------------------------
# ファイルまたはディレクトリエントリの情報をハッシュで返す
# 引数例
# データマルの場合
#  'drwxr-xr-x  1     0     0         0 Nov 14  2017 TEMP'
#  '-rw-r--r--  1     0     0     31166 Nov 21  2017 D21.CSV'
# ラズパイの場合
#  'drwxr-xr-x   2 1000  1000      4096 Jan 25 16:22 2017_11'
#
# 戻り値ハッシュ
#  { isDir => undef, ymd => '2017-11-21', size => 31166, name =>  D21.CSV
#--------------------------------------------------------------------------
sub file_info {
  my $line = shift ;
  #
  my $info = {};

  # [ '-rw-r--r--',  1, 0, 0, 31166, 'Nov', 21, 2017, 'D21.CSV' ]
  my ($drwx, $link, $own, $grp, $size, $month, $day, $year_or_hhmm, $fname) =  split(/\s+/, $line) ;
  $info->{isDir} = $drwx =~ /^d/ ? 1 : undef ;
  if (my($hh, $mm) = ($year_or_hhmm =~ /(\d\d):(\d\d)/) ) {  # ラズパイの場合 年内のタイムスタンプは 時:分
  	$info->{ymd}   = sprintf("%s-%s-%s %s:%s", $today->{year}, $mon2num->{$month}, $day, $hh, $mm);
  } else {
  	$info->{ymd}   = sprintf("%s-%s-%s", $year_or_hhmm, $mon2num->{$month}, $day);
  }
  $info->{size}  = $info->{isDir} ? undef : $size ;
  $info->{name}  = $fname ;

  return $info ;
}

#----------------------------------------------------------------
#  { Jan => '01', Feb => '02', .. Dec => '12'}
#----------------------------------------------------------------
sub mon2idx {
  my @mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
  my $hash = {};

  for my $idx (0..$#mon) {
	$hash->{$mon[$idx]} = sprintf("%02d", $idx+1);
  }
  return $hash ;
}

#==================================================================================
# ローカルフォルダでの処理
#==================================================================================
# 戻り値  [相対パス, ファイルサイズ] のリストを返す
#  $local = [ 
#       [ '.', undef ],
#       [ './ftp_sample.pl', 13112 ],
#       [ './sample.pl', 8916 ],
#       [ './wk.log', 2177 ],
#       [ './2017_11', undef ],
#       [ './2017_11/D28.CSV', 3101 ],
#       [ './192.168.76.199 (制御データマル)/TEMP', undef ],
#       [ './192.168.76.199 (制御データマル)/2017_11/D21.CSV', 31166 ],
#       [ './192.168.76.199 (制御データマル)/2017_11/D22.CSV', 90490 ],
#       [ './192.168.76.199 (制御データマル)/2017_11/D23.CSV', 95058 ],
#  ]
#==================================================================================
sub local_dir_scan {
  my $local_dir = shift ;
  my $files     = undef ;

  find ( sub { 
	# print "$File::Find::name";
	my $path = $File::Find::name ;
	my $size = -d $_ ? undef : -s $_ ;
	
	push(@{$files}, [$path, $size]);
	# push(@{$files}, [$path, $size, $_, $File::Find::dir]);

  }, ($local_dir) );

  return $files ;
}

#-----------------------------------------------------------------------
# ($fileHash, $dirHash) = local_path2size($local, $local_dir);
#
# ファイルの場合 ファイルパスをキー、サイズを値とするハッシュ($fileHash)
# を作成する
# ディレクトリの場合(サイズが undef) は 別のリスト($dirHash) を作る
#
# 戻り値 $fileHash->{'/2017_11/D28.CSV'} = 3101
#        $dirHash->{'/2017_11'} = 1
#-----------------------------------------------------------------------
sub local_path2size {
  my ($local, $local_dir) = @_ ;  # [ [ './2017_11', undef ], ['./2017_11/D28.CSV', 3101 ], ..
  my ($fileHash, $dirHash) = (undef, undef);

  my $quote_dir = quotemeta($local_dir) ;
  for my $pair (@{$local}) {
	my($path, $size) = @{$pair};
	# $path =~ s/^\.// ;       # './2017_11/D28.CSV' の先頭の . を外し FTPリモートパスに合わせる
	$path =~ s/^$quote_dir// ; # '$local_dir/2017_11/D28.CSV' の先頭の $local_dir を外し FTPリモートパスに合わせる

	if ($size) {  # 通常ファイルの場合
  		$fileHash->{$path} = $size ; 

	} else {  	# ディレクトリの場合
		$dirHash->{$path} = 1 ; # true の 意 
	}
  }
  return ($fileHash, $dirHash);
}


# $hash today_stamp()
sub  today_stamp {
  my @arr = localtime(time); # qw( 53  0  11 6 1 118 2 36 0 )
  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = @arr ;
  my $hash = {};
  $hash->{year}  = $year + 1900 ;
  $hash->{month} = $mon + 1 ;
  $hash->{day}   = $mday ;
  $hash->{hour}  = $hour ;
  $hash->{min}   = $min ;
  $hash->{sec}   = $sec ; 
  return $hash ;
} 

__END__
#===============================================================================
# 参考資料
#===============================================================================
# put
#   $ftp->put($file$)               # ファイルをアップロードするにはputを使用します。
#   $ftp->put($file, $renamed_file) #  第2引数にファイル名を指定すると名前を変えてアップロードを行うことができます。
# binary
#   $ftp->binary    # ファイルの転送モードをバイナリモードに変更します。
# 　                # 転送モードにはバイナリモードとアスキーモードの2種類があります。
#                   # バイナリモードを指定するとファイルを転送するときに何の変換も行いません。画像ファイルや動画ファイルなどを転送する場合はかならずバイナリモードで転送する必要があります。
# ascii
# 　ファイルの転送モードをアスキーモードに変更します。
#   $ftp->ascii 　 # アスキーモードを指定すると改行コードの自動変換を行ってくれます。
#                  # たとえばWindowsのデフォルトの改行コードは\r\nです。Unixのデフォルトの改行コードは\nです。Windowsのメモ帳などで作成したファイルをそのままUnixに転送すると正しく表示することができません。アスキーモードで転送するとこの変換を自動で行ってくれます。
#-------------------------------------------------------------------------------
# ls 　ファイル名の一覧を取得します。
#   @files = $ftp->ls($dir) # ディレクトリ名を省略した場合は接続先のカレントディレクトリに
#                           # 含まれるファイルの一覧を取得します。
# 
# dir ファイル名の一覧を詳細な情報を含めて取得します。
#   @file_infos = $ftp->dir($dir)  # dirコマンドはOS依存です。そのOSで「ls -l」を実行した出力結果が得られます。
#                                  # たとえば私の現在使用しているFedora7の場合は次のような出力になります。
#    -rw-r--r--  1 someuser  somegroup   6618 Aug  8 17:22 button.html
#    -rwxr-xr-x  3 someuser  somegroup    512 Apr  1  2009 a.pl
#    -rwx------  1 someuser  somegroup     77 Apr  1  2009 mm.txt
# 
#-------------------------------------------------------------------------------
# quit 　FTPサーバーとの接続を閉じます。
# 
# ときどき使用するメソッド
# 
# メソッド名 機能 
# pwd 接続先のカレントディレクトリの取得 
# rename ファイル名の変更 
# mkdir ディレクトリの作成 
# rmdir ディレクトリの削除 
# size ファイルサイズの取得 
#
#-------------------------------------------------------------------------------
# サンプル１ 
#-------------------------------------------------------------------------------
# ユーザとパスワードを指定するFTPサーバにはサンプルでは接続することができません。
# パスワードを指定しないでもよい匿名サーバからファイルをダウンロードしてみます。
# CPANのミラーサイトからCPANのトップページ(index.html)をダウンロードするサンプルです。
# use strict;
# use warnings;
# 
# use Net::FTP;
# 
# my $host = 'ftp.u-aizu.ac.jp';
# my $user = 'anonymous';
# 
# my $ftp = Net::FTP->new($host) or die "Cannot connect to '$host': $!";
# $ftp->login($user) or die "Cannot login '$host:$user':" . $ftp->message;
# $ftp->cwd('/pub/CPAN') or die "FTP command fail: " . $ftp->message;
# $ftp->get('index.html') or die "FTP command fail: " . $ftp->message;
# $ftp->quit;
# 
#-------------------------------------------------------------------------------
# サンプル２ 
#-------------------------------------------------------------------------------
# my %ftp = (
#   addr => 'source.jp', # 転送元サーバのFTPアドレス
#   user => 'admin', # ユーザー名
#   pass => 'password', # パスワード
#   dir => '/home/user01/www/image', # 送信元ディレクトリ
# );
# 
# my $ftp = Net::FTP->new( $ftp{'addr'}, Debug => 0 ) or die "can not connection: $@";
# $ftp -> login( $ftp{'user'}, $ftp{'pass'} ) or die;
# 
# # カレントディレクトリの変更
# $ftp -> cwd( $ftp{'dir'} );
# 
# # バイナリモード
# $ftp -> type( 'I' );   # アスキーモードの場合はIでなくA
# 
# my @dir = grep /^[^d]/, $ftp->dir; # ファイル一覧をdirコマンドで取得。
#                                    # フォルダ一覧を取得したい場合は「grep /^d/, $ftp->dir」
# 
# my @dir_names_full = @dir[2..$#dir]; # 　自フォルダと親フォルダ("."と"..")を除く。
# 
# my @dir_names_short = map { (split)[8] } @dir_names_full; # ファイル名のみを取得
# 
# chdir "./image";
# 
# foreach (@dir_names_short){
# 
#   $ftp -> get( "$_" );
# } 
# 
# chdir "../";
# 
# # 接続切断 
# $ftp -> quit();
# 
#===============================================================================
