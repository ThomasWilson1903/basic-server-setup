#!/bin/bash

# Jitsi Meet Auto-Installer Script
# Version: 1.1
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

# Update system
log "Обновление системы..."
apt update && apt upgrade -y

# Install required packages
log "Установка необходимых пакетов..."
apt install -y curl git wget nano jq

# Install Docker
if ! command -v docker &> /dev/null; then
    log "Установка Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    log "Docker уже установлен"
fi

# Install Docker Compose v2 (современная версия)
if ! command -v docker compose &> /dev/null; then
    log "Установка Docker Compose plugin..."
    apt install -y docker-compose-plugin
else
    log "Docker Compose уже установлен"
fi

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Configure Docker DNS (важно для Let's Encrypt)
log "Настройка Docker DNS..."
sudo tee /etc/docker/daemon.json << EOF
{
  "dns": ["8.8.8.8", "1.1.1.1"],
  "dns-opts": ["timeout:2", "attempts:2"]
}
EOF
sudo systemctl restart docker

# Create jitsi user
if ! id "jitsi" &>/dev/null; then
    log "Создание пользователя jitsi..."
    useradd -m -s /bin/bash -G docker jitsi
    echo "jitsi ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/jitsi
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
JICOFO_COMPONENT_SECRET=$(openssl rand -hex 32)
JICOFO_AUTH_PASSWORD=$(openssl rand -hex 32)
JVB_AUTH_PASSWORD=$(openssl rand -hex 32)
JIGASI_XMPP_PASSWORD=$(openssl rand -hex 32)
JIBRI_RECORDER_PASSWORD=$(openssl rand -hex 32)
JIBRI_XMPP_PASSWORD=$(openssl rand -hex 32)

# Функция для безопасной настройки переменных
set_env_var() {
    local var_name="$1"
    local value="$2"

    if grep -q "^#*${var_name}=" .env; then
        # Заменяем существующее значение
        sed -i "s|^#*${var_name}=.*|${var_name}=${value}|g" .env
    else
        # Добавляем новую строку
        echo "${var_name}=${value}" >> .env
    fi
}

# Update .env file with user inputs
set_env_var "PUBLIC_URL" "https://${DOMAIN}"
set_env_var "ENABLE_LETSENCRYPT" "1"
set_env_var "LETSENCRYPT_DOMAIN" "${DOMAIN}"
set_env_var "LETSENCRYPT_EMAIL" "${EMAIL}"
set_env_var "ENABLE_HTTP_REDIRECT" "1"
set_env_var "DISABLE_HTTPS" "0"

# Set passwords
set_env_var "JICOFO_COMPONENT_SECRET" "${JICOFO_COMPONENT_SECRET}"
set_env_var "JICOFO_AUTH_PASSWORD" "${JICOFO_AUTH_PASSWORD}"
set_env_var "JVB_AUTH_PASSWORD" "${JVB_AUTH_PASSWORD}"
set_env_var "JIGASI_XMPP_PASSWORD" "${JIGASI_XMPP_PASSWORD}"
set_env_var "JIBRI_RECORDER_PASSWORD" "${JIBRI_RECORDER_PASSWORD}"
set_env_var "JIBRI_XMPP_PASSWORD" "${JIBRI_XMPP_PASSWORD}"

# Set XMPP domain
set_env_var "XMPP_DOMAIN" "${DOMAIN}"
set_env_var "XMPP_AUTH_DOMAIN" "auth.${DOMAIN}"
set_env_var "XMPP_GUEST_DOMAIN" "guest.${DOMAIN}"
set_env_var "XMPP_MUC_DOMAIN" "muc.${DOMAIN}"
set_env_var "XMPP_INTERNAL_MUC_DOMAIN" "internal-muc.${DOMAIN}"
set_env_var "XMPP_RECORDER_DOMAIN" "recorder.${DOMAIN}"

# Set IP address
DOCKER_HOST_ADDRESS=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
set_env_var "DOCKER_HOST_ADDRESS" "${DOCKER_HOST_ADDRESS}"

# Set JWT authentication (optional)
read -p "Включить JWT аутентификацию? (y/n): " ENABLE_JWT
if [[ $ENABLE_JWT =~ ^[Yy]$ ]]; then
    set_env_var "ENABLE_AUTH" "1"
    set_env_var "ENABLE_GUESTS" "0"
    set_env_var "AUTH_TYPE" "jwt"
    JWT_SECRET=$(openssl rand -hex 64)
    set_env_var "JWT_APP_ID" "jitsi"
    set_env_var "JWT_APP_SECRET" "${JWT_SECRET}"
    set_env_var "JWT_ACCEPTED_ISSUERS" "jitsi"
    set_env_var "JWT_ACCEPTED_AUDIENCES" "jitsi"
    log "JWT аутентификация включена. Секрет: ${JWT_SECRET}"
fi

# Create configuration directory
log "Создание конфигурационных директорий..."
sudo mkdir -p /home/jitsi/.jitsi-meet-cfg/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}

