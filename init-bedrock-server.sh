#!/usr/bin/env bash
set -euo pipefail

SERVER_IP_DETECTED="YOUR_SERVER_IP"

if command -v curl >/dev/null 2>&1; then
  TMP_IP="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "${TMP_IP:-}" ]]; then
    SERVER_IP_DETECTED="$TMP_IP"
  fi
fi

if [[ "$SERVER_IP_DETECTED" == "YOUR_SERVER_IP" ]]; then
  TMP_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${TMP_IP:-}" ]]; then
    SERVER_IP_DETECTED="$TMP_IP"
  fi
fi

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root"
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

read -rp "Project name, например test: " NAME
read -rp "Domain, например example.com: " DOMAIN
read -rp "Deploy user [deploy]: " DEPLOY_USER
DEPLOY_USER="${DEPLOY_USER:-deploy}"

read -rp "Root/sudo user nickname [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

read -rp "SSH port [2222]: " SSH_PORT
SSH_PORT="${SSH_PORT:-2222}"

if [[ ! "$NAME" =~ ^[a-z0-9_-]+$ ]]; then
  echo "ERROR: имя проекта — только a-z, 0-9, _ и -"
  exit 1
fi

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  echo "ERROR: некорректный домен"
  exit 1
fi

if [[ ! "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "ERROR: deploy user — только a-z, 0-9, _ и -, должен начинаться с буквы или _"
  exit 1
fi

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "ERROR: root/sudo user — только a-z, 0-9, _ и -, должен начинаться с буквы или _"
  exit 1
fi

if [[ "$ADMIN_USER" == "root" ]]; then
  echo "ERROR: не используй root как имя нового sudo пользователя"
  exit 1
fi

if [[ "$ADMIN_USER" == "$DEPLOY_USER" ]]; then
  echo "ERROR: root/sudo user и deploy user должны быть разными"
  exit 1
fi

PHP_VERSION="8.4"
NODE_MAJOR="22"

APP_DIR="/var/www/${NAME}"
RELEASES_DIR="${APP_DIR}/releases"
SHARED_DIR="${APP_DIR}/shared"
CURRENT_DIR="${APP_DIR}/current"

DB_NAME="${NAME}_db"
DB_USER="${NAME}_db"
DB_PASS="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)"
ADMIN_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#%^+=' | head -c 16)"

FPM_POOL="${NAME}"
FPM_SOCK="/run/php/php${PHP_VERSION}-fpm-${NAME}.sock"
PHP_TMP_DIR="/run/php-tmp/${NAME}"
GIT_KEY_PATH="/home/${DEPLOY_USER}/.ssh/git_deploy"

fix_project_permissions() {
  local target="$1"

  if [[ -d "$target" ]]; then
    chown -R "${DEPLOY_USER}:www-data" "$target"

    # setgid: новые файлы/папки наследуют группу www-data
    find "$target" -type d -exec chmod 2775 {} \;
    find "$target" -type f -exec chmod 664 {} \;

    # ACL: deploy, admin и группа www-data могут читать/писать новые файлы
    setfacl -R -m "u:${DEPLOY_USER}:rwx" "$target"
    setfacl -R -m "u:${ADMIN_USER}:rwx" "$target"
    setfacl -R -m "g:www-data:rwx" "$target"
    setfacl -R -d -m "u:${DEPLOY_USER}:rwx" "$target"
    setfacl -R -d -m "u:${ADMIN_USER}:rwx" "$target"
    setfacl -R -d -m "g:www-data:rwx" "$target"
  fi
}

echo "==> Swap 2G"
if [[ ! -f /swapfile ]]; then
  fallocate -l 2G /swapfile 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none

  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if ! grep -q "^/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

echo "==> Обновление системы"
apt update
apt upgrade -y

echo "==> Базовые пакеты"
apt install -y \
  curl wget ca-certificates gnupg2 lsb-release sudo \
  git unzip zip ufw fail2ban mariadb-server \
  certbot acl rsync openssl

echo "==> Создание root/sudo пользователя"
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$ADMIN_USER"
fi

echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
usermod -aG sudo "$ADMIN_USER"
usermod -aG www-data "$ADMIN_USER"

mkdir -p "/home/${ADMIN_USER}/.ssh"
chmod 700 "/home/${ADMIN_USER}/.ssh"
touch "/home/${ADMIN_USER}/.ssh/authorized_keys"
chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"

echo "==> Создание deploy пользователя"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi

usermod -aG www-data "$DEPLOY_USER"

mkdir -p "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
touch "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"

echo ""
echo -e "${RED}====================================================${NC}"
echo -e "${RED}КРИТИЧЕСКИ ВАЖНО: ДОБАВЬ SSH-КЛЮЧ ДЛЯ ${DEPLOY_USER}${NC}"
echo -e "${RED}====================================================${NC}"
echo -e "${RED}Скрипт отключит root login и PasswordAuthentication.${NC}"
echo -e "${RED}Если сейчас не добавить публичный ключ для ${DEPLOY_USER},${NC}"
echo -e "${RED}доступ к серверу по SSH может быть потерян.${NC}"
echo ""
echo "Если ключа ещё нет, создай на своём ПК:"
echo "  Windows CMD:"
echo "    mkdir %USERPROFILE%\\.ssh 2>nul"
echo "    ssh-keygen -t ed25519 -f %USERPROFILE%\\.ssh\\deploy_server"
echo ""
echo "  Windows PowerShell:"
echo "    mkdir \$env:USERPROFILE\\.ssh -ErrorAction SilentlyContinue"
echo "    ssh-keygen -t ed25519 -f \$env:USERPROFILE\\.ssh\\deploy_server"
echo ""
echo "  Linux / macOS / WSL:"
echo "    ssh-keygen -t ed25519 -f ~/.ssh/deploy_server"
echo ""
echo "На своём ПК получи публичный ключ:"
echo "  Windows CMD:"
echo "    type %USERPROFILE%\\.ssh\\deploy_server.pub"
echo ""
echo "  Windows PowerShell:"
echo "    type \$env:USERPROFILE\\.ssh\\deploy_server.pub"
echo ""
echo "  Linux / macOS / WSL:"
echo "    cat ~/.ssh/deploy_server.pub"
echo ""
read -rp "Вставь PUBLIC SSH KEY для ${DEPLOY_USER} (ssh-ed25519 ...): " DEPLOY_PUBLIC_KEY

if [[ -z "${DEPLOY_PUBLIC_KEY}" ]]; then
  echo -e "${RED}ERROR: публичный ключ пустой. Остановка, чтобы не потерять доступ.${NC}"
  exit 1
fi

if [[ ! "${DEPLOY_PUBLIC_KEY}" =~ ^ssh-(ed25519|rsa)[[:space:]]+ ]]; then
  echo -e "${RED}ERROR: ключ должен начинаться с ssh-ed25519 или ssh-rsa.${NC}"
  exit 1
fi

if ! grep -qxF "${DEPLOY_PUBLIC_KEY}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"; then
  echo "${DEPLOY_PUBLIC_KEY}" >> "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

if ! grep -qxF "${DEPLOY_PUBLIC_KEY}" "/home/${ADMIN_USER}/.ssh/authorized_keys"; then
  echo "${DEPLOY_PUBLIC_KEY}" >> "/home/${ADMIN_USER}/.ssh/authorized_keys"
fi

chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
chmod 755 "/home/${ADMIN_USER}"
chmod 700 "/home/${ADMIN_USER}/.ssh"
chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
chmod 755 "/home/${DEPLOY_USER}"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"

echo -e "${GREEN}SSH public key добавлен для пользователей ${DEPLOY_USER} и ${ADMIN_USER}.${NC}"
echo ""

echo "==> SSH hardening"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)

sed -i \
  -e "s/^#\?Port .*/Port ${SSH_PORT}/" \
  -e "s/^#\?PermitRootLogin .*/PermitRootLogin no/" \
  -e "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" \
  -e "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" \
  /etc/ssh/sshd_config

sshd -t
systemctl restart ssh || systemctl restart sshd

echo ""
echo -e "${RED}====================================================${NC}"
echo -e "${RED}ПРОВЕРЬ SSH-ДОСТУП С ПК ПРЯМО СЕЙЧАС${NC}"
echo -e "${RED}====================================================${NC}"
echo "Открой НОВОЕ окно терминала на своём ПК и проверь вход."
echo ""
echo "Windows CMD:"
echo "  ssh -i %USERPROFILE%\\.ssh\\deploy_server -p ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}"
echo ""
echo "Windows PowerShell:"
echo "  ssh -i \$env:USERPROFILE\\.ssh\\deploy_server -p ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}"
echo ""
echo "Linux / macOS / WSL:"
echo "  ssh -i ~/.ssh/deploy_server -p ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}"
echo ""
echo -e "${RED}НЕ ЗАКРЫВАЙ текущую root-сессию, пока вход не проверен.${NC}"
echo ""
read -rp "Ты успешно подключился по SSH с ПК под пользователем ${DEPLOY_USER}? [y/N]: " SSH_LOGIN_OK

if [[ ! "$SSH_LOGIN_OK" =~ ^[Yy]$ ]]; then
  echo ""
  echo -e "${YELLOW}Если появилась ошибка REMOTE HOST IDENTIFICATION HAS CHANGED:${NC}"
  echo ""
  echo "Windows CMD / PowerShell / Linux / macOS / WSL:"
  echo "  ssh-keygen -R \"[${SERVER_IP_DETECTED}]:${SSH_PORT}\""
  echo ""
  echo "После этого повтори проверку:"
  echo "  ssh -i ~/.ssh/deploy_server -p ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}"
  echo ""
  echo "Если снова не входит:"
  echo "  1. Проверь, что публичный ключ вставлен одной строкой."
  echo "  2. Проверь /home/${DEPLOY_USER}/.ssh/authorized_keys."
  echo "  3. Проверь права:"
  echo "     chmod 755 /home/${DEPLOY_USER}"
  echo "     chmod 700 /home/${DEPLOY_USER}/.ssh"
  echo "     chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys"
  echo ""
  read -rp "После исправления повторно проверь вход. Теперь вход успешен? [y/N]: " SSH_LOGIN_OK_RETRY

  if [[ ! "$SSH_LOGIN_OK_RETRY" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Остановка установки, чтобы не потерять доступ к серверу.${NC}"
    exit 1
  fi
fi

echo -e "${GREEN}SSH-доступ для ${DEPLOY_USER} подтверждён.${NC}"
echo ""

echo "==> Firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "==> Fail2ban"
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "==> Установка Nginx mainline nginx.org"
install -d /etc/apt/keyrings

curl -fsSL https://nginx.org/keys/nginx_signing.key \
  | gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

cat > /etc/apt/sources.list.d/nginx.org.list <<EOF
deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/debian/ ${CODENAME} nginx
deb-src [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/debian/ ${CODENAME} nginx
EOF

cat > /etc/apt/preferences.d/99nginx <<EOF
Package: *
Pin: origin nginx.org
Pin-Priority: 900
EOF

apt update
apt install -y nginx

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
  sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a\    include /etc/nginx/sites-enabled/*.conf;' /etc/nginx/nginx.conf
fi

rm -f /etc/nginx/conf.d/default.conf
rm -f /etc/nginx/sites-enabled/default

systemctl enable nginx
systemctl start nginx

# nginx от nginx.org работает от пользователя nginx, а не www-data.
# Добавляем nginx в группу www-data чтобы он мог читать сокет PHP-FPM.
usermod -aG www-data nginx
systemctl restart nginx


echo "==> Создание базовой release-структуры"
mkdir -p \
  "${RELEASES_DIR}" \
  "${SHARED_DIR}/web/app/uploads" \
  "${SHARED_DIR}/web/app/cache" \
  "${SHARED_DIR}/storage" \
  "${SHARED_DIR}/logs" \
  "${SHARED_DIR}/certbot"

fix_project_permissions "${APP_DIR}"
chmod 2775 "${SHARED_DIR}/logs"

echo "==> Установка PHP ${PHP_VERSION}"
if ! apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
  echo "php${PHP_VERSION} не найден. Добавляем Sury."

  curl -fsSL https://packages.sury.org/php/apt.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg

  cat > /etc/apt/sources.list.d/sury-php.list <<EOF
deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${CODENAME} main
EOF

  apt update
fi

apt install -y \
  php${PHP_VERSION} \
  php${PHP_VERSION}-fpm \
  php${PHP_VERSION}-cli \
  php${PHP_VERSION}-mysql \
  php${PHP_VERSION}-curl \
  php${PHP_VERSION}-xml \
  php${PHP_VERSION}-mbstring \
  php${PHP_VERSION}-zip \
  php${PHP_VERSION}-gd \
  php${PHP_VERSION}-intl \
  php${PHP_VERSION}-bcmath \
  php${PHP_VERSION}-soap \
  php${PHP_VERSION}-opcache

systemctl enable "php${PHP_VERSION}-fpm"
systemctl start "php${PHP_VERSION}-fpm"

echo "==> PHP production tuning"
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"

sed -i \
  -e "s/^memory_limit = .*/memory_limit = 512M/" \
  -e "s/^upload_max_filesize = .*/upload_max_filesize = 128M/" \
  -e "s/^post_max_size = .*/post_max_size = 128M/" \
  -e "s/^max_execution_time = .*/max_execution_time = 180/" \
  "$PHP_INI"

OPCACHE_INI="/etc/php/${PHP_VERSION}/mods-available/opcache.ini"

cat > "$OPCACHE_INI" <<EOF
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.save_comments=1
EOF

echo "==> Изолированный PHP tmp"
mkdir -p "$PHP_TMP_DIR"
chown "${DEPLOY_USER}:www-data" "$PHP_TMP_DIR"
chmod 770 "$PHP_TMP_DIR"

cat > "/etc/tmpfiles.d/php-tmp-${NAME}.conf" <<EOF
d ${PHP_TMP_DIR} 0770 ${DEPLOY_USER} www-data -
EOF

echo "==> Отдельный PHP-FPM pool"
cat > "/etc/php/${PHP_VERSION}/fpm/pool.d/${NAME}.conf" <<EOF
[${FPM_POOL}]
user = ${DEPLOY_USER}
group = www-data

listen = ${FPM_SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 20
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests = 500

php_admin_value[open_basedir] = ${APP_DIR}:/tmp:${PHP_TMP_DIR}
php_admin_value[upload_tmp_dir] = ${PHP_TMP_DIR}
php_admin_value[session.save_path] = ${PHP_TMP_DIR}
php_admin_flag[log_errors] = on
php_admin_value[error_log] = ${SHARED_DIR}/logs/php-fpm.log
EOF

if [[ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]]; then
  mv "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" \
     "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf.disabled"
fi

mkdir -p "${SHARED_DIR}/logs"
chown -R "${DEPLOY_USER}:www-data" "${SHARED_DIR}/logs"
chmod 775 "${SHARED_DIR}/logs"

systemctl restart "php${PHP_VERSION}-fpm"

echo "==> WP-CLI"
curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
  -o /usr/local/bin/wp
chmod +x /usr/local/bin/wp
wp --info --allow-root

echo "==> Composer"
EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

if [[ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]]; then
  echo "Composer installer checksum failed"
  rm composer-setup.php
  exit 1
fi

php composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm composer-setup.php

echo "==> Node.js ${NODE_MAJOR}"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt install -y nodejs

echo "==> MariaDB hardening"
systemctl enable mariadb
systemctl start mariadb

mysql -uroot <<MYSQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
FLUSH PRIVILEGES;
MYSQL

echo "==> MariaDB bind to localhost only"
MARIADB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
if [[ -f "$MARIADB_CONF" ]]; then
  if grep -q "^bind-address" "$MARIADB_CONF"; then
    sed -i "s/^bind-address.*/bind-address = 127.0.0.1/" "$MARIADB_CONF"
  else
    sed -i '/^\[mysqld\]/a bind-address = 127.0.0.1' "$MARIADB_CONF"
  fi
else
  mkdir -p /etc/mysql/mariadb.conf.d
  cat > "$MARIADB_CONF" <<DBCNF
[mysqld]
bind-address = 127.0.0.1
DBCNF
fi
systemctl restart mariadb

echo "==> Создание БД"
mysql -uroot <<MYSQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
  IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL

echo "==> Создание shared .env"
cat > "${SHARED_DIR}/.env" <<EOF
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASSWORD='${DB_PASS}'
DB_HOST='localhost'

WP_ENV='production'
WP_HOME='https://${DOMAIN}'
WP_SITEURL="\${WP_HOME}/wp"

AUTH_KEY='$(openssl rand -base64 48)'
SECURE_AUTH_KEY='$(openssl rand -base64 48)'
LOGGED_IN_KEY='$(openssl rand -base64 48)'
NONCE_KEY='$(openssl rand -base64 48)'
AUTH_SALT='$(openssl rand -base64 48)'
SECURE_AUTH_SALT='$(openssl rand -base64 48)'
LOGGED_IN_SALT='$(openssl rand -base64 48)'
NONCE_SALT='$(openssl rand -base64 48)'
EOF

INITIAL_RELEASE="${RELEASES_DIR}/00000000000000"
mkdir -p "${INITIAL_RELEASE}/web"

cat > "${INITIAL_RELEASE}/web/index.html" <<EOF
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>${DOMAIN}</title>
</head>
<body>
  <h1>${DOMAIN}</h1>
  <p>Server is ready for Bedrock release deploy.</p>
</body>
</html>
EOF

ln -sfn "${INITIAL_RELEASE}" "${CURRENT_DIR}"

fix_project_permissions "${APP_DIR}"

chmod 640 "${SHARED_DIR}/.env"
chown "${DEPLOY_USER}:www-data" "${SHARED_DIR}/.env"

echo "==> Создание git_deploy SSH ключа для Git и Workflow"
if [[ ! -f "${GIT_KEY_PATH}" ]]; then
  sudo -u "${DEPLOY_USER}" ssh-keygen -t ed25519 \
    -f "${GIT_KEY_PATH}" \
    -C "${DEPLOY_USER}@${DOMAIN}-git" \
    -N ""
fi

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
chmod 600 "${GIT_KEY_PATH}"
chmod 644 "${GIT_KEY_PATH}.pub"

# git_deploy ключ добавляется в authorized_keys чтобы GitHub Actions
# мог подключаться к серверу по SSH используя secret SSH_PRIVATE_KEY.
# Это безопасно: ключ создаётся на сервере и нигде больше не используется.
if ! grep -qxF "$(cat "${GIT_KEY_PATH}.pub")" "/home/${DEPLOY_USER}/.ssh/authorized_keys"; then
  cat "${GIT_KEY_PATH}.pub" >> "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"

cat > "/home/${DEPLOY_USER}/.ssh/config" <<EOF
Host gitverse.ru
    HostName gitverse.ru
    User git
    IdentityFile ~/.ssh/git_deploy
    IdentitiesOnly yes

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/git_deploy
    IdentitiesOnly yes
EOF

chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/config"
chmod 600 "/home/${DEPLOY_USER}/.ssh/config"

sudo -u "${DEPLOY_USER}" ssh-keyscan gitverse.ru >> "/home/${DEPLOY_USER}/.ssh/known_hosts" 2>/dev/null || true
sudo -u "${DEPLOY_USER}" ssh-keyscan github.com >> "/home/${DEPLOY_USER}/.ssh/known_hosts" 2>/dev/null || true
sort -u "/home/${DEPLOY_USER}/.ssh/known_hosts" -o "/home/${DEPLOY_USER}/.ssh/known_hosts" || true
chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/known_hosts"
chmod 600 "/home/${DEPLOY_USER}/.ssh/known_hosts"

if [[ ! -f "${GIT_KEY_PATH}" ]]; then
  echo -e "${RED}ERROR: Git SSH ключ не создан: ${GIT_KEY_PATH}${NC}"
  exit 1
fi

if [[ ! -f "${GIT_KEY_PATH}.pub" ]]; then
  echo -e "${RED}ERROR: Git SSH публичный ключ не создан: ${GIT_KEY_PATH}.pub${NC}"
  exit 1
fi

echo "==> Сохранение доступов в /root/db.txt"
cat > /root/db.txt <<EOF
PROJECT_NAME=${NAME}
DOMAIN=${DOMAIN}

DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}
DB_HOST=localhost

APP_DIR=${APP_DIR}
RELEASES_DIR=${RELEASES_DIR}
SHARED_DIR=${SHARED_DIR}
CURRENT_DIR=${CURRENT_DIR}

DEPLOY_USER=${DEPLOY_USER}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASS}
SSH_PORT=${SSH_PORT}

PHP_VERSION=${PHP_VERSION}
PHP_FPM_POOL=${FPM_POOL}
PHP_FPM_SOCKET=${FPM_SOCK}
PHP_TMP_DIR=${PHP_TMP_DIR}

GIT_PRIVATE_KEY_PATH=${GIT_KEY_PATH}
GIT_PUBLIC_KEY_PATH=${GIT_KEY_PATH}.pub
EOF

chmod 600 /root/db.txt
chown root:root /root/db.txt

echo "==> Nginx temporary HTTP config"
cat > "/etc/nginx/sites-available/${NAME}-temp.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${CURRENT_DIR}/web;
    index index.html index.php;

    location /.well-known/acme-challenge/ {
        root ${SHARED_DIR}/certbot;
        allow all;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sfn "/etc/nginx/sites-available/${NAME}-temp.conf" "/etc/nginx/sites-enabled/${NAME}.conf"

nginx -t
systemctl reload nginx

echo "==> Certbot nginx reload hook"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

# Проверка что systemd timer для certbot активен
if ! systemctl is-enabled certbot.timer >/dev/null 2>&1; then
  echo "WARN: certbot.timer не найден или не активен. Проверь автообновление SSL вручную."
else
  echo "certbot.timer активен — автообновление будет работать."
fi

echo "==> SSL certificate через webroot"
read -rp "Выпустить Let's Encrypt SSL сейчас? DNS должен смотреть на сервер. [y/N]: " ISSUE_SSL

if [[ "$ISSUE_SSL" =~ ^[Yy]$ ]]; then
  certbot certonly \
    --webroot \
    -w "${SHARED_DIR}/certbot" \
    -d "${DOMAIN}" \
    -d "www.${DOMAIN}" \
    --agree-tos \
    --no-eff-email \
    -m "admin@${DOMAIN}" || {
      echo "Certbot failed. Можно повторить позже:"
      echo "certbot certonly --webroot -w ${SHARED_DIR}/certbot -d ${DOMAIN} -d www.${DOMAIN}"
    }
fi

echo "==> Nginx production HTTP/2 config без HTTP/3/QUIC"
cat > "/etc/nginx/sites-available/${NAME}.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${SHARED_DIR}/certbot;
        allow all;
    }

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    http2 on;

    server_name www.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;


    return 301 https://${DOMAIN}\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    http2 on;

    server_name ${DOMAIN};

    root ${CURRENT_DIR}/web;
    index index.php index.html;

    access_log /var/log/nginx/${NAME}.access.log;
    error_log /var/log/nginx/${NAME}.error.log;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    client_max_body_size 128M;

    location /.well-known/acme-challenge/ {
        root ${SHARED_DIR}/certbot;
        allow all;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_index index.php;
        fastcgi_read_timeout 180;
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|webp|avif|svg|ico|woff2?)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public";
        try_files \$uri =404;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* /(?:composer\.json|composer\.lock|package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|vite\.config\.\w+) {
        deny all;
    }

    location ~* ^/(vendor|storage|node_modules)/ {
        deny all;
    }
}
EOF

if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  ln -sfn "/etc/nginx/sites-available/${NAME}.conf" "/etc/nginx/sites-enabled/${NAME}.conf"
  nginx -t
  systemctl reload nginx
else
  echo "SSL ещё не выпущен, оставлен временный HTTP-конфиг."
  echo "После выпуска SSL включи production config:"
  echo "ln -sfn /etc/nginx/sites-available/${NAME}.conf /etc/nginx/sites-enabled/${NAME}.conf"
  echo "nginx -t && systemctl reload nginx"
fi

echo "==> Logrotate для логов приложения"
cat > "/etc/logrotate.d/${NAME}" <<LOGROTATE
${SHARED_DIR}/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        systemctl reload php${PHP_VERSION}-fpm >/dev/null 2>&1 || true
        systemctl reload nginx >/dev/null 2>&1 || true
    endscript
}

/var/log/nginx/${NAME}.access.log
/var/log/nginx/${NAME}.error.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        systemctl reload nginx >/dev/null 2>&1 || true
    endscript
}
LOGROTATE

