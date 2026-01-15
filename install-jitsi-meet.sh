#!/bin/bash

# Jitsi Meet Auto-Installer Script
# Version: 1.0
# Author: Jitsi Docker Helper

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "Этот скрипт должен быть запущен с правами root (sudo)"
    exit 1
fi

log "Начинаем установку Jitsi Meet Docker..."

# Ask for user input
read -p "Введите доменное имя вашего Jitsi сервера (например, meet.example.com): " DOMAIN
read -p "Введите email для Let's Encrypt (для уведомлений): " EMAIL
read -p "Введите пароль для Jitsi администратора: " -s JITSI_PASS
echo ""
read -p "Повторите пароль: " -s JITSI_PASS_CONFIRM
echo ""

if [ "$JITSI_PASS" != "$JITSI_PASS_CONFIRM" ]; then
    error "Пароли не совпадают!"
    exit 1
fi

# Update system
log "Обновление системы..."
apt update && apt upgrade -y

# Install required packages
log "Установка необходимых пакетов..."
apt install -y curl git wget nano

# Install Docker
if ! command -v docker &> /dev/null; then
    log "Установка Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    log "Docker уже установлен"
fi

# Install Docker Compose
if ! command -v docker-compose &> /dev/null; then
    log "Установка Docker Compose..."
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    log "Docker Compose уже установлен"
fi

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Create jitsi user
if ! id "jitsi" &>/dev/null; then
    log "Создание пользователя jitsi..."
    useradd -m -s /bin/bash -G docker jitsi
else
    log "Пользователь jitsi уже существует"
fi

# Clone Jitsi Docker
log "Клонирование Jitsi Docker репозитория..."
cd /home/jitsi
if [ -d "docker-jitsi-meet" ]; then
    warn "Директория docker-jitsi-meet уже существует. Делаем backup..."
    mv docker-jitsi-meet docker-jitsi-meet.backup-$(date +%Y%m%d-%H%M%S)
fi

git clone https://github.com/jitsi/docker-jitsi-meet
cd docker-jitsi-meet

# Create .env file from template
log "Создание конфигурационного файла..."
cp env.example .env

# Configure .env file
log "Настройка конфигурации..."

# Generate strong secrets
JICOFO_COMPONENT_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
JICOFO_AUTH_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
JVB_AUTH_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
JIGASI_XMPP_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
JIBRI_RECORDER_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
JIBRI_XMPP_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

# Update .env file with user inputs
sed -i "s|#PUBLIC_URL=https://meet.example.com|PUBLIC_URL=https://${DOMAIN}|g" .env
sed -i "s|#ENABLE_LETSENCRYPT=1|ENABLE_LETSENCRYPT=1|g" .env
sed -i "s|#LETSENCRYPT_DOMAIN=|LETSENCRYPT_DOMAIN=${DOMAIN}|g" .env
sed -i "s|#LETSENCRYPT_EMAIL=|LETSENCRYPT_EMAIL=${EMAIL}|g" .env
sed -i "s|#ENABLE_HTTP_REDIRECT=1|ENABLE_HTTP_REDIRECT=1|g" .env
sed -i "s|#DISABLE_HTTPS=0|DISABLE_HTTPS=0|g" .env

# Set passwords
sed -i "s|#JICOFO_COMPONENT_SECRET=|JICOFO_COMPONENT_SECRET=${JICOFO_COMPONENT_SECRET}|g" .env
sed -i "s|#JICOFO_AUTH_PASSWORD=|JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}|g" .env
sed -i "s|#JVB_AUTH_PASSWORD=|JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}|g" .env
sed -i "s|#JIGASI_XMPP_PASSWORD=|JIGASI_XMPP_PASSWORD=${JIGASI_XMPP_PASSWORD}|g" .env
sed -i "s|#JIBRI_RECORDER_PASSWORD=|JIBRI_RECORDER_PASSWORD=${JIBRI_RECORDER_PASSWORD}|g" .env
sed -i "s|#JIBRI_XMPP_PASSWORD=|JIBRI_XMPP_PASSWORD=${JIBRI_XMPP_PASSWORD}|g" .env

# Set XMPP domain
sed -i "s|#XMPP_DOMAIN=|XMPP_DOMAIN=${DOMAIN}|g" .env
sed -i "s|#XMPP_AUTH_DOMAIN=|XMPP_AUTH_DOMAIN=auth.${DOMAIN}|g" .env
sed -i "s|#XMPP_GUEST_DOMAIN=|XMPP_GUEST_DOMAIN=guest.${DOMAIN}|g" .env
sed -i "s|#XMPP_MUC_DOMAIN=|XMPP_MUC_DOMAIN=muc.${DOMAIN}|g" .env
sed -i "s|#XMPP_INTERNAL_MUC_DOMAIN=|XMPP_INTERNAL_MUC_DOMAIN=internal-muc.${DOMAIN}|g" .env
sed -i "s|#XMPP_RECORDER_DOMAIN=|XMPP_RECORDER_DOMAIN=recorder.${DOMAIN}|g" .env