# Set proper permissions
sudo chown -R jitsi:jitsi /home/jitsi/docker-jitsi-meet
sudo chown -R jitsi:jitsi /home/jitsi/.jitsi-meet-cfg

# Configure firewall
log "Настройка фаервола..."
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 10000/udp
    ufw allow 3478/udp
    ufw allow 5349/tcp
    ufw --force enable
    ufw reload
    log "Правила фаервола добавлены"
else
    warn "UFW не установлен. Не забудьте открыть порты в фаерволе!"
fi

# Switch to jitsi user and start containers
log "Запуск Jitsi Meet контейнеров..."
sudo -u jitsi bash << EOF
cd /home/jitsi/docker-jitsi-meet
docker compose up -d
EOF

# Wait for containers to start
log "Ожидание запуска контейнеров (60 секунд)..."
sleep 60

# Check if containers are running
log "Проверка состояния контейнеров..."
cd /home/jitsi/docker-jitsi-meet
CONTAINERS_RUNNING=$(sudo -u jitsi docker compose ps | grep Up | wc -l)

if [ $CONTAINERS_RUNNING -ge 4 ]; then
    log "✓ Все контейнеры запущены успешно!"
else
    warn "Некоторые контейнеры не запущены. Проверьте логи..."
    sudo -u jitsi docker compose logs --tail=50
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
echo "• IP адрес сервера: ${DOCKER_HOST_ADDRESS}"
echo ""
echo "Пароли (сохраните их!):"
echo "• JICOFO_COMPONENT_SECRET: ${JICOFO_COMPONENT_SECRET}"
echo "• JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}"
echo "• JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}"
if [[ $ENABLE_JWT =~ ^[Yy]$ ]]; then
    echo "• JWT_SECRET: ${JWT_SECRET}"
fi
echo ""
echo "ВАЖНО: Настройте DNS запись!"
echo "Добавьте A запись для ${DOMAIN} → ${DOCKER_HOST_ADDRESS}"
echo ""
echo "Управление:"
echo "• Просмотр логов: cd /home/jitsi/docker-jitsi-meet && docker compose logs -f"
echo "• Остановить: cd /home/jitsi/docker-jitsi-meet && docker compose down"
echo "• Обновить: cd /home/jitsi/docker-jitsi-meet && docker compose pull && docker compose up -d"
echo "• Статус: cd /home/jitsi/docker-jitsi-meet && docker compose ps"
echo ""
echo "Проверка SSL сертификата (через 5 минут):"
echo "curl -I https://${DOMAIN} 2>/dev/null | head -1"
echo ""
echo "Проблемы? Проверьте:"
echo "1. DNS записи для ${DOMAIN}"
echo "2. Порт 80 и 443 открыты на фаерволе"
echo "3. Логи: cd /home/jitsi/docker-jitsi-meet && docker compose logs web"
echo "================================================"

