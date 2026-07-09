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
# URL base del repositorio de paquetes para "pkg" (ver setup-oky-repo.sh).
pkg_repo_url="http://192.168.0.22"

kernel="https://github.com/oscargfloresb/GNU-Linux/raw/refs/heads/main/linux-6.18.37.tar.xz"

# Paquetes que reemplazan a BusyBox. Todos se compilan desde fuente,
# de preferencia enlazados estáticamente ("-static"), al estilo LFS.
# NOTA: las versiones/URLs pueden quedar desactualizadas; si una descarga
# falla, actualiza la variable correspondiente a la última versión estable.
coreutils_url="https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
util_linux_url="https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.40/util-linux-2.40.2.tar.xz"
bash_url="https://ftp.gnu.org/gnu/bash/bash-5.2.32.tar.gz"
sysvinit_url="https://github.com/slicer69/sysvinit/archive/refs/tags/3.09.tar.gz"
inetutils_url="https://ftp.gnu.org/gnu/inetutils/inetutils-2.5.tar.xz"
iproute2_url="https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.9.0.tar.xz"
grep_url="https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
gzip_url="https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz"
findutils_url="https://ftp.gnu.org/gnu/findutils/findutils-4.9.0.tar.xz"
cpio_url="https://ftp.gnu.org/gnu/cpio/cpio-2.15.tar.gz"
tar_url="https://ftp.gnu.org/gnu/tar/tar-1.35.tar.gz"
wget_url="https://ftp.gnu.org/gnu/wget/wget-1.24.5.tar.gz"
eudev_url="https://github.com/eudev-project/eudev/releases/download/v3.2.14/eudev-3.2.14.tar.gz"
darkhttpd_url="https://raw.githubusercontent.com/emikulic/darkhttpd/master/darkhttpd.c"
dcron_url="https://github.com/dubiousjim/dcron/archive/refs/heads/master.tar.gz"
dhcpcd_url="https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.0.6/dhcpcd-10.0.6.tar.xz"
dosfstools_url="https://github.com/dosfstools/dosfstools/releases/download/v4.2/dosfstools-4.2.tar.gz"
e2fsprogs_url="https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.1/e2fsprogs-1.47.1.tar.gz"
vim_url="https://github.com/vim/vim/archive/refs/tags/v9.1.1401.tar.gz"
procps_url="https://sourceforge.net/projects/procps-ng/files/Production/procps-ng-3.3.17.tar.xz/download"
shadow_url="https://github.com/shadow-maint/shadow/releases/download/4.15.1/shadow-4.15.1.tar.xz"

iso_name="${distro_name}-${version}.iso"
workdir="$(pwd)"
isodir="$workdir/isoroot"
root_password=""
root_hash=""

if [ $(id -u) -ne 0 ]; then
echo "Run as root"; exit 1
fi
clear
# Todo el script corre como root; varios paquetes GNU (coreutils, grep,
# findutils, gzip, cpio, inetutils...) usan gnulib y por defecto se niegan
# a correr "configure" como root. Esto lo habilita explícitamente.
export FORCE_UNSAFE_CONFIGURE=1

required_pkgs="ca-certificates wget build-essential libncurses-dev \
bison flex libelf-dev chrpath gawk texinfo libsdl1.2-dev whiptail diffstat cpio \
libssl-dev bc grub-pc-bin grub-efi-amd64-bin grub-common grub2-common xorriso mtools dosfstools parted \
autoconf automake libtool pkg-config gperf m4 libcrypt-dev netbase zlib1g-dev libzstd-dev"
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

# ---------------------------------------------------------------------------
# Ayudantes genéricos de descarga/extracción/compilación de paquetes fuente.
# ---------------------------------------------------------------------------
fetch_source () {
url="$1"; out="$2"
reuse="n"
if [ -f "$out" ]; then
printf "** Se encontró %s ya descargado. ¿Usarlo sin volver a descargar? (y/n): " "$out"
read reuse
fi
if [ "$reuse" != "y" ]; then
rm -f "$out"
wget "$url" -O "$out" || { echo "** Falló la descarga de $out."; exit 1; }
fi
}

extract_source () {
tarball="$1"; destdir="$2"
rm -rf "$destdir"
mkdir -p "$destdir"
tar -xf "$tarball" -C "$destdir" --strip-components=1 || { echo "** Falló la extracción de $destdir."; exit 1; }
}

# Compila un paquete autotools de forma estática. Si ya existe una marca
# ".built" en files/<nombre>, pregunta si se debe reutilizar.
build_autotools () {
name="$1"; url="$2"; extra="$3"
cd "$workdir/files" || exit 1
case "$url" in
*.tar.xz) tarball="${name}-src.tar.xz" ;;
*.tar.bz2) tarball="${name}-src.tar.bz2" ;;
*) tarball="${name}-src.tar.gz" ;;
esac
answer="n"
if [ -f "$name/.built" ]; then
printf "** Se detectó una compilación previa de %s. ¿Reutilizarla? (y/n): " "$name"
read answer
fi
if [ "$answer" = "y" ]; then
cd "$workdir"
return 0
fi
fetch_source "$url" "$tarball"
extract_source "$tarball" "$name"
cd "$name" || exit 1
FORCE_UNSAFE_CONFIGURE=1 CFLAGS="-static -O2" LDFLAGS="-static" ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var $extra \
|| { echo "** Falló el configure de $name."; exit 1; }
make -j"$(nproc)" || { echo "** Falló la compilación de $name."; exit 1; }
touch .built
cd "$workdir"
}

echo "** Compilando utilidades base (reemplazo de BusyBox)..."

