#!/bin/sh
# mediawiki.sh
# Configura un sitio MediaWiki para OKY, sirviendo con nginx + php-fpm,
# con base de datos SQLite (sin necesitar un servidor de base de datos
# aparte) y un usuario administrador ya creado.
#
# Uso:
#   sudo ./mediawiki.sh [-n DOMINIO] [-p PUERTO] [-r DIRECTORIO] [-u USUARIO] [-w NOMBRE_WIKI]
#
# Por defecto: dominio wiki.oky.pe, puerto 80, /var/www/html/wiki.oky.pe,
# usuario admin "Admin", nombre de wiki "OKY Wiki"
#
# La contraseña del administrador se genera al azar y se muestra al
# final -- guardala, no queda guardada en ningún lado más.
#
# Usa un SUBDOMINIO propio (wiki.oky.pe) en vez de oky.pe directamente,
# a propósito: si oky.pe (o pkg.oky.pe, git.oky.pe) ya sirven otra cosa
# en este mismo servidor, este script arma un "server {}" de nginx
# totalmente aparte -- no toca ni pisa la configuración que ya exista
# para otros dominios.
#
# IMPORTANTE: el dominio (wiki.oky.pe por defecto) tiene que apuntar por
# DNS (registro A/AAAA propio) a la IP pública de este servidor. Este
# script NO configura el DNS, solo nginx -- eso se hace en tu proveedor
# de dominio.
set -e

WIKI_DOMAIN="wiki.oky.pe"
WIKI_PORT="80"
WIKI_DIR="/var/www/html/oky.pe/wiki"
WIKI_ADMIN_USER="Admin"
WIKI_NAME="OKY Wiki"
MEDIAWIKI_VERSION="1.46.0"
MEDIAWIKI_BRANCH="1.46"

usage() {
	echo "Uso: $0 [-n DOMINIO] [-p PUERTO] [-r DIRECTORIO] [-u USUARIO] [-w NOMBRE_WIKI]"
	echo "  -n DOMINIO       Dominio (default: $WIKI_DOMAIN)"
	echo "  -p PUERTO        Puerto (default: $WIKI_PORT)"
	echo "  -r DIRECTORIO    Carpeta de instalación (default: $WIKI_DIR)"
	echo "  -u USUARIO       Usuario administrador (default: $WIKI_ADMIN_USER)"
	echo "  -w NOMBRE_WIKI   Nombre del sitio (default: $WIKI_NAME)"
	exit 1
}

while getopts "n:p:r:u:w:h" opt; do
	case "$opt" in
	n) WIKI_DOMAIN="$OPTARG" ;;
	p) WIKI_PORT="$OPTARG" ;;
	r) WIKI_DIR="$OPTARG" ;;
	u) WIKI_ADMIN_USER="$OPTARG" ;;
	w) WIKI_NAME="$OPTARG" ;;
	h) usage ;;
	*) usage ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "** Este script debe correrse como root (sudo)." >&2
	exit 1
fi

echo "== Configurando MediaWiki en http://$WIKI_DOMAIN:$WIKI_PORT/ =="
echo "== Carpeta: $WIKI_DIR =="
echo

# ---------------------------------------------------------------------
# 1. Paquetes del sistema
# ---------------------------------------------------------------------
if ! command -v apt >/dev/null 2>&1; then
	echo "** No se encontró 'apt'. Instalá los paquetes a mano: nginx php-fpm php-sqlite3 php-mbstring php-xml php-intl wget" >&2
	exit 1
fi

echo "-- Instalando nginx, php-fpm y extensiones necesarias..."
apt update
apt install -y nginx php-fpm php-sqlite3 php-mbstring php-xml php-intl php-apcu wget

PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