echo "==> Deploy template"
cat > "/usr/local/bin/${NAME}-deploy-template" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR}"
RELEASES_DIR="${RELEASES_DIR}"
SHARED_DIR="${SHARED_DIR}"
CURRENT_DIR="${CURRENT_DIR}"
PHP_VERSION="${PHP_VERSION}"
DEPLOY_USER="${DEPLOY_USER}"
ADMIN_USER="${ADMIN_USER}"

REPO_URL="git@gitverse.ru:USER/REPO.git"
BRANCH="master"
THEME_DIR="web/app/themes/THEME_NAME"

RELEASE="\${RELEASES_DIR}/\$(date +%Y%m%d%H%M%S)"
PREVIOUS_RELEASE="\$(readlink -f "\${CURRENT_DIR}" 2>/dev/null || echo "")"
THEME_CACHE="\${SHARED_DIR}/node_modules_cache"

# Откат на предыдущий релиз при любой ошибке после переключения symlink
_SWITCHED=0
trap '
  if [[ "\$_SWITCHED" -eq 1 && -n "\$PREVIOUS_RELEASE" && -d "\$PREVIOUS_RELEASE" ]]; then
    echo "==> ERROR: откат на предыдущий релиз \${PREVIOUS_RELEASE}"
    ln -sfn "\${PREVIOUS_RELEASE}" "\${CURRENT_DIR}"
    sudo /bin/systemctl reload php${PHP_VERSION}-fpm || true
    sudo /bin/systemctl reload nginx || true
  fi
  [[ -d "\${RELEASE}" ]] && rm -rf "\${RELEASE}"