build_autotools coreutils "$coreutils_url" "--disable-nls --disable-acl --disable-xattr --disable-libcap --without-selinux"
build_autotools util-linux "$util_linux_url" "--disable-nls --disable-shared --without-python --without-systemd --without-udev --disable-widechar --disable-liblastlog2 --disable-cfdisk --without-ncurses --without-ncursesw"
build_autotools bash "$bash_url" "--without-bash-malloc --enable-static-link"
build_autotools inetutils "$inetutils_url" "--disable-nls --disable-ipv6 --disable-libcap --disable-rcp --disable-rexec --disable-rlogin --disable-rlogind --disable-rsh --disable-rshd --disable-talk --disable-talkd --disable-tftp --disable-tftpd --disable-uucpd --disable-whois"
build_autotools grep "$grep_url" "--disable-nls"
build_autotools gzip "$gzip_url" "--disable-nls"
build_autotools findutils "$findutils_url" "--disable-nls --without-selinux"
build_autotools cpio "$cpio_url" "--disable-nls --without-selinux"
build_autotools tar "$tar_url" "--disable-nls --without-selinux"
build_autotools dosfstools "$dosfstools_url" ""
build_autotools e2fsprogs "$e2fsprogs_url" "--disable-nls --disable-libuuid --disable-uuidd --disable-fsck --disable-e2initrd-helper"
build_autotools shadow "$shadow_url" "--without-libpam --without-audit --without-selinux --without-acl --without-attr --without-tcb --without-cracklib --without-nscd --without-subordinate-ids --disable-account-tools-setuid --without-btrfs"

# wget: aparte de build_autotools porque necesita LIBS=-lzstd extra (la
# libcrypto.a estática del host trae soporte zstd compilado, y si no se
# linkea explícito contra libzstd el enlazado final falla).
answer="n"
if [ -f files/wget/.built ]; then
printf "** Se detectó una compilación previa de wget. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$wget_url" wget-src.tar.gz
extract_source wget-src.tar.gz wget
cd wget
FORCE_UNSAFE_CONFIGURE=1 CFLAGS="-static -O2" LDFLAGS="-static" LIBS="-lzstd" \
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
--disable-nls --with-ssl=openssl --without-libpsl \
|| { echo "** Falló el configure de wget."; exit 1; }
make -j"$(nproc)" || { echo "** Falló la compilación de wget."; exit 1; }
touch .built
cd ../..
fi

# vim: su configure está en src/, no en la raíz del tarball. Se compila
# dinámico (como GRUB/parted/eudev) porque necesita ncurses para dibujar
# la pantalla; sus libs se copian al rootfs igual que a esos otros.
answer="n"
if [ -f files/vim/.built ]; then
printf "** Se detectó una compilación previa de vim. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$vim_url" vim-src.tar.gz
extract_source vim-src.tar.gz vim
cd vim/src
./configure --prefix=/usr --with-features=normal --disable-gui --without-x \
--disable-netbeans --disable-channel --disable-nls \
|| { echo "** Falló el configure de vim."; exit 1; }
make -j"$(nproc)" || { echo "** Falló la compilación de vim."; exit 1; }
touch ../.built
cd ../../..
fi

# procps-ng: ps, top, free, kill, w, etc. Última versión con autotools
# (las posteriores usan meson); dinámico, sin ncurses (solo lo usaría
# 'watch', que no es crítico).
answer="n"
if [ -f files/procps/.built ]; then
printf "** Se detectó una compilación previa de procps. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$procps_url" procps-src.tar.xz
extract_source procps-src.tar.xz procps
cd procps
./configure --prefix=/usr --disable-nls \
|| { echo "** Falló el configure de procps."; exit 1; }
make -j"$(nproc)" || { echo "** Falló la compilación de procps."; exit 1; }
touch .built
cd ../..
fi

# sysvinit: Makefile propio, no autotools.
answer="n"
if [ -f files/sysvinit/.built ]; then
printf "** Se detectó una compilación previa de sysvinit. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$sysvinit_url" sysvinit-src.tar.gz
extract_source sysvinit-src.tar.gz sysvinit
cd sysvinit
make CFLAGS="-static -O2" LDFLAGS="-static" || { echo "** Falló la compilación de sysvinit."; exit 1; }
touch .built
cd ../..
fi

# eudev: se compila dinámico (enlazar estático es frágil); sus dependencias
# se resuelven copiando las bibliotecas con ldd, igual que con grub/parted.
answer="n"
if [ -f files/eudev/.built ]; then
printf "** Se detectó una compilación previa de eudev. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$eudev_url" eudev-src.tar.gz
extract_source eudev-src.tar.gz eudev
cd eudev
./configure --prefix=/usr --disable-manpages --disable-introspection --disable-hwdb --disable-blkid --without-systemd \
|| { echo "** Falló el configure de eudev."; exit 1; }
make -j"$(nproc)" || { echo "** Falló la compilación de eudev."; exit 1; }
touch .built
cd ../..
fi

# darkhttpd: un solo archivo C, sustituye al httpd de BusyBox.
answer="n"
if [ -f files/darkhttpd/.built ]; then
printf "** Se detectó una compilación previa de darkhttpd. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
mkdir -p files/darkhttpd
cd files/darkhttpd
fetch_source "$darkhttpd_url" darkhttpd.c
gcc -static -O2 -o darkhttpd darkhttpd.c || { echo "** Falló la compilación de darkhttpd."; exit 1; }
touch .built
cd ../..
fi

# dcron: Makefile propio, sustituye al crond de BusyBox.
answer="n"
if [ -f files/dcron/.built ]; then
printf "** Se detectó una compilación previa de dcron. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$dcron_url" dcron-src.tar.gz
extract_source dcron-src.tar.gz dcron
cd dcron
make CFLAGS="-static -O2" LDFLAGS="-static" || { echo "** Falló la compilación de dcron."; exit 1; }
touch .built
cd ../..
fi

