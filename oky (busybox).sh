#!/bin/sh
version_major=1
version_minor=0
version_patch=0
version="${version_major}.${version_minor}.${version_patch}"
distro_name="OKY"
distro_codename="San Jacinto"
hostname="none"
telnetd_enabled="true"
hyperv_support="false"
kernel="https://github.com/oscargfloresb/GNU-Linux/raw/refs/heads/main/linux-6.18.37.tar.xz"
busybox="https://github.com/oscargfloresb/GNU-Linux/raw/refs/heads/main/busybox-1.36.1.tar.bz2"
iso_name="${distro_name}-${version}.iso"
workdir="$(pwd)"
isodir="$workdir/isoroot"
root_password=""
root_hash=""
if [ $(id -u) -ne 0 ]; then
echo "Run as root"; exit 1
fi
clear
required_pkgs="ca-certificates wget build-essential libncurses-dev \
bison flex libelf-dev chrpath gawk texinfo libsdl1.2-dev whiptail diffstat cpio \
libssl-dev bc grub-pc-bin grub-efi-amd64-bin grub-common grub2-common xorriso mtools dosfstools parted"
missing=""
for p in $required_pkgs; do
dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done
if [ -n "$missing" ]; then
echo "** Faltan las siguientes dependencias:$missing"
printf "** ¿Instalar las dependencias faltantes ahora? (y/n): "
read answer
if [ "$answer" = "y" ]; then
apt update && apt install -y $missing || { echo "** Falló la instalación de dependencias."; exit 1; }
else
echo "** No se puede continuar sin las dependencias necesarias."; exit 1
fi
fi
command -v openssl >/dev/null 2>&1 || { echo "** Falta 'openssl', necesario para generar la contraseña de root."; exit 1; }
root_password="toor"
root_hash="$(openssl passwd -6 -salt "$(head -c 8 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 8)" "$root_password")"
[ -d ./files ] || mkdir files
answer="n"
if [ -f files/busybox/busybox ] ; then
printf "** Se detectó una compilación previa de BusyBox. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ] ; then
cd files/
bb_tarball="busybox-src.tar.bz2"
reuse_tar="n"
if [ -f "$bb_tarball" ] ; then
printf "** Se encontró el archivo de BusyBox ya descargado. ¿Usarlo sin volver a descargar? (y/n): "
read reuse_tar
fi
if [ "$reuse_tar" != "y" ] ; then
rm -f "$bb_tarball"
wget "$busybox" -O "$bb_tarball" || { echo "** Falló la descarga de BusyBox."; exit 1; }
fi
rm -rf busybox
mkdir busybox
tar -xf "$bb_tarball" -C busybox --strip-components=1 || { echo "** Falló la extracción de BusyBox."; exit 1; }
cd busybox
make defconfig
sed 's/^.*CONFIG_STATIC.*$/CONFIG_STATIC=y/' -i .config
sed 's/^CONFIG_MAN=y/CONFIG_MAN=n/' -i .config
sed 's/^CONFIG_TC=y/CONFIG_TC=n/' -i .config
echo "CONFIG_STATIC_LIBGCC=y" >> .config
make -j"$(nproc)" || { echo "** Falló la compilación de BusyBox."; exit 1; }
cd ../../
fi
rm -rf "$isodir"
mkdir -p "$isodir/boot/grub"
host=$(printf '%s' "$hostname" | tr 'A-Z' 'a-z' | cut -d' ' -f1)
arch=$(uname -m)
[ $arch = 'i686' ] && arch="i386"
answer="n"
if [ -f files/linux/arch/$arch/boot/bzImage ] ; then
printf "** Se detectó un kernel ya compilado. ¿Reutilizarlo? (y/n): "
read answer
fi
if [ "$answer" != "y" ] ; then
cd files
k_tarball="linux-src.tar.xz"
reuse_tar="n"
if [ -f "$k_tarball" ] ; then
printf "** Se encontró el archivo del kernel ya descargado. ¿Usarlo sin volver a descargar? (y/n): "
read reuse_tar
fi
if [ "$reuse_tar" != "y" ] ; then
rm -f "$k_tarball"
wget "$kernel" -O "$k_tarball" || { echo "** Falló la descarga del kernel."; exit 1; }
fi
rm -rf linux
mkdir linux
tar -xf "$k_tarball" -C linux --strip-components=1 || { echo "** Falló la extracción del kernel."; exit 1; }
cd linux
if [ "$hyperv_support" = "true" ]; then
cat <<EOF >> arch/x86/configs/x86_64_defconfig
CONFIG_HYPERVISOR_GUEST=y
CONFIG_PARAVIRT=y
CONFIG_CONNECTOR=y
CONFIG_HYPERV=y
CONFIG_HYPERV_NET=y
EOF
fi
make defconfig
./scripts/config --enable CONFIG_FB
./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
./scripts/config --enable CONFIG_SYSFB_SIMPLEFB
./scripts/config --enable CONFIG_DRM
./scripts/config --enable CONFIG_DRM_SIMPLEDRM
./scripts/config --enable CONFIG_DRM_FBDEV_EMULATION
make olddefconfig
make -j"$(nproc)" || { echo "** Falló la compilación del kernel."; exit 1; }
cd ../../
fi
kernel_release=$(cat files/linux/include/config/kernel.release)
kernel_file=vmlinuz-$kernel_release-$arch
initrd_file=initrd.img-$kernel_release-$arch
cp files/linux/arch/$arch/boot/bzImage "$isodir/boot/$kernel_file"
cat > "$isodir/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
menuentry '$distro_name' {
linux /boot/$kernel_file quiet
initrd /boot/$initrd_file
}
EOF
mkdir rootfs
cd rootfs
mkdir -p bin boot dev lib lib64 run mnt/root proc sbin sys usr/bin usr/sbin tmp home var/log usr/share/udhcpc usr/local/bin var/spool/cron/crontabs etc/init.d etc/rc.d var/run var/www/html etc/network/if-down.d etc/network/if-post-down.d etc/network/if-pre-up.d etc/network/if-up.d run etc/cron/daily etc/cron/hourly etc/cron/monthly etc/cron/weekly
cp ../files/busybox/busybox bin
install -d -m 0750 root
install -d -m 1777 tmp
for i in $(find /lib/ | grep 'ld-2\|ld-lin\|libc.so\|libnss_dns\|libresolv'); do
cp ${i} lib
done
cp ../files/linux/arch/$arch/boot/bzImage boot/vmlinuz
grub_tools="
/usr/sbin/grub-install
/usr/bin/grub-mkimage
/usr/sbin/grub-probe
/usr/sbin/grub-mkdevicemap
/usr/bin/grub-mkrelpath
/usr/bin/grub-editenv
/usr/lib/grub/i386-pc/grub-bios-setup
/usr/lib/grub/x86_64-efi/grub-mkimage
"
mkdir -p sbin
cp /usr/sbin/parted sbin/
for lib in $(ldd /usr/sbin/parted | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/
done
for gt in $grub_tools; do
[ -f "$gt" ] || continue
destdir="usr/sbin"
case "$gt" in
/usr/bin/*)
destdir="usr/bin"
;;
/usr/lib/grub/i386-pc/*)
destdir="usr/lib/grub/i386-pc"
;;
/usr/lib/grub/x86_64-efi/*)
destdir="usr/lib/grub/x86_64-efi"
;;
esac
mkdir -p "$destdir"
cp "$gt" "$destdir/"
for lib in $(ldd "$gt" 2>/dev/null | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/ 2>/dev/null
done
done
mkdir -p lib64
cp lib/ld-linux-x86-64.so.2 lib64/ 2>/dev/null || \
cp /lib64/ld-linux-x86-64.so.2 lib64/ 2>/dev/null
mkdir -p usr/lib/grub
cp -a /usr/lib/grub/i386-pc usr/lib/grub/
cp -a /usr/lib/grub/x86_64-efi usr/lib/grub/
mkdir -p usr/share
cp -a /usr/share/grub usr/share/ 2>/dev/null
mknod dev/console c 5 1
mknod dev/tty c 5 0
printf '%s' "$host" > etc/hostname
printf "root:x:0:0:root:/root:/bin/sh\nservice:x:1:1:service:/var/www/html:/usr/sbin/nologin\n" > etc/passwd
printf "root:%s:0::::::\n" "$root_hash" > etc/shadow
printf "root:x:0:root\nservice:x:1:service\n" > etc/group
echo "/bin/sh" > etc/shells
echo "127.0.0.1	 localhost $host" > etc/hosts
cat << EOF > var/www/html/index.html
<!DOCTYPE html><html lang="en"><head><title>$distro_name httpd default page: It works</title>
<style>body{background-color:#004c75;}h1,p{margin-top:60px;color:#d4d4d4;
text-align:center;font-family:Arial}</style></head><body><h1>It works!</h1><hr>
<p><b>$distro_name httpd</b> default page<br>ver. $version</p></body></html>
EOF
cat << EOF > etc/fstab
proc    /proc   proc    defaults        0   0
sysfs   /sys    sysfs   defaults        0   0
tmpfs   /tmp    tmpfs   defaults,nosuid 0   0
EOF
cat << 'EOF' > etc/profile
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
trap 'clear' 0
export PS1='\u@\h:\w\$ '
EOF
cat > etc/issue << EOF
Welcome to $distro_name
EOF
cat << EOF > etc/motd
Thank you for trying this distribution.
EOF
cat << EOF > etc/os-release
PRETTY_NAME="$distro_name ($distro_codename)"
NAME="$distro_name"
VERSION_ID="$version"
VERSION="$version"
VERSION_CODENAME="$distro_codename"
ID="$distro_name"
HOME_URL="oky.pe"
SUPPORT_URL="oky.pe"
BUG_REPORT_URL="oky.pe"
EOF
cat << EOF > etc/inittab
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
::sysinit:/sbin/swapon -a
::sysinit:/bin/hostname -F /etc/hostname
::sysinit:/etc/init.d/rcS
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/echo SHUTTING DOWN
::shutdown:/sbin/swapoff -a
::shutdown:/etc/init.d/rcK
::shutdown:/bin/umount -a -r
EOF
cat << EOF > etc/network/interfaces
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF
cat << EOF > init
#!/bin/busybox sh
/bin/busybox --install -s
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mountpoint -q proc || mount -t proc proc proc
mountpoint -q sys || mount -t sysfs sys sys
mknod /dev/null c 1 3
if ! mountpoint -q dev
then
mount -t tmpfs -o size=64k,mode=0755 tmpfs dev
mkdir -p dev/pts
mdev -s
fi
echo 0 > /proc/sys/kernel/printk
root_part=\$(findfs LABEL=OKYROOT 2>/dev/null)
if [ -n "\$root_part" ] && [ -b "\$root_part" ] && mount "\$root_part" /mnt/root 2>/dev/null
then
for i in dev proc sys run; do
[ -d /mnt/root/\$i ] || mkdir -p /mnt/root/\$i
mount -o bind /\$i /mnt/root/\$i
done
mkdir -p /mnt/root/tmp
mount -t tmpfs -o mode=1777 tmpfs /mnt/root/tmp
exec switch_root /mnt/root /sbin/init
fi
mount -t tmpfs -o mode=1777 tmpfs tmp
mount -t devpts none dev/pts
mount -t tmpfs run /run -o mode=0755,nosuid,nodev
chown -R service:service /var/www
exec /sbin/init
EOF
printf "#!/bin/sh
echo 'This account is currently not available.'
sleep 3
exit 1" > usr/sbin/nologin
cat << EOF > sbin/halt
#!/bin/sh
if [ \$1 ] && [ \$1 = '-p' ] ; then
/bin/busybox poweroff
return 0
fi
/bin/busybox halt
EOF
cat << EOF > usr/sbin/install-to-disk
#!/bin/sh
echo
echo "== Instalador de $distro_name a disco =="
echo "AVISO: esto borra TODOS los datos del disco que elijas."
echo
echo "Discos disponibles:"
for d in \$(ls /sys/block 2>/dev/null); do
case "\$d" in loop*|sr*|ram*) continue ;; esac
echo "/dev/\$d"
done
echo
printf "Dispositivo destino completo (ej: /dev/sda): "
read target
if [ ! -b "\$target" ]; then
echo "\$target no es un dispositivo de bloque valido."
exit 1
fi
printf "Esto BORRARA todo en \$target. Escribe SI en mayusculas para continuar: "
read confirm
if [ "\$confirm" != "SI" ]; then
echo "Cancelado."
exit 1
fi
if [ -d /sys/firmware/efi ]; then
echo "** Instalacion UEFI"
parted -s "\$target" mklabel gpt
parted -s "\$target" mkpart ESP fat32 1MiB 301MiB
parted -s "\$target" set 1 esp on
parted -s "\$target" mkpart primary ext2 301MiB 100%
mdev -s
sleep 2
case "\$target" in
*[0-9])
efipart="\${target}p1"
partdev="\${target}p2"
;;
*)
efipart="\${target}1"
partdev="\${target}2"
;;
esac
echo "** Formateando EFI"
mkfs.vfat -F32 "\$efipart"
echo "** Formateando ROOT"
mkfs.ext2 -L OKYROOT "\$partdev"
mkdir -p /mnt/target
mount "\$partdev" /mnt/target
mkdir -p /mnt/target/boot/efi
mount "\$efipart" /mnt/target/boot/efi
else
echo "** Instalacion BIOS"
printf "o\nn\np\n1\n2048\n\nw\n" | fdisk "\$target" >/dev/null 2>&1
mdev -s
sleep 1
partdev="\${target}1"
case "\$target" in
*[0-9]) partdev="\${target}p1" ;;
esac
mkfs.ext2 -L OKYROOT "\$partdev"
mkdir -p /mnt/target
mount "\$partdev" /mnt/target
fi
if ! mountpoint -q /mnt/target; then
echo "ERROR: no se pudo montar \$partdev en /mnt/target."
exit 1
fi
echo "** Copiando el sistema (puede tardar un poco)"
for entry in /*; do
base=\$(basename "\$entry")
case "\$base" in proc|sys|dev|run|tmp|mnt) continue ;; esac
cp -a "\$entry" /mnt/target/ 2>/dev/null
done
mkdir -p /mnt/target/proc /mnt/target/sys /mnt/target/dev /mnt/target/run \
/mnt/target/tmp /mnt/target/mnt/root /mnt/target/boot/grub
cat > /mnt/target/etc/fstab <<FSTAB
proc    /proc   proc    defaults        0   0
sysfs   /sys    sysfs   defaults        0   0
tmpfs   /tmp    tmpfs   defaults,nosuid 0   0
FSTAB
echo "** Generando initrd del sistema instalado"
(
cd /mnt/target
find . -xdev -print0 | cpio -o -H newc --null 2>/dev/null
) | gzip > /tmp/initrd.img.new
mv /tmp/initrd.img.new /mnt/target/boot/initrd.img
cat > /mnt/target/boot/grub/grub.cfg <<GRUBCFG
set default=0
set timeout=3
menuentry '$distro_name' {
linux /boot/vmlinuz quiet
initrd /boot/initrd.img
}
GRUBCFG
if [ -d /sys/firmware/efi ]; then
echo "** Instalando GRUB UEFI"
grub-install \
--target=x86_64-efi \
--efi-directory=/mnt/target/boot/efi \
--boot-directory=/mnt/target/boot \
--bootloader-id=OKY \
--removable
else
echo "** Instalando GRUB BIOS"
grub-install \
--target=i386-pc \
--boot-directory=/mnt/target/boot \
--modules="part_msdos ext2 biosdisk" \
"\$target"
fi
echo
echo "** Verificando archivos..."
[ -f /mnt/target/boot/vmlinuz ] || {
echo "Falta el kernel."
exit 1
}
[ -f /mnt/target/boot/initrd.img ] || {
echo "Falta el initrd."
exit 1
}
[ -f /mnt/target/boot/grub/grub.cfg ] || {
echo "Falta grub.cfg."
exit 1
}
if [ -d /sys/firmware/efi ]; then
[ -d /mnt/target/boot/grub/x86_64-efi ] || {
echo "Faltan los modulos UEFI de GRUB."
exit 1
}
else
[ -d /mnt/target/boot/grub/i386-pc ] || {
echo "Faltan los modulos BIOS de GRUB."
exit 1
}
fi
echo "** Verificacion correcta."
sync
cd /
umount /mnt/target
echo
echo "** Instalacion completa."
echo "** Retira el medio de instalacion y reinicia."
EOF
cat << EOF > sbin/man
#!/bin/sh
if [ -z "\$(busybox \$1 --help 2>&1 | head -1 | grep 'applet not found')" ]
then
clear
head="\$(echo \$1 | tr 'a-z' 'A-Z')(1)\\t\\t\\tManual page\\n"
body="\$(busybox \$1 --help 2>&1 | tail -n +2)\\n\\n"
printf "\$head\$body" | more
exit 0
fi
echo "No manual entry for \$1"
EOF
printf "#!/bin/sh
. /etc/init.d/init-functions
rc" > etc/init.d/rcS
ln -s /etc/init.d/rcS etc/init.d/rcK
cat << EOF > var/spool/cron/crontabs/root
15 * * * * cd / && run-parts /etc/cron/hourly
23 6 * * * cd / && run-parts /etc/cron/daily
47 6 * * 0 cd / && run-parts /etc/cron/weekly
33 5 1 * * cd / && run-parts /etc/cron/monthly
EOF
cat << EOF > usr/sbin/logrotate
#!/bin/sh 
maxsize=512
dir=/var/log
for log in \$(ls -1 \${dir} | grep -Ev '\.gz$'); do
size=\$(du "\$dir/\$log" | tr -s '\t' ' ' | cut -d' ' -f1)
if [ "\$size" -gt "\$maxsize" ] ; then
tsp=\$(date +%s)
mv "\$dir/\$log" "\$dir/\$log.\$tsp"
touch "\$dir/\$log"
gzip "\$dir/\$log.\$tsp"
fi
done
EOF
ln -s ../../../usr/sbin/logrotate etc/cron/daily/logrotate
cat << EOF > usr/bin/add-rc.d
#!/bin/sh
if [ -f /etc/init.d/\$1 ] && [ "\$2" -gt 0 ] ; then 
ln -s /etc/init.d/\$1 /etc/rc.d/\$2\$1
echo "added \$1 to init."
else
echo "
** $distro_name add-rc.d ussage:
add-rc.d [init.d script name] [order number]
examples:
add-rc.d httpd 40
add-rc.d ftpd 40
add-rc.d telnetd 50
"
fi
EOF
initdata="
networking|network|30|/sbin/ifup|-a|/sbin/ifdown
telnetd|telnet daemon|80|/usr/sbin/telnetd|-p 23
cron|cron daemon|20|/usr/sbin/crond
syslogd|syslog|10|/sbin/syslogd
httpd|http server||/usr/sbin/httpd|-vvv -f -u service -h /var/www/html||httpd.log
ftpd|ftp daemon||/usr/bin/tcpsvd|-vE 0.0.0.0 21 ftpd -S -a service -w /var/www/html"
OIFS=$IFS
IFS='
'
for i in $initdata; do
IFS='|'
set -- $i
cat << EOF > etc/init.d/$1
#!/bin/sh
NAME="$1"
DESC="$2"
DAEMON="$4"
PARAMS="$5"
STOP="$6"
LOG="$7"
PIDFILE=/var/run/$1.pid
. /etc/init.d/init-functions
init \$@
EOF
chmod 744 etc/init.d/$1
[ $1 = 'telnetd' ] && [ "$telnetd_enabled" = false ] && continue;
[ "$3" ] && ln -s ../init.d/$1 etc/rc.d/$3$1.sh
done
IFS=$OIFS
cat > usr/share/udhcpc/default.script <<'EOF'
#!/bin/sh
[ -z "$1" ] && echo "Error: should be called from udhcpc" && exit 1
RESOLV_CONF="/etc/resolv.conf"
[ -n "$broadcast" ] && BROADCAST="broadcast $broadcast"
[ -n "$subnet" ] && NETMASK="netmask $subnet"
root_is_nfs() {
grep -qe '^/dev/root.*\(nfs\|smbfs\|ncp\|coda\) .*' /proc/mounts
}
have_bin_ip=0
if [ -x /bin/ip ]; then
have_bin_ip=1
fi
case "$1" in
deconfig)
if ! root_is_nfs ; then
if [ $have_bin_ip -eq 1 ]; then
ip addr flush dev $interface
ip link set dev $interface up
else
/sbin/ifconfig $interface 0.0.0.0
fi
fi
;;
renew|bound)
if [ $have_bin_ip -eq 1 ]; then
ip addr add dev $interface local $ip/$mask $BROADCAST
else
/sbin/ifconfig $interface $ip $BROADCAST $NETMASK
fi
if [ -n "$router" ] ; then
if ! root_is_nfs ; then
if [ $have_bin_ip -eq 1 ]; then
while ip route del default 2>/dev/null ; do
:
done
else
while route del default gw 0.0.0.0 dev $interface 2>/dev/null ; do
:
done
fi
fi
metric=0
for i in $router ; do
if [ $have_bin_ip -eq 1 ]; then
ip route add default via $i metric $((metric++))
else
route add default gw $i dev $interface metric $((metric++)) 2>/dev/null
fi
done
fi
echo -n > $RESOLV_CONF
[ -n "$domain" ] && echo search $domain >> $RESOLV_CONF
for i in $dns ; do
echo adding dns $i
echo nameserver $i >> $RESOLV_CONF
done
;;
esac
exit 0
EOF
cat > etc/init.d/init-functions <<'EOF'
#!/bin/sh
init () {
test -f $DAEMON || exit 0
case "$1" in
start)
echo "Starting $DESC..."
if [ $LOG ] ; then
$DAEMON $PARAMS 2>>/var/log/$LOG &
else
$DAEMON $PARAMS &>/dev/null &
fi
echo $! > $PIDFILE
;;
stop)
echo "Stopping $DESC..."
if [ $STOP ] ; then
$STOP $PARAMS
else
[ -f $PIDFILE ] && kill $(cat $PIDFILE) &>/dev/null
fi
;;
restart|reload)
"$0" stop
"$0" start
;;
*)
echo "$NAME init script usage: $0 {start|stop|restart}"
return 1
esac
return $?
}
rc () {
if [ -d /etc/rc.d ] && [ "$0" = "/etc/init.d/rcK" ]; then
for x in $(ls -r /etc/rc.d/) ; do
/etc/rc.d/$x stop
done
return 1
fi
for i in /etc/rc.d/??* ; do
[ ! -f "$i" ] && continue
case "$i" in
*.sh)
(
trap - INT QUIT TSTP
set start
. $i
)
;;
*)
$i start
;;
esac
done
sleep 1
clear
return 1
}
EOF
touch proc/mounts var/log/wtmp var/log/lastlog
chmod 640 etc/shadow etc/inittab
chmod 664 var/log/lastlog var/log/wtmp
chmod 755 bin/busybox
chmod 600 var/spool/cron/crontabs/root
chmod 755 usr/sbin/nologin init sbin/man etc/init.d/rcS usr/sbin/logrotate usr/bin/add-rc.d sbin/halt usr/share/udhcpc/default.script usr/sbin/install-to-disk
chmod 644 etc/passwd etc/group etc/hostname etc/shells etc/hosts etc/fstab etc/issue etc/motd etc/network/interfaces etc/profile
chmod 755 usr/sbin/grub-install usr/bin/grub-mkimage usr/sbin/grub-probe usr/sbin/grub-mkdevicemap usr/bin/grub-mkrelpath usr/bin/grub-editenv usr/lib/grub/i386-pc/grub-bios-setup 2>/dev/null
find . | cpio -H newc -o 2> /dev/null | gzip > "$isodir/boot/$initrd_file"
cd ..
rm -rf rootfs
grub-mkrescue -o "$workdir/$iso_name" "$isodir"
if [ -f "$workdir/$iso_name" ] ; then
printf "\n** Listo: %s\n" "$workdir/$iso_name"
if command -v xorriso >/dev/null 2>&1; then
if xorriso -indev "$workdir/$iso_name" -find / -name "*.efi" 2>/dev/null | grep -qi '\.efi'; then
echo "** Arranque UEFI: presente (BOOTX64.EFI encontrado en la ISO)"
else
echo "** AVISO: no se encontró ningún .efi en la ISO. El arranque UEFI puede no funcionar."
echo "** Verifica que 'grub-efi-amd64-bin' y 'mtools' estén instalados y vuelve a generar la ISO."
fi
fi
printf "** Puedes probarla con: qemu-system-x86_64 -m 512 -cdrom %s\n\n" "$iso_name"
echo "** Usuario: root"
echo "** Contraseña: $root_password"
else
echo "** Ocurrió un error generando la ISO. Verifica que xorriso/grub-mkrescue estén instalados."
exit 1
fi