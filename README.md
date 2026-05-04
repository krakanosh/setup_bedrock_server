# Bedrock WordPress — Server Setup & Deploy

Комплект для развёртывания WordPress на стеке [Roots Bedrock](https://roots.io/bedrock/) + [Sage](https://roots.io/sage/) на Debian 13 с автодеплоем через GitHub Actions.

## Что входит

| Файл | Назначение |
|------|-----------|
| `init-bedrock-server.sh` | Настройка чистого сервера Debian 13 |
| `.github/workflows/deploy.yml` | GitHub Actions — автодеплой при push в `master` |

## Стек

- **Nginx** mainline (nginx.org) + HTTP/2 + Let's Encrypt SSL
- **PHP 8.4** FPM с изолированным pool и opcache
- **MariaDB** с hardening
- **Composer** + **Node.js 22** + **WP-CLI**
- **Rolling deploys** — хранятся последние 5 релизов, автооткат при ошибке

---

## Часть 1. Настройка сервера

### Требования

- Чистый **Debian 13** VPS
- Root-доступ по SSH
- Домен, указывающий на IP сервера (для SSL)
- SSH-ключ на локальном ПК

### Шаг 1. Создание SSH-ключа (если ещё нет)

**WSL / Linux / macOS:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/deploy_server
cat ~/.ssh/deploy_server.pub  # скопируй этот ключ
```

**Windows CMD:**
```cmd
ssh-keygen -t ed25519 -f %USERPROFILE%\.ssh\deploy_server
type %USERPROFILE%\.ssh\deploy_server.pub
```

**Windows PowerShell:**
```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\deploy_server
type $env:USERPROFILE\.ssh\deploy_server.pub
```

### Шаг 2. Загрузка скрипта на сервер

```bash
scp init-bedrock-server.sh root@YOUR_SERVER_IP:/root/
```

### Шаг 3. Запуск

```bash
# На сервере от root
chmod +x /root/init-bedrock-server.sh
bash /root/init-bedrock-server.sh
```

> ⚠️ **Не закрывай root-сессию** во время установки. Скрипт отключит вход по паролю и root-login. Перед продолжением он попросит проверить SSH-доступ в отдельном окне терминала.

### Шаг 4. Ответы на вопросы скрипта

| Вопрос | Пример |
|--------|--------|
| Project name | `myshop` (только a-z, 0-9, `_`, `-`) |
| Domain | `example.com` |
| Deploy user | `deploy` |
| Root/sudo user | `admin` |
| SSH port | `2222` |
| Public SSH key | вставь содержимое `deploy_server.pub` |

Далее скрипт:
1. Попросит **проверить SSH-доступ** в новом окне терминала — сделай это не закрывая текущую сессию
2. Спросит **выпускать ли SSL** прямо сейчас (введи `y` если DNS уже смотрит на сервер)
3. Выведет **публичный deploy-ключ** — его нужно добавить в GitHub/GitVerse

### Шаг 5. Проверка SSH-доступа

Открой **новое** окно терминала и проверь:

```bash
# WSL / Linux / macOS
ssh -i ~/.ssh/deploy_server -p 2222 deploy@YOUR_SERVER_IP

# Windows CMD
ssh -i %USERPROFILE%\.ssh\deploy_server -p 2222 deploy@YOUR_SERVER_IP
```

> Если ошибка `REMOTE HOST IDENTIFICATION HAS CHANGED` — выполни:
> ```bash
> ssh-keygen -R "[YOUR_SERVER_IP]:2222"
> ```
> затем повтори подключение и подтверди новый ключ (`yes`).

### Что создаётся на сервере

```
/var/www/PROJECT_NAME/
├── current/              → симлинк на актуальный релиз
├── releases/             → последние 5 релизов
└── shared/
    ├── .env              → настройки окружения (БД, ключи WP)
    ├── web/app/uploads/  → медиафайлы
    └── web/app/cache/    → кэш Acorn/Blade
```

Все учётные данные (БД, пароли, SSH-порт) сохраняются в `/root/db.txt`.

---

## Часть 2. Настройка GitHub Actions

### Шаг 1. Получи приватный SSH-ключ

Скрипт создал ключ `git_deploy` — он используется GitHub Actions для подключения к серверу:

```bash
# На сервере
cat /home/deploy/.ssh/git_deploy
```

Скопируй вывод **целиком** — включая строки `-----BEGIN OPENSSH PRIVATE KEY-----` и `-----END OPENSSH PRIVATE KEY-----`.

### Шаг 2. Добавь secrets в GitHub

Перейди в **Repository → Settings → Secrets and variables → Actions** и добавь:

| Secret | Значение |
|--------|----------|
| `SSH_PRIVATE_KEY` | содержимое `/home/deploy/.ssh/git_deploy` |
| `VM_PUBLIC_IP` | IP сервера |
| `VM_USERNAME` | имя deploy-пользователя (например `deploy`) |
| `VM_PORT` | SSH-порт (например `2222`) |
| `PROJECT_NAME` | имя проекта (например `myshop`) |
| `PHP_VERSION` | версия PHP (например `8.4`) |
| `REPO_URL` | SSH-адрес репозитория (`git@github.com:user/repo.git`) |
| `DEPLOY_BRANCH` | ветка для деплоя (например `master`) |
| `THEME_DIR` | путь к теме (например `web/app/themes/my-theme`) |

### Шаг 3. Добавь workflow в репозиторий

Скопируй `deploy.yml` в `.github/workflows/deploy.yml` в корне репозитория.

Деплой запускается автоматически при каждом `push` в ветку `master`, либо вручную через **Actions → Run workflow**.

---

## Часть 3. Миграция данных

### Экспорт БД из DDEV

```bash
cd ~/projects/old-wordpress

# Экспортировать и распаковать
ddev export-db --file=old-site-dump.sql.gz
gunzip old-site-dump.sql.gz

# Заменить URL — подставь свои значения
sed -i 's|https://old-site.ddev.site|https://example.com|g' old-site-dump.sql
sed -i 's|http://old-site.ddev.site|https://example.com|g' old-site-dump.sql
```

### Загрузка дампа на сервер

```bash
# WSL / Linux / macOS
scp -i ~/.ssh/deploy_server -P 2222 \
  old-site-dump.sql deploy@YOUR_SERVER_IP:/tmp/old-site-dump.sql
```

### Импорт БД на сервере

```bash
# На сервере — считать данные из .env и импортировать
DB_NAME=$(grep DB_NAME /var/www/PROJECT_NAME/shared/.env | cut -d"'" -f2)
DB_USER=$(grep DB_USER /var/www/PROJECT_NAME/shared/.env | cut -d"'" -f2)
DB_PASS=$(grep DB_PASSWORD /var/www/PROJECT_NAME/shared/.env | cut -d"'" -f2)

mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < /tmp/old-site-dump.sql

rm /tmp/old-site-dump.sql
```

### Копирование медиафайлов

В Bedrock медиафайлы хранятся в `web/app/uploads/` (не в `wp-content/uploads/`).

```bash
# WSL: путь \\wsl.localhost\Ubuntu\home\user\... пишется как /home/user/...
rsync -avz --progress \
  -e "ssh -i ~/.ssh/deploy_server -p 2222" \
  /home/sidweb/projects/old-site/wp-content/uploads/ \
  deploy@YOUR_SERVER_IP:/var/www/PROJECT_NAME/shared/web/app/uploads/
```

### Права на медиафайлы

```bash
# На сервере
sudo chgrp -R www-data /var/www/PROJECT_NAME/shared/web/app/uploads/
sudo find /var/www/PROJECT_NAME/shared/web/app/uploads/ -type d -exec chmod 2775 {} \;
sudo find /var/www/PROJECT_NAME/shared/web/app/uploads/ -type f -exec chmod 664 {} \;
```

### Проверка после миграции

```bash
# Сбросить кэш
wp --path=/var/www/PROJECT_NAME/current/web/wp --allow-root cache flush

# Проверить URL в БД
wp --path=/var/www/PROJECT_NAME/current/web/wp --allow-root option get siteurl
wp --path=/var/www/PROJECT_NAME/current/web/wp --allow-root option get home
```

Если URL в БД остался старым:

```bash
wp --path=/var/www/PROJECT_NAME/current/web/wp --allow-root \
  search-replace 'https://old-site.ddev.site' 'https://example.com' \
  --all-tables
```

---

## Устранение типичных проблем

### 502 Bad Gateway

Nginx не может подключиться к PHP-FPM из-за прав на сокет:

```bash
sudo usermod -aG www-data nginx
sudo systemctl restart nginx
```

### SSH: Permission denied (publickey)

Публичный ключ не совпадает с тем что в `authorized_keys`. Сравни отпечатки:

```bash
# На сервере
cat /home/deploy/.ssh/authorized_keys

# Локально
ssh-keygen -lf ~/.ssh/deploy_server.pub
```

### GitHub Actions: Invalid PHP_VERSION

Не добавлен secret `PHP_VERSION`. Добавь в **Repository → Settings → Secrets → Actions**:

| Secret | Значение |
|--------|----------|
| `PHP_VERSION` | `8.4` |

### GitHub Actions: SSH handshake failed

Secret `SSH_PRIVATE_KEY` скопирован с ошибкой. Убедись что:
- скопировано содержимое `/home/deploy/.ssh/git_deploy` (не `.pub`)
- включены строки `-----BEGIN...-----` и `-----END...-----`
- нет лишних пробелов в начале строк