# dhcpcd: configure propio (no autotools), sustituye a udhcpc de BusyBox.
answer="n"
if [ -f files/dhcpcd/.built ]; then
printf "** Se detectó una compilación previa de dhcpcd. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$dhcpcd_url" dhcpcd-src.tar.xz
extract_source dhcpcd-src.tar.xz dhcpcd
cd dhcpcd
CFLAGS="-static -O2" LDFLAGS="-static" ./configure --prefix=/usr --sbindir=/sbin \
--sysconfdir=/etc --localstatedir=/var --without-dev --disable-privsep --with-hook=resolv.conf \
|| { echo "** Falló el configure de dhcpcd."; exit 1; }
make -j"$(nproc)" || { echo "** Falló la compilación de dhcpcd."; exit 1; }
touch .built
cd ../..
fi

# iproute2: Makefile propio con un ./configure auxiliar que genera config.mk.
answer="n"
if [ -f files/iproute2/.built ]; then
printf "** Se detectó una compilación previa de iproute2. ¿Reutilizarla? (y/n): "
read answer
fi
if [ "$answer" != "y" ]; then
cd files
fetch_source "$iproute2_url" iproute2-src.tar.xz
extract_source iproute2-src.tar.xz iproute2
cd iproute2
./configure || true
make -k || true
if [ ! -f ip/ip ]; then
echo "** Falló la compilación de iproute2 (no se generó ip/ip)."; exit 1
fi
touch .built
cd ../..
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
./scripts/config --enable CONFIG_SERIAL_8250
./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
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
mkdir -p bin boot dev lib lib64 run mnt/root proc sbin sys tmp home var/log usr/local/bin var/spool/cron/crontabs etc/init.d etc/rc.d var/run var/www/html etc/network/if-down.d etc/network/if-post-down.d etc/network/if-pre-up.d etc/network/if-up.d run etc/cron/daily etc/cron/hourly etc/cron/monthly etc/cron/weekly usr/share var/db/dhcpcd var/run/dhcpcd var/mail
# /usr se fusiona con / (usrmerge): simplifica saber a dónde va cada binario,
# ya que ahora todo entra en bin/ o sbin/ y usr/bin, usr/sbin son enlaces.
ln -s ../bin usr/bin
ln -s ../sbin usr/sbin
install -d -m 0750 root
install -d -m 1777 tmp

echo "** Instalando utilidades base en el rootfs (sin BusyBox)..."
copy_bins () {
# copy_bins <directorio-de-búsqueda> <destino>
srcdir="$1"; dest="$2"
find "$srcdir" -maxdepth 1 -type f -perm -u+x -exec cp {} "$dest/" \; 2>/dev/null
}