# ---------------------------------------------------------------------
# 2. Descargar e instalar MediaWiki
# ---------------------------------------------------------------------
if [ ! -f "$WIKI_DIR/LocalSettings.php" ]; then
	echo "-- Descargando MediaWiki ${MEDIAWIKI_VERSION}..."
	mkdir -p "$WIKI_DIR"
	workdir=$(mktemp -d)
	wget -q "https://releases.wikimedia.org/mediawiki/${MEDIAWIKI_BRANCH}/mediawiki-${MEDIAWIKI_VERSION}.tar.gz" -O "$workdir/mediawiki.tar.gz"
	tar -xzf "$workdir/mediawiki.tar.gz" -C "$workdir"
	cp -a "$workdir/mediawiki-${MEDIAWIKI_VERSION}/." "$WIKI_DIR/"
	rm -rf "$workdir"

	echo "-- Generando LocalSettings.php (base de datos SQLite, instalador por linea de comandos)..."
	WIKI_ADMIN_PASS=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
	mkdir -p "$WIKI_DIR/data"
	php "$WIKI_DIR/maintenance/install.php" \
		--dbtype sqlite \
		--dbpath "$WIKI_DIR/data" \
		--server "http://${WIKI_DOMAIN}" \
		--scriptpath "" \
		--lang es \
		--pass "$WIKI_ADMIN_PASS" \
		"$WIKI_NAME" \
		"$WIKI_ADMIN_USER"
	echo "$WIKI_ADMIN_PASS" > "$WIKI_DIR/.admin-pass-inicial"
	chmod 600 "$WIKI_DIR/.admin-pass-inicial"
else
	echo "-- Ya existe una instalación en $WIKI_DIR (LocalSettings.php presente), no se reinstala."
fi

# ---------------------------------------------------------------------
# 3. Sitio de nginx
# ---------------------------------------------------------------------
echo "-- Configurando el sitio de nginx..."
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > /etc/nginx/sites-available/${WIKI_DOMAIN} <<NGINX
server {
	listen ${WIKI_PORT};
	server_name ${WIKI_DOMAIN};

	root ${WIKI_DIR};
	index index.php;

	client_max_body_size 20m;

	location / {
		try_files \$uri \$uri/ @rewrite;
	}

	location @rewrite {
		rewrite ^/(.*)$ /index.php?title=\$1&\$args;
	}

	location ~ \.php$ {
		fastcgi_pass unix:${PHP_SOCK};
		fastcgi_index index.php;
		fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
		include fastcgi_params;
	}

	# La carpeta data/ tiene la base SQLite -- nunca se sirve por web.
	location ^~ /data/ {
		deny all;
		return 404;
	}

	location ~ /\.ht {
		deny all;
	}
}
NGINX

ln -sf /etc/nginx/sites-available/${WIKI_DOMAIN} /etc/nginx/sites-enabled/${WIKI_DOMAIN}
# Evita que el sitio "default" de nginx compita por el mismo puerto.
rm -f /etc/nginx/sites-enabled/default

# ---------------------------------------------------------------------
# 4. Permisos
# ---------------------------------------------------------------------
echo "-- Ajustando permisos..."
chown -R www-data:www-data "$WIKI_DIR"
find "$WIKI_DIR" -type d -exec chmod 755 {} \;
find "$WIKI_DIR" -type f -exec chmod 644 {} \;
chmod 700 "$WIKI_DIR/data"

# ---------------------------------------------------------------------
# 5. Arrancar / recargar servicios
# ---------------------------------------------------------------------
echo "-- Verificando configuración de nginx..."
nginx -t

if command -v systemctl >/dev/null 2>&1; then
	systemctl enable "php${PHP_VERSION}-fpm" >/dev/null 2>&1 || true
	systemctl restart "php${PHP_VERSION}-fpm"
	systemctl enable nginx >/dev/null 2>&1 || true
	systemctl reload nginx 2>/dev/null || systemctl restart nginx
else
	service "php${PHP_VERSION}-fpm" restart
	service nginx reload 2>/dev/null || service nginx restart
fi

echo
echo "== Listo =="
echo "MediaWiki disponible en: http://${WIKI_DOMAIN}:${WIKI_PORT}/"
echo
echo "** Recordá: ${WIKI_DOMAIN} necesita su PROPIO registro A en el DNS,"
echo "** apuntando a la IP pública de este servidor. Eso se configura en"
echo "** tu proveedor de dominio, no acá."
echo
if [ -f "$WIKI_DIR/.admin-pass-inicial" ]; then
	echo "Usuario administrador: ${WIKI_ADMIN_USER}"
	echo "Contraseña inicial:    $(cat "$WIKI_DIR/.admin-pass-inicial")"
	echo "(guardala ahora -- este mensaje no se repite; después la podés"
	echo " cambiar entrando a la wiki con Special:ChangePassword)"
	rm -f "$WIKI_DIR/.admin-pass-inicial"
else
	echo "El sitio ya estaba instalado -- usá las credenciales que ya tenías."
fi