' ERR

git clone --branch "\${BRANCH}" --depth 1 "\${REPO_URL}" "\${RELEASE}"

ln -sfn "\${SHARED_DIR}/.env" "\${RELEASE}/.env"

rm -rf "\${RELEASE}/web/app/uploads"
ln -sfn "\${SHARED_DIR}/web/app/uploads" "\${RELEASE}/web/app/uploads"

rm -rf "\${RELEASE}/web/app/cache"
ln -sfn "\${SHARED_DIR}/web/app/cache" "\${RELEASE}/web/app/cache"

cd "\${RELEASE}"
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction

if [[ -d "\${RELEASE}/\${THEME_DIR}" ]]; then
  cd "\${RELEASE}/\${THEME_DIR}"

  if [[ -f composer.json ]]; then
    composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
  fi

  # Кэш node_modules между релизами для ускорения деплоя
  if [[ -d "\${THEME_CACHE}" ]]; then
    echo "==> Restoring node_modules from cache"
    cp -r "\${THEME_CACHE}" node_modules
  fi

  npm ci
  npm run build

  echo "==> Updating node_modules cache"
  rm -rf "\${THEME_CACHE}"
  cp -r node_modules "\${THEME_CACHE}"
fi

chgrp -R www-data "\${RELEASE}"
find "\${RELEASE}" -type d -exec chmod 2775 {} \\;
find "\${RELEASE}" -type f -exec chmod 664 {} \\;
setfacl -R -m "u:\${DEPLOY_USER}:rwx" "\${RELEASE}"
setfacl -R -m "u:\${ADMIN_USER}:rwx" "\${RELEASE}"
setfacl -R -m "g:www-data:rwx" "\${RELEASE}"
setfacl -R -d -m "u:\${DEPLOY_USER}:rwx" "\${RELEASE}"
setfacl -R -d -m "u:\${ADMIN_USER}:rwx" "\${RELEASE}"
setfacl -R -d -m "g:www-data:rwx" "\${RELEASE}"