copy_bins ../files/coreutils/src bin
copy_bins ../files/findutils/find bin
copy_bins ../files/findutils/xargs bin
cp ../files/grep/src/grep bin/ 2>/dev/null || find ../files/grep -mindepth 1 -maxdepth 2 -type f -name grep -exec cp {} bin/ \;
cp ../files/gzip/gzip bin/ 2>/dev/null || find ../files/gzip -mindepth 1 -maxdepth 2 -type f -name gzip -exec cp {} bin/ \;
cp ../files/cpio/cpio bin/ 2>/dev/null || find ../files/cpio -mindepth 1 -maxdepth 2 -type f -name cpio -exec cp {} bin/ \;
cp ../files/tar/src/tar bin/ 2>/dev/null || find ../files/tar -mindepth 1 -maxdepth 2 -type f -name tar -exec cp {} bin/ \;
cp ../files/wget/src/wget bin/ 2>/dev/null || find ../files/wget -mindepth 1 -maxdepth 2 -type f -name wget -exec cp {} bin/ \;
if [ -f bin/wget ]; then
for lib in $(ldd bin/wget 2>/dev/null | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/ 2>/dev/null
done
fi
cp ../files/bash/bash bin/ || { echo "** No se encontró el binario de bash compilado."; exit 1; }
ln -sf bash bin/sh

copy_bins ../files/util-linux sbin

# shadow-utils: gestión real de usuarios/contraseñas (passwd, useradd, su...)
for b in passwd useradd userdel usermod groupadd groupdel groupmod \
chpasswd chage chsh chfn newgrp gpasswd su newusers vipw vigr; do
src=$(find ../files/shadow -maxdepth 4 -type f -perm -u+x -name "$b" 2>/dev/null | head -1)
[ -n "$src" ] && cp "$src" bin/"$b"
done
# a pesar de compilar con -static, algunos binarios de shadow-utils
# quedan enlazados dinámico contra libbsd u otras libs del sistema.
for b in passwd useradd userdel usermod groupadd groupdel groupmod \
chpasswd chage chsh chfn newgrp gpasswd su newusers vipw vigr; do
[ -f "bin/$b" ] || continue
for lib in $(ldd "bin/$b" 2>/dev/null | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/ 2>/dev/null
done
done
# passwd/su/chsh/chfn/newgrp/gpasswd necesitan setuid root: sin esto,
# un usuario sin privilegios no podría ni siquiera cambiar su propia clave.
for b in passwd su chsh chfn newgrp gpasswd; do
[ -f bin/$b ] && chmod 4755 bin/$b
done
if [ -f bin/useradd ]; then
cat << 'EOF' > bin/adduser
#!/bin/sh
if [ -z "$1" ]; then
echo "Uso: adduser usuario"
exit 1
fi
useradd -m -s /bin/bash "$1" || exit 1
echo "Creando cuenta para $1..."
passwd "$1"
EOF
chmod 755 bin/adduser
fi
copy_bins ../files/dhcpcd/src sbin
cp ../files/dhcpcd/dhcpcd sbin/ 2>/dev/null
if [ -d ../files/dhcpcd/hooks ]; then
mkdir -p usr/libexec/dhcpcd-hooks
cp ../files/dhcpcd/hooks/dhcpcd-run-hooks usr/libexec/ 2>/dev/null
find ../files/dhcpcd/hooks -maxdepth 1 -type f ! -name 'dhcpcd-run-hooks*' ! -name '*.in' ! -name '*.8' -exec cp {} usr/libexec/dhcpcd-hooks/ \; 2>/dev/null
chmod 755 usr/libexec/dhcpcd-run-hooks 2>/dev/null
chmod 755 usr/libexec/dhcpcd-hooks/* 2>/dev/null
fi
copy_bins ../files/iproute2/ip sbin
if [ -f sbin/ip ]; then
for lib in $(ldd sbin/ip 2>/dev/null | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/ 2>/dev/null
done
fi

cp ../files/sysvinit/src/init sbin/ 2>/dev/null || find ../files/sysvinit -maxdepth 2 -name init -type f -exec cp {} sbin/ \;
for b in halt shutdown killall5 pidof sulogin runlevel wall; do
find ../files/sysvinit -maxdepth 2 -type f -name "$b" -exec cp {} sbin/ \; 2>/dev/null
done
ln -sf halt sbin/poweroff
ln -sf halt sbin/reboot

for b in telnetd ftpd syslogd hostname ifconfig ping ping6 traceroute logger; do
find ../files/inetutils -maxdepth 3 -type f -perm -u+x -name "$b" -exec cp {} sbin/ \; 2>/dev/null
done

find ../files/eudev -maxdepth 3 -type f -perm -u+x -name 'udevd' -exec cp {} sbin/ \; 2>/dev/null
find ../files/eudev -maxdepth 3 -type f -perm -u+x -name 'udevadm' -exec cp {} sbin/ \; 2>/dev/null

# vim (enlazado dinámico, necesita ncurses + terminfo)
find ../files/vim/src -maxdepth 1 -type f -perm -u+x -name vim -exec cp {} bin/vim \; 2>/dev/null
if [ -f bin/vim ]; then
ln -sf vim bin/vi
ln -sf vim bin/ex
ln -sf vim bin/view
for lib in $(ldd bin/vim 2>/dev/null | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/ 2>/dev/null
done
fi
mkdir -p usr/share
cp -a /usr/share/terminfo usr/share/ 2>/dev/null
mkdir -p etc/ssl/certs
cp -a /etc/ssl/certs/ca-certificates.crt etc/ssl/certs/ 2>/dev/null
cat << 'EOF' > etc/wgetrc
ca_certificate = /etc/ssl/certs/ca-certificates.crt
EOF
mkdir -p usr/share/vim
cp -a ../files/vim/runtime usr/share/vim/vim91 2>/dev/null

# clear/tput: no los compilamos aparte, se copian del host (dinámicos,
# contra la misma ncurses/terminfo que ya usa vim).
for b in clear tput; do
[ -f /usr/bin/$b ] || continue
cp /usr/bin/$b bin/ 2>/dev/null
for lib in $(ldd /usr/bin/$b 2>/dev/null | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/ 2>/dev/null
done
done

# procps-ng (ps, top, free, kill con nombre real, etc; enlazado dinámico)
for b in ps top free kill pkill pgrep w uptime vmstat slabtop tload sysctl pmap skill snice watch; do
src=$(find ../files/procps -path '*/.libs/*' -type f -perm -u+x \( -name "$b" -o -name "lt-$b" \) 2>/dev/null | head -1)
[ -z "$src" ] && src=$(find ../files/procps -maxdepth 4 -type f -perm -u+x -name "$b" 2>/dev/null | head -1)
# procps-ng compila 'ps' con el nombre 'pscommand' (para no chocar con
# el nombre reservado 'ps' en su propio Makefile/automake).
[ -z "$src" ] && [ "$b" = "ps" ] && src=$(find ../files/procps -maxdepth 4 -type f -perm -u+x -name pscommand 2>/dev/null | head -1)
[ -n "$src" ] && cp "$src" bin/"$b"
done
# -type f solo copiaba el .so real (ej. libprocps.so.8.0.3), no los symlinks
# libprocps.so / libprocps.so.8 que el binario realmente busca por nombre.
find ../files/procps -path '*/.libs/*' \( -type f -o -type l \) -name 'libproc*.so*' -exec cp -a {} lib/ \; 2>/dev/null
for b in ps top free kill pkill pgrep w uptime vmstat slabtop tload sysctl pmap skill snice watch; do
[ -f "bin/$b" ] || continue
for lib in $(ldd "bin/$b" 2>/dev/null | awk '{print $3}' | grep '^/'); do
cp -n "$lib" lib/ 2>/dev/null
done
done

cp ../files/darkhttpd/darkhttpd usr/sbin/httpd 2>/dev/null
mkdir -p usr/sbin
[ -f ../files/darkhttpd/darkhttpd ] && cp ../files/darkhttpd/darkhttpd usr/sbin/httpd

find ../files/dcron -maxdepth 2 -type f -perm -u+x -name 'crond' -exec cp {} usr/sbin/ \; 2>/dev/null

find ../files/dosfstools -maxdepth 3 -type f -perm -u+x -name 'mkfs.fat' -exec cp {} sbin/mkfs.vfat \; 2>/dev/null
find ../files/e2fsprogs -maxdepth 3 -type f -perm -u+x -name 'mke2fs' -exec cp {} sbin/mkfs.ext2 \; 2>/dev/null
find ../files/e2fsprogs -maxdepth 3 -type f -perm -u+x -name 'e2fsck' -exec cp {} sbin/ \; 2>/dev/null

# login propio y mínimo (util-linux no compila el suyo sin PAM, y no
# queremos meter todo el stack de PAM para algo tan puntual).
cat << 'LOGINEOF' > ../files/login.c
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <crypt.h>
#include <termios.h>
#include <sys/types.h>

struct account {
	char name[64];
	char home[256];
	char shell[64];
	uid_t uid;
	gid_t gid;
};

/* Se parsea /etc/passwd y /etc/shadow a mano, sin pasar por NSS
 * (getpwnam/getspnam dependen de poder cargar libnss_*.so en tiempo de
 * ejecucion, algo que en este sistema minimo resulto poco confiable:
 * fallaba en el primer intento de login y funcionaba en el segundo). */
static int find_account(const char *user, struct account *out)
{
	FILE *f = fopen("/etc/passwd", "r");
	char line[512];
	int found = 0;

	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f)) {
		char *save = NULL;
		char *name = strtok_r(line, ":", &save);
		char *passwd = strtok_r(NULL, ":", &save);
		char *uid_s = strtok_r(NULL, ":", &save);
		char *gid_s = strtok_r(NULL, ":", &save);
		char *gecos = strtok_r(NULL, ":", &save);
		char *home = strtok_r(NULL, ":", &save);
		char *shell = strtok_r(NULL, ":\n", &save);
		(void)passwd;
		(void)gecos;
		if (!name || strcmp(name, user) != 0)
			continue;
		memset(out, 0, sizeof(*out));
		strncpy(out->name, name, sizeof(out->name) - 1);
		out->uid = uid_s ? (uid_t)atoi(uid_s) : 0;
		out->gid = gid_s ? (gid_t)atoi(gid_s) : 0;
		strncpy(out->home, (home && home[0]) ? home : "/", sizeof(out->home) - 1);
		strncpy(out->shell, (shell && shell[0]) ? shell : "/bin/sh", sizeof(out->shell) - 1);
		found = 1;
		break;
	}
	fclose(f);
	return found;
}

