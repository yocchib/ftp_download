:::
::: DataMaru ($B%(%`%7%9%F%`5;8&@=(B $B%G!<%?%^%k(B IoT$B5!4o(B)
:::
:: ftp_download.exe -h 192.168.**.** -u  dl8  -p dl8  -l ./DataMaruSD  -r /LOG
ftp_download.exe -h 192.168.**.** -u  dl8  -p dl8

::: Raspberry Pi
::: ftp_download.exe -h 192.168.77.85 -u  taka  -p ****  -l ./raspi -r /home/taka/sub

::: Error Test
::: ftp_download.exe -h unknown -u  guest  -p denied_pass  -l ./raspi -r /home/guest/sub
::: ftp_download.exe -h 192.168.**.** -u  taka  -p unknown  -l ./raspi -r /home/guest/sub
