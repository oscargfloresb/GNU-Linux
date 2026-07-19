#!/bin/sh
# gitweb.sh
# Configura un servidor gitweb (visor web de repositorios git) para OKY,
# sirviendo con nginx + fcgiwrap, con un repo de ejemplo.
#
# Uso:
#   sudo ./gitweb.sh [-n DOMINIO] [-p PUERTO] [-r DIRECTORIO_REPOS]
#
# Por defecto: dominio git.oky.pe, puerto 80, /srv/git
#
# Usa un SUBDOMINIO propio (git.oky.pe) en vez de oky.pe directamente,
# a propósito: si oky.pe (o pkg.oky.pe) ya sirven otra cosa en este mismo
# servidor, este script arma un "server {}" de nginx totalmente aparte --
# no toca ni pisa la configuración que ya exista para otros dominios.
#
# IMPORTANTE: el dominio (git.oky.pe por defecto) tiene que apuntar por
# DNS (registro A/AAAA propio) a la IP pública de este servidor. Este
# script NO configura el DNS, solo nginx -- eso se hace en tu proveedor
# de dominio.
set -e

GIT_DOMAIN="git.oky.pe"
GIT_PORT="80"
GIT_REPOS_DIR="/var/www/html/oky.pe/git"

usage() {
	echo "Uso: $0 [-n DOMINIO] [-p PUERTO] [-r DIRECTORIO_REPOS]"
	echo "  -n DOMINIO         Dominio (default: $GIT_DOMAIN)"
	echo "  -p PUERTO          Puerto (default: $GIT_PORT)"
	echo "  -r DIRECTORIO_REPOS  Carpeta de repos bare (default: $GIT_REPOS_DIR)"
	exit 1
}

while getopts "n:p:r:h" opt; do
	case "$opt" in
	n) GIT_DOMAIN="$OPTARG" ;;
	p) GIT_PORT="$OPTARG" ;;
	r) GIT_REPOS_DIR="$OPTARG" ;;
	h) usage ;;
	*) usage ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "** Este script debe correrse como root (sudo)." >&2
	exit 1
fi

echo "== Configurando gitweb en http://$GIT_DOMAIN:$GIT_PORT/ =="
echo "== Repos: $GIT_REPOS_DIR =="
echo

# ---------------------------------------------------------------------
# 1. Paquetes del sistema
# ---------------------------------------------------------------------
if ! command -v apt >/dev/null 2>&1; then
	echo "** No se encontró 'apt'. Instalá los paquetes a mano: nginx git gitweb fcgiwrap" >&2
	exit 1
fi

echo "-- Instalando nginx, git, gitweb, fcgiwrap..."
apt update
apt install -y nginx git gitweb fcgiwrap highlight

# ---------------------------------------------------------------------
# 2. Repo de ejemplo
# ---------------------------------------------------------------------
echo "-- Preparando carpeta de repos..."
mkdir -p "$GIT_REPOS_DIR"

if [ ! -d "$GIT_REPOS_DIR/hello.git" ]; then
	echo "-- Generando repo de ejemplo (hello.git)..."
	workdir=$(mktemp -d)
	git init -q "$workdir"
	cd "$workdir"
	git config user.email "oky@$GIT_DOMAIN"
	git config user.name "OKY"
	cat > README.md <<'README'
# hello

Repo de ejemplo servido por gitweb en OKY.
README
	git add README.md
	git commit -q -m "Commit inicial"
	cd /
	git clone -q --bare "$workdir" "$GIT_REPOS_DIR/hello.git"
	rm -rf "$workdir"
fi

# Le da a gitweb la lista de proyectos a mostrar (autodetecta cualquier
# *.git dentro de GIT_REPOS_DIR).
cat > /etc/gitweb.conf <<GITWEBCONF
\$projectroot = "$GIT_REPOS_DIR";
\$git_temp = "/tmp";
\$projects_list = \$projectroot;
\$site_name = "OKY git";
\$strict_export = 0;
\$feature{'highlight'}{'default'} = [1];
GITWEBCONF

# ---------------------------------------------------------------------
# 3. fcgiwrap (ejecuta gitweb.cgi como FastCGI para nginx)
# ---------------------------------------------------------------------
echo "-- Habilitando fcgiwrap..."
if command -v systemctl >/dev/null 2>&1; then
	systemctl enable fcgiwrap >/dev/null 2>&1 || true
	systemctl restart fcgiwrap
else
	service fcgiwrap restart
fi

# ---------------------------------------------------------------------
# 4. Sitio de nginx
# ---------------------------------------------------------------------
echo "-- Configurando el sitio de nginx..."
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

GITWEB_CGI="/usr/share/gitweb/gitweb.cgi"
GITWEB_STATIC="/usr/share/gitweb/static"

cat > /etc/nginx/sites-available/${GIT_DOMAIN} <<NGINX
server {
	listen ${GIT_PORT};
	server_name ${GIT_DOMAIN};

	root ${GITWEB_STATIC};

	location /static/ {
		alias ${GITWEB_STATIC}/;
	}

	location / {
		gzip off;
		fastcgi_pass unix:/var/run/fcgiwrap.socket;
		fastcgi_index gitweb.cgi;
		fastcgi_param SCRIPT_FILENAME ${GITWEB_CGI};
		fastcgi_param GITWEB_CONFIG /etc/gitweb.conf;
		include fastcgi_params;
	}

	# Clonar por HTTP con "git clone http://\$GIT_DOMAIN/hello.git"
	location ~ ^/(.*\\.git)/(.*) {
		client_max_body_size 0;
		fastcgi_pass unix:/var/run/fcgiwrap.socket;
		include fastcgi_params;
		fastcgi_param SCRIPT_FILENAME /usr/lib/git-core/git-http-backend;
		fastcgi_param GIT_HTTP_EXPORT_ALL "";
		fastcgi_param GIT_PROJECT_ROOT ${GIT_REPOS_DIR};
		fastcgi_param PATH_INFO /\$1/\$2;
	}
}
NGINX

ln -sf /etc/nginx/sites-available/${GIT_DOMAIN} /etc/nginx/sites-enabled/${GIT_DOMAIN}
# Evita que el sitio "default" de nginx compita por el mismo puerto.
rm -f /etc/nginx/sites-enabled/default

# ---------------------------------------------------------------------
# 5. Permisos
# ---------------------------------------------------------------------
echo "-- Ajustando permisos..."
chown -R www-data:www-data "$GIT_REPOS_DIR" 2>/dev/null || true
find "$GIT_REPOS_DIR" -type d -exec chmod 755 {} \;

# ---------------------------------------------------------------------
# 6. Arrancar / recargar nginx
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
echo "gitweb disponible en: http://${GIT_DOMAIN}:${GIT_PORT}/"
echo
echo "** Recordá: ${GIT_DOMAIN} necesita su PROPIO registro A en el DNS,"
echo "** apuntando a la IP pública de este servidor. Eso se configura en"
echo "** tu proveedor de dominio, no acá."
echo
echo "Para agregar un repo nuevo:"
echo "  git init --bare ${GIT_REPOS_DIR}/mi-repo.git"
echo
echo "Para clonarlo por HTTP:"
echo "  git clone http://${GIT_DOMAIN}:${GIT_PORT}/mi-repo.git"