# Set JWT authentication (optional)
read -p "Включить JWT аутентификацию? (y/n): " ENABLE_JWT
if [[ $ENABLE_JWT =~ ^[Yy]$ ]]; then
    sed -i "s|#ENABLE_AUTH=0|ENABLE_AUTH=1|g" .env
    sed -i "s|#ENABLE_GUESTS=1|ENABLE_GUESTS=0|g" .env
    sed -i "s|#AUTH_TYPE=|AUTH_TYPE=jwt|g" .env
    JWT_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)
    sed -i "s|#JWT_APP_ID=|JWT_APP_ID=jitsi|g" .env
    sed -i "s|#JWT_APP_SECRET=|JWT_APP_SECRET=${JWT_SECRET}|g" .env
    sed -i "s|#JWT_ACCEPTED_ISSUERS=|JWT_ACCEPTED_ISSUERS=jitsi|g" .env
    sed -i "s|#JWT_ACCEPTED_AUDIENCES=|JWT_ACCEPTED_AUDIENCES=jitsi|g" .env
    log "JWT аутентификация включена. Секрет: ${JWT_SECRET}"
fi

# Create configuration directory
log "Создание конфигурационных директорий..."
mkdir -p ~/.jitsi-meet-cfg/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}

# Set proper permissions
chown -R jitsi:jitsi /home/jitsi/docker-jitsi-meet
chown -R jitsi:jitsi ~/.jitsi-meet-cfg

# Configure firewall
log "Настройка фаервола..."
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 10000/udp
    ufw allow 3478/udp
    ufw allow 5349/tcp
    ufw reload
    log "Правила фаервола добавлены"
fi

# Switch to jitsi user and start containers
log "Запуск Jitsi Meet контейнеров..."
sudo -u jitsi bash << EOF
cd /home/jitsi/docker-jitsi-meet
docker-compose up -d
EOF

# Wait for containers to start
log "Ожидание запуска контейнеров (30 секунд)..."
sleep 30

# Check if containers are running
log "Проверка состояния контейнеров..."
cd /home/jitsi/docker-jitsi-meet
CONTAINERS_RUNNING=$(docker-compose ps | grep Up | wc -l)

if [ $CONTAINERS_RUNNING -ge 4 ]; then
    log "✓ Все контейнеры запущены успешно!"
else
    warn "Некоторые контейнеры не запущены. Проверьте логи: docker-compose logs"
fi

# Display installation summary
echo ""
echo "================================================"
echo "          УСТАНОВКА ЗАВЕРШЕНА!"
echo "================================================"
echo ""
echo "Данные для доступа:"
echo "• Домен: https://${DOMAIN}"
echo "• Email Let's Encrypt: ${EMAIL}"
echo ""
echo "Пароли (сохраните их!):"
echo "• JICOFO_COMPONENT_SECRET: ${JICOFO_COMPONENT_SECRET}"
echo "• JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}"
echo "• JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}"
if [[ $ENABLE_JWT =~ ^[Yy]$ ]]; then
    echo "• JWT_SECRET: ${JWT_SECRET}"
fi
echo ""
echo "Управление:"
echo "• Просмотр логов: cd /home/jitsi/docker-jitsi-meet && docker-compose logs -f"
echo "• Остановить: cd /home/jitsi/docker-jitsi-meet && docker-compose down"
echo "• Обновить: cd /home/jitsi/docker-jitsi-meet && docker-compose pull && docker-compose up -d"
echo "• Backup данных: cp -r ~/.jitsi-meet-cfg ~/jitsi-backup-\$(date +%Y%m%d)"
echo ""
echo "Проверка SSL сертификата (через 5 минут):"
echo "curl https://${DOMAIN}"
echo ""
echo "Проблемы? Проверьте:"
echo "1. DNS записи для ${DOMAIN}"
echo "2. Порт 80 и 443 открыты на фаерволе"
echo "3. Логи: docker-compose logs web"
echo "================================================"

# Create management script
cat > /usr/local/bin/jitsi-manage << 'EOF'
#!/bin/bash
case "$1" in
    start)
        cd /home/jitsi/docker-jitsi-meet && docker-compose up -d
        ;;
    stop)
        cd /home/jitsi/docker-jitsi-meet && docker-compose down
        ;;
    restart)
        cd /home/jitsi/docker-jitsi-meet && docker-compose restart
        ;;
    logs)
        cd /home/jitsi/docker-jitsi-meet && docker-compose logs -f
        ;;
    update)
        cd /home/jitsi/docker-jitsi-meet && docker-compose pull && docker-compose up -d
        ;;
    status)
        cd /home/jitsi/docker-jitsi-meet && docker-compose ps
        ;;
    backup)
        cp -r ~/.jitsi-meet-cfg ~/jitsi-backup-$(date +%Y%m%d-%H%M%S)
        echo "Backup создан"
        ;;
    *)
        echo "Использование: jitsi-manage {start|stop|restart|logs|update|status|backup}"
        exit 1
        ;;
esac
EOF

chmod +x /usr/local/bin/jitsi-manage
log "Скрипт управления создан: jitsi-manage"

# Save credentials to file
cat > /home/jitsi/jitsi-credentials.txt << EOF
Jitsi Meet Installation Details
===============================
Domain: https://${DOMAIN}
Installation Date: $(date)

Configuration:
- Public URL: https://${DOMAIN}
- Let's Encrypt Email: ${EMAIL}
- XMPP Domain: ${DOMAIN}

Passwords:
- JICOFO_COMPONENT_SECRET: ${JICOFO_COMPONENT_SECRET}
- JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}
- JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}
EOF

if [[ $ENABLE_JWT =~ ^[Yy]$ ]]; then
    echo "- JWT_SECRET: ${JWT_SECRET}" >> /home/jitsi/jitsi-credentials.txt
fi

chown jitsi:jitsi /home/jitsi/jitsi-credentials.txt
chmod 600 /home/jitsi/jitsi-credentials.txt

log "Данные сохранены в /home/jitsi/jitsi-credentials.txt"
log "Для доступа к файлу: sudo cat /home/jitsi/jitsi-credentials.txt"