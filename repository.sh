#!/bin/sh
# repository.sh
# Configura un servidor de repositorio de paquetes para el gestor "pkg"
# de OKY, sirviendo con nginx, con un par de paquetes de ejemplo.
#
# Uso:
#   sudo ./repository.sh [-n DOMINIO] [-p PUERTO] [-r DIRECTORIO]
#
# Por defecto: dominio pkg.oky.pe, puerto 80, /var/www/html/oky.pe/pkg
#
# Usa un SUBDOMINIO propio (pkg.oky.pe) en vez de oky.pe directamente,
# a propósito: si oky.pe ya sirve otra cosa en este mismo servidor (otro
# sitio, otra app), este script arma un "server {}" de nginx totalmente
# aparte -- no toca ni pisa la configuración que ya exista para oky.pe.
#
# IMPORTANTE: el dominio (pkg.oky.pe por defecto) tiene que apuntar por
# DNS (registro A/AAAA propio, distinto al de oky.pe) a la IP pública de
# este servidor. Este script NO configura el DNS, solo nginx -- eso se
# hace en tu proveedor de dominio.
set -e

REPO_DOMAIN="pkg.oky.pe"
REPO_PORT="80"
REPO_DIR="/var/www/html/oky.pe/pkg"

usage() {
	echo "Uso: $0 [-n DOMINIO] [-p PUERTO] [-r DIRECTORIO]"
	echo "  -n DOMINIO     Dominio (default: $REPO_DOMAIN)"
	echo "  -p PUERTO      Puerto (default: $REPO_PORT)"
	echo "  -r DIRECTORIO  Carpeta del repo (default: $REPO_DIR)"
	exit 1
}

while getopts "n:p:r:h" opt; do
	case "$opt" in
	n) REPO_DOMAIN="$OPTARG" ;;
	p) REPO_PORT="$OPTARG" ;;
	r) REPO_DIR="$OPTARG" ;;
	h) usage ;;
	*) usage ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "** Este script debe correrse como root (sudo)." >&2
	exit 1
fi

echo "== Configurando repositorio OKY en http://$REPO_DOMAIN:$REPO_PORT/ =="
echo "== Carpeta: $REPO_DIR =="
echo

# ---------------------------------------------------------------------
# 1. nginx
# ---------------------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1; then
	echo "-- Instalando nginx..."
	if command -v apt >/dev/null 2>&1; then
		apt update && apt install -y nginx
	else
		echo "** No se encontró 'apt' y nginx no está instalado. Instalalo a mano." >&2
		exit 1
	fi
else
	echo "-- nginx ya está instalado."
fi

# ---------------------------------------------------------------------
# 2. Paquetes de ejemplo
# ---------------------------------------------------------------------
mkdir -p "$REPO_DIR"

# Genera un paquete .tar.gz (formato pkg de OKY: pkginfo + data/) y
# agrega su línea al índice del repo.
# build_pkg <nombre> <version> <descripcion> <contenido del script>
build_pkg() {
	name="$1"; version="$2"; desc="$3"; body="$4"
	workdir=$(mktemp -d)
	mkdir -p "$workdir/data/usr/local/bin"
	cat > "$workdir/pkginfo" <<PKGINFO
NAME=$name
VERSION=$version
DESC=$desc
PKGINFO
	printf '%s\n' "$body" > "$workdir/data/usr/local/bin/$name"
	chmod 755 "$workdir/data/usr/local/bin/$name"
	tar -czf "$REPO_DIR/${name}-${version}.tar.gz" -C "$workdir" pkginfo data
	rm -rf "$workdir"
	echo "${name}|${version}|${name}-${version}.tar.gz|${desc}"
}

echo "-- Generando paquetes de ejemplo..."
: > "$REPO_DIR/packages"

build_pkg hello 1.0 "Saluda desde el paquete hello" \
'#!/bin/sh
echo "¡Hola! Este binario vino del paquete '"'"'hello'"'"', instalado con pkg."' \
>> "$REPO_DIR/packages"

build_pkg sysinfo 1.0 "Muestra informacion basica del sistema" \
'#!/bin/sh
echo "== sysinfo =="
uname -a
echo
echo "-- uptime --"
uptime 2>/dev/null || cat /proc/uptime
echo
echo "-- memoria --"
free 2>/dev/null || cat /proc/meminfo | head -3
echo
echo "-- red --"
ip -brief addr 2>/dev/null || ip addr' \
>> "$REPO_DIR/packages"

echo "-- Paquetes generados:"
cat "$REPO_DIR/packages"
echo

# ---------------------------------------------------------------------
# 3. Sitio de nginx
# ---------------------------------------------------------------------
echo "-- Configurando el sitio de nginx..."
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > /etc/nginx/sites-available/${REPO_DOMAIN} <<NGINX
server {
	listen ${REPO_PORT};
	server_name ${REPO_DOMAIN};

	root ${REPO_DIR};

	location / {
		autoindex on;
		try_files \$uri \$uri/ =404;
	}
}
NGINX

ln -sf /etc/nginx/sites-available/${REPO_DOMAIN} /etc/nginx/sites-enabled/${REPO_DOMAIN}
# Evita que el sitio "default" de nginx compita por el mismo puerto.
rm -f /etc/nginx/sites-enabled/default

# ---------------------------------------------------------------------
# 4. Permisos
# ---------------------------------------------------------------------
echo "-- Ajustando permisos..."
chown -R www-data:www-data "$REPO_DIR" 2>/dev/null || true
find "$REPO_DIR" -type d -exec chmod 755 {} \;
find "$REPO_DIR" -type f -exec chmod 644 {} \;

# ---------------------------------------------------------------------
# 5. Arrancar / recargar nginx
# ---------------------------------------------------------------------
echo "-- Verificando configuración de nginx..."
nginx -t

if command -v systemctl >/dev/null 2>&1; then
	systemctl enable nginx >/dev/null 2>&1 || true
	systemctl reload nginx 2>/dev/null || systemctl restart nginx
else
	service nginx reload 2>/dev/null || service nginx restart
fi

echo
echo "== Listo =="
echo "Repositorio disponible en: http://${REPO_DOMAIN}:${REPO_PORT}/"
echo
echo "** Recordá: ${REPO_DOMAIN} necesita su PROPIO registro A en el DNS"
echo "** (distinto del que ya tiene oky.pe), apuntando a la IP pública de"
echo "** este servidor. Eso se configura en tu proveedor de dominio, no acá."
echo
echo "En el sistema OKY, configurá /etc/pkg.conf con:"
echo "  REPO=http://${REPO_DOMAIN}:${REPO_PORT}"
echo
echo "Y probá:"
echo "  pkg update"
echo "  pkg search hello"
echo "  pkg install hello"
echo "  pkg install sysinfo"