ln -sfn "\${RELEASE}" "\${CURRENT_DIR}"
_SWITCHED=1

sudo /bin/systemctl reload php${PHP_VERSION}-fpm
sudo /bin/systemctl reload nginx

echo "==> WP cache flush"
wp --path="\${CURRENT_DIR}/web/wp" --allow-root acorn optimize:clear || true
wp --path="\${CURRENT_DIR}/web/wp" --allow-root cache flush || true

echo "==> DB migrations"
wp --path="\${CURRENT_DIR}/web/wp" --allow-root core update-db || true

echo "==> Health check"
DOMAIN_CHECK="\$(grep WP_HOME "\${SHARED_DIR}/.env" | cut -d"'" -f2 | sed 's|https://||')"
if [[ -n "\${DOMAIN_CHECK}" ]]; then
  HTTP_CODE="\$(curl -sk -o /dev/null -w "%{http_code}" "https://\${DOMAIN_CHECK}/" || echo "000")"
  if [[ "\${HTTP_CODE}" != "200" && "\${HTTP_CODE}" != "301" && "\${HTTP_CODE}" != "302" ]]; then
    echo "WARN: site returned HTTP \${HTTP_CODE} — проверь сайт вручную"
  else
    echo "Health check OK: HTTP \${HTTP_CODE}"
  fi