static int find_shadow_hash(const char *user, char *hash, size_t hashlen)
{
	FILE *f = fopen("/etc/shadow", "r");
	char line[512];
	int found = 0;

	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f)) {
		char *save = NULL;
		char *name = strtok_r(line, ":", &save);
		char *h = strtok_r(NULL, ":\n", &save);
		if (!name || strcmp(name, user) != 0)
			continue;
		strncpy(hash, h ? h : "", hashlen - 1);
		hash[hashlen - 1] = '\0';
		found = 1;
		break;
	}
	fclose(f);
	return found;
}

static void read_password(char *buf, size_t len)
{
	struct termios oldt, newt;
	size_t n;
	tcgetattr(STDIN_FILENO, &oldt);
	newt = oldt;
	newt.c_lflag &= ~ECHO;
	tcsetattr(STDIN_FILENO, TCSANOW, &newt);
	if (fgets(buf, len, stdin) == NULL)
		buf[0] = '\0';
	tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
	printf("\n");
	n = strlen(buf);
	if (n && buf[n - 1] == '\n')
		buf[n - 1] = '\0';
}

int main(int argc, char **argv)
{
	char user[256];
	char pass[256];
	char hash[256];
	size_t n;
	int idx = 1;
	int have_argv_user;

	if (idx < argc && strcmp(argv[idx], "--") == 0)
		idx++;
	have_argv_user = (idx < argc && argv[idx][0] != '\0');

	if (have_argv_user) {
		strncpy(user, argv[idx], sizeof(user) - 1);
		user[sizeof(user) - 1] = '\0';
	}

	for (;;) {
		if (!have_argv_user) {
			printf("login: ");
			fflush(stdout);
			if (fgets(user, sizeof(user), stdin) == NULL) {
				printf("\n");
				continue;
			}
			n = strlen(user);
			if (n && user[n - 1] == '\n')
				user[n - 1] = '\0';
			if (user[0] == '\0')
				continue;
		}
		have_argv_user = 0;

		printf("Password: ");
		fflush(stdout);
		tcflush(STDIN_FILENO, TCIFLUSH);
		read_password(pass, sizeof(pass));

		struct account acc;
		if (!find_account(user, &acc)) {
			printf("Login incorrect\n\n");
			continue;
		}

		if (!find_shadow_hash(user, hash, sizeof(hash)))
			hash[0] = '\0';

		char *result = hash[0] ? crypt(pass, hash) : NULL;
		memset(pass, 0, sizeof(pass));
		if (!result || !hash[0] || strcmp(result, hash) != 0) {
			printf("Login incorrect\n\n");
			continue;
		}

		if (setgid(acc.gid) != 0) {
			perror("setgid");
			exit(1);
		}
		if (setuid(acc.uid) != 0) {
			perror("setuid");
			exit(1);
		}

		if (chdir(acc.home) != 0)
			chdir("/");

		setenv("HOME", acc.home, 1);
		setenv("SHELL", acc.shell, 1);
		setenv("USER", acc.name, 1);
		setenv("LOGNAME", acc.name, 1);

		char argv0[257];
		const char *base = strrchr(acc.shell, '/');
		base = base ? base + 1 : acc.shell;
		snprintf(argv0, sizeof(argv0), "-%s", base);

		execl(acc.shell, argv0, (char *)NULL);
		perror("exec shell");
		exit(1);
	}
}
LOGINEOF
gcc -O2 -o ../files/login-bin ../files/login.c -lcrypt 2>../files/login-build.log \
|| { echo "** Falló la compilación de login (ver files/login-build.log)."; exit 1; }
cp ../files/login-bin bin/login
chmod 755 bin/login

for i in $(find /lib/ | grep 'ld-2\|ld-lin\|libc.so\|libnss_dns\|libnss_files\|libnss_compat\|libresolv\|libcrypt'); do
cp ${i} lib
done
cp ../files/linux/arch/$arch/boot/bzImage boot/vmlinuz

