#!/bin/sh

if [ ! -f "/etc/vsftpd/vsftpd.conf" ]; then
    FTP_USER=$LINUX_USER_NAME
    FTP_PASS=$(cat /run/secrets/ftp_password)


    echo "Setting up FTP user: $FTP_USER"

    addgroup -g 2000 $LINUX_GROUP_NAME 2>/dev/null || true
    adduser -h /var/www/html/ -G $LINUX_GROUP_NAME -s /bin/sh -D -u 2000 $LINUX_USER_NAME 2>/dev/null || true

    grep -qx /bin/sh /etc/shells 2>/dev/null || echo /bin/sh >> /etc/shells

    echo "$FTP_USER:$FTP_PASS" | chpasswd


    echo "listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
seccomp_sandbox=NO
listen_port=$FTP_PORT
pasv_enable=YES
pasv_min_port=$pasv_min_port
pasv_max_port=$pasv_max_port
local_root=/var/www/html/
" > /etc/vsftpd/vsftpd.conf

fi
echo "Starting vsftpd..."

exec /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf