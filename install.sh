#!/bin/bash

echo "Обновление списка пакетов и системы..."
apt update && apt upgrade -y

echo "Установка docker"
apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
sudo docker run hello-world

echo "Установка docker-compose"
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version


echo "Очистка кеша пакетов..."
apt autoremove -y
apt clean

echo "Установка завершена!"