# Herramientas dinámicas: GRUB, parted y eudev (udevd/udevadm) se enlazan
# contra glibc dinámica, así que copiamos también sus bibliotecas.
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
for eb in ../files/eudev/src/udev/udevd ../files/eudev/src/udev/udevadm; do
[ -f "$eb" ] || continue
for lib in $(ldd "$eb" 2>/dev/null | awk '{print $3}' | grep '^/'); do
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
lastchange_day=$(( $(date +%s) / 86400 ))
printf "root:%s:%s::::::\nservice:!:%s::::::\n" "$root_hash" "$lastchange_day" "$lastchange_day" > etc/shadow
printf "root:x:0:root\nservice:x:1:service\nmail:x:8:\n" > etc/group
printf "root:*::root\nservice:*::service\nmail:*::\n" > etc/gshadow
echo "/bin/sh" > etc/shells
echo "127.0.0.1	 localhost $host" > etc/hosts
cp /etc/protocols etc/protocols 2>/dev/null
cp /etc/services etc/services 2>/dev/null
cat << EOF > etc/syslog.conf
*.*	/var/log/messages
EOF
touch var/log/messages
cat << EOF > etc/nsswitch.conf
passwd:    files
group:     files
shadow:    files
hosts:     files dns
networks:  files
protocols: files
services:  files
EOF
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
trap "printf '\033[H\033[2J'" 0
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

# /etc/inittab en formato sysvinit real (id:runlevels:acción:proceso).
# sysvinit NO tiene una acción "shutdown" (eso es un invento de BusyBox);
# el mecanismo real es entrar a runlevel 0 (halt) o 6 (reboot).
cat << EOF > etc/inittab
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
1:2345:respawn:/sbin/agetty 38400 tty1
2:2345:respawn:/sbin/agetty 38400 tty2
3:2345:respawn:/sbin/agetty 38400 tty3
4:2345:respawn:/sbin/agetty 38400 tty4
ca::ctrlaltdel:/sbin/reboot
l0:0:wait:/etc/init.d/halt
l6:6:wait:/etc/init.d/reboot
EOF

cat << 'EOF' > etc/init.d/halt
#!/bin/sh
/etc/init.d/rcK
umount -a -r
swapoff -a
exec poweroff -d -f
EOF

cat << 'EOF' > etc/init.d/reboot
#!/bin/sh
/etc/init.d/rcK
umount -a -r
swapoff -a
exec reboot -d -f
EOF

cat << EOF > etc/network/interfaces
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF

cat << EOF > etc/dhcpcd.conf
# Configuración mínima de dhcpcd para $distro_name
duid
persistent
option rapid_commit
option domain_name_servers, domain_name
require dhcp_server_identifier
slaac private
EOF

cat << EOF > etc/login.defs
ENCRYPT_METHOD SHA512
PATH=/bin:/sbin:/usr/bin:/usr/sbin
MAIL_DIR /var/mail
UMASK 022
LOGIN_RETRIES 5
LOGIN_TIMEOUT 60
EOF

# /etc/inetd.conf: reemplaza al tcpsvd de BusyBox para telnetd/ftpd,
# usando el inetd real que trae inetutils.
{
[ "$telnetd_enabled" = "true" ] && echo "telnet stream tcp nowait root /sbin/telnetd telnetd"
echo "ftp    stream tcp nowait root /sbin/ftpd ftpd -l"
} > etc/inetd.conf

cat << EOF > init
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
exec 2>/dev/console
mountpoint -q proc || mount -t proc proc proc
mountpoint -q sys || mount -t sysfs sys sys
if ! mountpoint -q dev
then
mount -t devtmpfs devtmpfs dev
mkdir -p dev/pts
/sbin/udevd --daemon
/sbin/udevadm trigger --action=add
/sbin/udevadm settle
fi
echo 0 > /proc/sys/kernel/printk
[ -f /etc/hostname ] && cat /etc/hostname > /proc/sys/kernel/hostname 2>/dev/null
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
/sbin/udevadm trigger --action=add 2>/dev/null
/sbin/udevadm settle 2>/dev/null
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
/sbin/udevadm trigger --action=add 2>/dev/null
/sbin/udevadm settle 2>/dev/null
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
if command -v "\$1" >/dev/null 2>&1
then
printf '\033[H\033[2J'
head="\$(echo \$1 | tr 'a-z' 'A-Z')(1)\\t\\t\\tManual page\\n"
body="\$("\$1" --help 2>&1)\\n\\n"
if command -v more >/dev/null 2>&1
then
printf "\$head\$body" | more
elif command -v vim >/dev/null 2>&1
then
printf "\$head\$body" | vim -R -c 'set nomodified' -
else
printf "\$head\$body"
fi
exit 0
fi
echo "No manual entry for \$1"
EOF

# pkg: gestor de paquetes mínimo para $distro_name.
# Formato del paquete (.tar.gz):
#   pkginfo   -> metadatos: NAME=, VERSION=, DESC=
#   data/     -> árbol de archivos, tal cual se copian a /
cat << 'EOF' > usr/sbin/pkg
#!/bin/sh
DBDIR=/var/lib/pkg
CONF=/etc/pkg.conf
mkdir -p "$DBDIR"

REPO=""
[ -f "$CONF" ] && . "$CONF"

usage() {
cat << USAGE
Uso: pkg install <archivo.tar.gz o nombre> | remove <nombre> | list | info <nombre> | update | search <término>

Si <nombre> no es un archivo local, se busca en el índice del
repositorio (ver 'pkg update' y $CONF).
USAGE
exit 1
}

# Lee "CLAVE=valor" de un pkginfo como texto plano (sin ejecutarlo como
# shell), para no romperse con valores con espacios ni correr código.
pkginfo_get() {
grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

# Índice del repo: una línea por paquete, "NOMBRE|VERSION|ARCHIVO|DESCRIPCION"
repo_lookup() {
[ -f "$DBDIR/repo.index" ] || return 1
grep "^$1|" "$DBDIR/repo.index" | head -1
}

cmd_update() {
[ -n "$REPO" ] || { echo "pkg: no hay REPO configurado en $CONF"; exit 1; }
echo "Actualizando índice desde $REPO..."
if ! wget -O "$DBDIR/repo.index.tmp" "$REPO/index"; then
echo "pkg: no pude descargar el índice de $REPO (ver el error de wget arriba)."
rm -f "$DBDIR/repo.index.tmp"
exit 1
fi
mv "$DBDIR/repo.index.tmp" "$DBDIR/repo.index"
echo "Índice actualizado ($(wc -l < "$DBDIR/repo.index") paquetes disponibles)."
}

cmd_search() {
term="$1"
[ -f "$DBDIR/repo.index" ] || { echo "pkg: no hay índice descargado, corré 'pkg update' primero"; exit 1; }
[ -n "$term" ] || { echo "Uso: pkg search <término>"; exit 1; }
found=0
while IFS='|' read -r n v f d; do
case "$n $d" in
*"$term"*) echo "$n $v - $d"; found=1 ;;
esac
done < "$DBDIR/repo.index"
[ "$found" = 0 ] && echo "(sin resultados para '$term')"
}