fi

find "\${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | head -n -5 | xargs -r rm -rf
EOF

chmod +x "/usr/local/bin/${NAME}-deploy-template"

echo "==> Ограниченный sudo для reload сервисов"
cat > "/etc/sudoers.d/${DEPLOY_USER}-${NAME}" <<EOF
${DEPLOY_USER} ALL=NOPASSWD: /bin/systemctl reload php${PHP_VERSION}-fpm
${DEPLOY_USER} ALL=NOPASSWD: /bin/systemctl reload nginx
EOF

chmod 440 "/etc/sudoers.d/${DEPLOY_USER}-${NAME}"
visudo -cf "/etc/sudoers.d/${DEPLOY_USER}-${NAME}"

echo ""
echo -e "${YELLOW}FINAL GIT ACCESS CHECK${NC}"
echo "============================================"
echo "Публичный ключ для GitVerse/GitHub/GitLab:"
echo "============================================"
cat "${GIT_KEY_PATH}.pub"
echo "============================================"
echo ""
echo "Добавь этот ключ в GitVerse/GitHub/GitLab:"
echo "  Repository → Settings → Deploy keys"
echo "или:"
echo "  Profile → Settings → SSH keys"
echo ""
read -rp "Нажми Enter после добавления публичного ключа в GitVerse/GitHub/GitLab..."