# Create management script
cat > /usr/local/bin/jitsi-manage << 'EOF'
#!/bin/bash
case "$1" in
    start)
        cd /home/jitsi/docker-jitsi-meet && sudo -u jitsi docker compose up -d
        ;;
    stop)
        cd /home/jitsi/docker-jitsi-meet && sudo -u jitsi docker compose down
        ;;
    restart)
        cd /home/jitsi/docker-jitsi-meet && sudo -u jitsi docker compose restart
        ;;
    logs)
        cd /home/jitsi/docker-jitsi-meet && sudo -u jitsi docker compose logs -f
        ;;
    update)
        cd /home/jitsi/docker-jitsi-meet && sudo -u jitsi docker compose pull && sudo -u jitsi docker compose up -d
        ;;
    status)
        cd /home/jitsi/docker-jitsi-meet && sudo -u jitsi docker compose ps
        ;;
    backup)
        sudo cp -r /home/jitsi/.jitsi-meet-cfg /home/jitsi/jitsi-backup-$(date +%Y%m%d-%H%M%S)
        echo "Backup создан"
        ;;
    config)
        sudo nano /home/jitsi/docker-jitsi-meet/.env
        ;;
    *)
        echo "Использование: jitsi-manage {start|stop|restart|logs|update|status|backup|config}"
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
Server IP: ${DOCKER_HOST_ADDRESS}

Configuration:
- Public URL: https://${DOMAIN}
- Let's Encrypt Email: ${EMAIL}
- XMPP Domain: ${DOMAIN}

Passwords:
- JICOFO_COMPONENT_SECRET: ${JICOFO_COMPONENT_SECRET}
- JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}
- JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}
- JIGASI_XMPP_PASSWORD: ${JIGASI_XMPP_PASSWORD}
- JIBRI_RECORDER_PASSWORD: ${JIBRI_RECORDER_PASSWORD}
- JIBRI_XMPP_PASSWORD: ${JIBRI_XMPP_PASSWORD}
EOF

if [[ $ENABLE_JWT =~ ^[Yy]$ ]]; then
    echo "- JWT_SECRET: ${JWT_SECRET}" >> /home/jitsi/jitsi-credentials.txt
    echo "- JWT_APP_ID: jitsi" >> /home/jitsi/jitsi-credentials.txt
fi

cat >> /home/jitsi/jitsi-credentials.txt << EOF

DNS Configuration:
Add A record: ${DOMAIN} -> ${DOCKER_HOST_ADDRESS}

Management Commands:
- Start/Stop: jitsi-manage start|stop|restart
- Logs: jitsi-manage logs
- Update: jitsi-manage update
- Status: jitsi-manage status
- Backup: jitsi-manage backup
- Edit config: jitsi-manage config

Troubleshooting:
1. Check DNS: nslookup ${DOMAIN}
2. Check SSL: curl -I https://${DOMAIN}
3. Check logs: cd /home/jitsi/docker-jitsi-meet && docker compose logs
EOF

sudo chown jitsi:jitsi /home/jitsi/jitsi-credentials.txt
sudo chmod 600 /home/jitsi/jitsi-credentials.txt

log "Данные сохранены в /home/jitsi/jitsi-credentials.txt"
log "Для доступа к файлу: sudo cat /home/jitsi/jitsi-credentials.txt"

# Final check
echo ""
log "Выполняем финальную проверку..."
sleep 10
log "Проверка контейнеров:"
sudo -u jitsi docker compose -f /home/jitsi/docker-jitsi-meet/docker-compose.yml ps

log "Проверка портов:"
ss -tulpn | grep -E ':80|:443|:10000'

echo ""
log "Установка завершена!"
log "Не забудьте настроить DNS запись для ${DOMAIN}"
log "После настройки DNS проверьте: https://${DOMAIN}"