cmd_install() {
arg="$1"
[ -n "$arg" ] || { echo "pkg: falta el nombre o archivo del paquete"; exit 1; }
downloaded=""

if [ -f "$arg" ]; then
pkgfile="$arg"
else
line=$(repo_lookup "$arg")
if [ -z "$line" ]; then
echo "pkg: '$arg' no es un archivo local ni está en el índice del repositorio."
echo "pkg: si es un paquete remoto, corré 'pkg update' primero."
exit 1
fi
rname=$(echo "$line" | cut -d'|' -f1)
rver=$(echo "$line" | cut -d'|' -f2)
rfile=$(echo "$line" | cut -d'|' -f3)
rdesc=$(echo "$line" | cut -d'|' -f4-)
[ -n "$REPO" ] || { echo "pkg: no hay REPO configurado en $CONF"; exit 1; }
echo "Encontrado en el repositorio: $rname $rver - ${rdesc:-sin descripción}"
printf "¿Descargar e instalar desde %s? (y/n): " "$REPO"
read ans
[ "$ans" = "y" ] || { echo "pkg: instalación cancelada."; exit 1; }
pkgfile=$(mktemp /tmp/pkgdl.XXXXXX) || exit 1
downloaded="$pkgfile"
echo "Descargando $rfile..."
wget -O "$pkgfile" "$REPO/$rfile" || { echo "pkg: no pude descargar $REPO/$rfile (ver el error de wget arriba)."; rm -f "$pkgfile"; exit 1; }
fi

tmpdir=$(mktemp -d /tmp/pkg.XXXXXX) || { [ -n "$downloaded" ] && rm -f "$downloaded"; exit 1; }
tar -xzf "$pkgfile" -C "$tmpdir" || { echo "pkg: no pude extraer $pkgfile"; rm -rf "$tmpdir"; [ -n "$downloaded" ] && rm -f "$downloaded"; exit 1; }
info="$tmpdir/pkginfo"
[ -f "$info" ] || { echo "pkg: el paquete no tiene 'pkginfo'"; rm -rf "$tmpdir"; [ -n "$downloaded" ] && rm -f "$downloaded"; exit 1; }
NAME=$(pkginfo_get "$info" NAME)
VERSION=$(pkginfo_get "$info" VERSION)
DESC=$(pkginfo_get "$info" DESC)
[ -n "$NAME" ] || { echo "pkg: pkginfo sin NAME"; rm -rf "$tmpdir"; [ -n "$downloaded" ] && rm -f "$downloaded"; exit 1; }

nfiles=0
[ -d "$tmpdir/data" ] && nfiles=$(cd "$tmpdir/data" && find . \( -type f -o -type l \) | wc -l)

echo "Paquete:     $NAME"
echo "Versión:     ${VERSION:-desconocida}"
echo "Descripción: ${DESC:-sin descripción}"
echo "Archivos a instalar: $nfiles"

if [ -f "$DBDIR/$NAME.files" ]; then
oldver=$(pkginfo_get "$DBDIR/$NAME.info" VERSION)
echo "Ya hay una versión instalada: ${oldver:-desconocida}"
printf "¿Reinstalar '%s'? (y/n): " "$NAME"
read ans
[ "$ans" = "y" ] || { echo "pkg: instalación cancelada."; rm -rf "$tmpdir"; [ -n "$downloaded" ] && rm -f "$downloaded"; exit 1; }
fi

: > "$DBDIR/$NAME.files"
if [ -d "$tmpdir/data" ]; then
( cd "$tmpdir/data" && find . \( -type f -o -type l \) ) | while read -r f; do
rel="${f#./}"
dest="/$rel"
mkdir -p "$(dirname "$dest")"
cp -a "$tmpdir/data/$rel" "$dest"
echo "$dest" >> "$DBDIR/$NAME.files"
done
fi
cp "$info" "$DBDIR/$NAME.info"
rm -rf "$tmpdir"
[ -n "$downloaded" ] && rm -f "$downloaded"
echo "$NAME instalado ($(wc -l < "$DBDIR/$NAME.files") archivos)."
}

cmd_remove() {
name="$1"
[ -n "$name" ] && [ -f "$DBDIR/$name.files" ] || { echo "pkg: '$name' no está instalado"; exit 1; }
version=$(pkginfo_get "$DBDIR/$name.info" VERSION)
desc=$(pkginfo_get "$DBDIR/$name.info" DESC)
nfiles=$(wc -l < "$DBDIR/$name.files")

echo "Paquete:     $name"
echo "Versión:     ${version:-desconocida}"
echo "Descripción: ${desc:-sin descripción}"
echo "Se van a eliminar $nfiles archivos:"
cat "$DBDIR/$name.files"
printf "¿Eliminar '%s'? (y/n): " "$name"
read ans
[ "$ans" = "y" ] || { echo "pkg: eliminación cancelada."; exit 1; }

while read -r f; do
[ -f "$f" ] || [ -L "$f" ] && rm -f "$f"
done < "$DBDIR/$name.files"
rm -f "$DBDIR/$name.files" "$DBDIR/$name.info"
echo "$name eliminado."
}