echo ""
echo "Проверка GitVerse:"
su - "${DEPLOY_USER}" -c "ssh -T git@gitverse.ru" || true
echo ""
echo "Проверка GitHub:"
su - "${DEPLOY_USER}" -c "ssh -T git@github.com" || true
echo ""
echo "Если получил Permission denied (publickey), значит публичный ключ ещё не добавлен в Git-хостинг."
echo "Если получил Host key verification failed, значит проблема с known_hosts."
echo ""

echo ""
echo -e "${RED}====================================================${NC}"
echo -e "${RED}ВАЖНО: ПРОВЕРЬ SSH-ДОСТУП ПЕРЕД ЗАКРЫТИЕМ ROOT-СЕССИИ${NC}"
echo -e "${RED}====================================================${NC}"
echo "Root вход и вход по паролю отключены."
echo "Дальше подключайся по SSH-ключу:"
echo "  - обычный deploy: ${DEPLOY_USER}"
echo "  - sudo/root-пользователь: ${ADMIN_USER}"
echo ""
echo "Команда проверки deploy:"
echo "  ssh -i ~/.ssh/deploy_server -p ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}"
echo ""
echo "Команда проверки sudo/root-пользователя:"
echo "  ssh -i ~/.ssh/deploy_server -p ${SSH_PORT} ${ADMIN_USER}@${SERVER_IP_DETECTED}"
echo ""
echo "Windows CMD:"
echo "  ssh -i %USERPROFILE%\\.ssh\\deploy_server -p ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}"
echo ""
echo "Windows PowerShell:"
echo "  ssh -i \$env:USERPROFILE\\.ssh\\deploy_server -p ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}"
echo ""
echo "Если после переустановки сервера появилась ошибка REMOTE HOST IDENTIFICATION HAS CHANGED:"
echo "  ssh-keygen -R \"[${SERVER_IP_DETECTED}]:${SSH_PORT}\""
echo ""
echo -e "${RED}НЕ ЗАКРЫВАЙ текущую root-сессию, пока SSH вход не проверен.${NC}"
echo -e "${RED}====================================================${NC}"
echo ""
read -rp "Нажми Enter для вывода итоговой информации..." _CONFIRM_FINAL

echo ""
echo "============================================"
echo "SERVER READY"
echo "============================================"
echo "Project:       ${NAME}"
echo "Domain:        ${DOMAIN}"
echo "App dir:       ${APP_DIR}"
echo "Current:       ${CURRENT_DIR}"
echo "Deploy user:   ${DEPLOY_USER}"
echo "Admin user:    ${ADMIN_USER}"
echo "Admin pass:    ${ADMIN_PASS}"
echo "SSH port:      ${SSH_PORT}"
echo ""
echo "DB_NAME:       ${DB_NAME}"
echo "DB_USER:       ${DB_USER}"
echo "DB_PASSWORD:   ${DB_PASS}"
echo ""
echo "Saved to:      /root/db.txt"
echo ""
echo "WORKFLOW SSH_PRIVATE_KEY:"
echo "============================================"
echo -e "${YELLOW}Приватный ключ НЕ выводится в терминал из соображений безопасности.${NC}"
echo "Скопируй его вручную из защищённого файла:"
echo ""
echo "  cat ${GIT_KEY_PATH}"
echo ""
echo "Или скачай с сервера (с ПК):"
echo "  scp -i ~/.ssh/deploy_server -P ${SSH_PORT} ${DEPLOY_USER}@${SERVER_IP_DETECTED}:${GIT_KEY_PATH} ./git_deploy_key"
echo ""
echo "Этот приватный ключ добавь в GitHub Actions secret:"
echo "  SSH_PRIVATE_KEY"
echo ""
echo "Публичная часть уже автоматически добавлена в:"
echo "  /home/${DEPLOY_USER}/.ssh/authorized_keys"
echo ""
echo "Workflow secrets:"
echo "  VM_PUBLIC_IP=${SERVER_IP_DETECTED}"
echo "  VM_USERNAME=${DEPLOY_USER}"
echo "  VM_PORT=${SSH_PORT}"
echo "  PROJECT_NAME=${NAME}"
echo "  PHP_VERSION=${PHP_VERSION}"
echo "============================================"