cmd_list() {
found=0
for f in "$DBDIR"/*.info; do
[ -f "$f" ] || continue
found=1
n=$(pkginfo_get "$f" NAME)
v=$(pkginfo_get "$f" VERSION)
d=$(pkginfo_get "$f" DESC)
echo "$n ${v:-?} - ${d:-sin descripción}"
done
[ "$found" = 0 ] && echo "(no hay paquetes instalados)"
}

cmd_info() {
name="$1"
[ -f "$DBDIR/$name.info" ] || { echo "pkg: '$name' no está instalado"; exit 1; }
cat "$DBDIR/$name.info"
echo "Archivos:"
cat "$DBDIR/$name.files"
}

case "$1" in
install) shift; cmd_install "$1" ;;
remove) shift; cmd_remove "$1" ;;
update) cmd_update ;;
search) shift; cmd_search "$1" ;;
list) cmd_list ;;
info) shift; cmd_info "$1" ;;
*) usage ;;
esac
EOF
chmod 755 usr/sbin/pkg
mkdir -p var/lib/pkg

# Paquete de ejemplo "app.tar.gz": instala un script mínimo en /usr/local/bin.
mkdir -p ../files/example-pkg/data/usr/local/bin
cat << EOF > ../files/example-pkg/pkginfo
NAME=app
VERSION=1.0
DESC=Paquete de ejemplo para el gestor pkg de $distro_name
EOF
cat << 'EOF' > ../files/example-pkg/data/usr/local/bin/app
#!/bin/sh
echo "¡Hola! Este binario vino del paquete 'app', instalado con pkg."
EOF
chmod 755 ../files/example-pkg/data/usr/local/bin/app
mkdir -p root/examples
tar -czf root/examples/app.tar.gz -C ../files/example-pkg pkginfo data
chmod 644 root/examples/app.tar.gz

# El mismo paquete se publica como un repositorio de ejemplo, servido por
# nuestro propio httpd en /var/www/html/repo. Sirve para probar
# "pkg update && pkg install app" de punta a punta sin depender de un
# servidor externo; /etc/pkg.conf se puede apuntar a cualquier otra URL.
mkdir -p var/www/html/repo
cp root/examples/app.tar.gz var/www/html/repo/app-1.0.tar.gz
echo "app|1.0|app-1.0.tar.gz|Paquete de ejemplo para el gestor pkg de $distro_name" > var/www/html/repo/index
chmod 644 var/www/html/repo/index var/www/html/repo/app-1.0.tar.gz

cat << EOF > etc/pkg.conf
# URL base del repositorio de paquetes para "pkg update"/"pkg install".
# Debe tener un archivo "index" y los .tar.gz que liste, todos servidos
# por HTTP/HTTPS. Este es el que arma setup-oky-repo.sh; cambiala si tu
# repositorio vive en otra dirección.
REPO=$pkg_repo_url
EOF

printf "#!/bin/sh
. /etc/init.d/init-functions
rc >>/var/log/boot.log 2>&1" > etc/init.d/rcS
ln -s /etc/init.d/rcS etc/init.d/rcK

cat << EOF > var/spool/cron/crontabs/root
15 * * * * cd / && run-parts /etc/cron/hourly
23 6 * * * cd / && run-parts /etc/cron/daily
47 6 * * 0 cd / && run-parts /etc/cron/weekly
33 5 1 * * cd / && run-parts /etc/cron/monthly
EOF

# run-parts: BusyBox lo traía como applet; aquí es un envoltorio mínimo,
# ya que reimplementar debianutils completo no aporta nada en este contexto.
cat << 'EOF' > usr/bin/run-parts
#!/bin/sh
dir="$1"
[ -d "$dir" ] || exit 0
for script in "$dir"/*; do
[ -f "$script" ] && [ -x "$script" ] && "$script"
done
exit 0
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
add-rc.d inetd 80
add-rc.d httpd 40
"
fi
EOF

cat << 'EOF' > sbin/net-up
#!/bin/sh
/sbin/ip link set lo up
/sbin/ip addr add 127.0.0.1/8 dev lo 2>/dev/null
/sbin/ip link set eth0 up 2>/dev/null
/sbin/dhcpcd -b eth0 2>/dev/null
EOF

cat << 'EOF' > sbin/net-down
#!/bin/sh
/sbin/dhcpcd -x eth0 2>/dev/null
/sbin/ip link set eth0 down 2>/dev/null
EOF

initdata="
networking|network|30|/sbin/net-up||/sbin/net-down
crond|cron daemon|20|/usr/sbin/crond|-f
syslogd|syslog|10|/sbin/syslogd
httpd|http server||/usr/sbin/httpd|/var/www/html --port 80 --uid service --gid service --log /var/log/httpd.log||httpd.log
inetd|telnet/ftp daemon|80|/sbin/inetd|/etc/inetd.conf||inetd.log"
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
[ "$3" ] && ln -s ../init.d/$1 etc/rc.d/$3$1.sh
done
IFS=$OIFS

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
printf '\033[H\033[2J'
return 1
}
EOF

touch proc/mounts var/log/wtmp var/log/lastlog
chmod 640 etc/shadow etc/gshadow etc/inittab
chmod 664 var/log/lastlog var/log/wtmp
chmod 600 var/spool/cron/crontabs/root
chmod 755 usr/sbin/nologin init sbin/man etc/init.d/rcS etc/init.d/halt etc/init.d/reboot usr/sbin/logrotate usr/bin/add-rc.d usr/bin/run-parts \
usr/sbin/install-to-disk sbin/net-up sbin/net-down
chmod 644 etc/passwd etc/group etc/hostname etc/shells etc/hosts etc/protocols etc/services etc/syslog.conf etc/fstab etc/issue etc/motd etc/network/interfaces etc/profile etc/inetd.conf etc/dhcpcd.conf etc/login.defs etc/wgetrc etc/pkg.conf
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
