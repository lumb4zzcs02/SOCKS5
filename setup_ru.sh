#!/bin/bash

# Устанавливаем необходимые пакеты
apt update && apt install -y dante-server apache2-utils qrencode

# Определяем правильный сетевой интерфейс
INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1)

echo "Автоматически определён сетевой интерфейс: $INTERFACE"

# Функция для генерации случайного порта
function generate_random_port() {
    while :; do
        port=$((RANDOM % 64512 + 1024))
        if ! ss -tulnp | awk '{print $4}' | grep -q ":$port"; then
            echo $port
            return
        fi
    done
}

# Спрашиваем у пользователя, хочет ли он ввести логин и пароль сам
read -p "Хотите ввести логин и пароль вручную? (y/n): " choice

if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    read -p "Введите имя пользователя: " username
    read -s -p "Введите пароль: " password
    echo
else
    username=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
    password=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)
    echo "Сгенерированы логин и пароль:"
    echo "Логин: $username"
    echo "Пароль: $password"
fi

# Спрашиваем у пользователя, хочет ли он ввести порт вручную
read -p "Хотите ввести порт вручную? (y/n): " port_choice

if [[ "$port_choice" == "y" || "$port_choice" == "Y" ]]; then
    while :; do
        read -p "Введите порт (1024-65535, не занятый системой): " port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] && ! ss -tulnp | awk '{print $4}' | grep -q ":$port"; then
            break
        else
            echo "Этот порт недоступен или некорректный. Попробуйте снова."
        fi
    done
else
    port=$(generate_random_port)
    echo "Сгенерирован случайный порт: $port"
fi

# Создаём системного пользователя для аутентификации
useradd -r -s /bin/false $username
(echo "$password"; echo "$password") | passwd $username

# Создаём конфигурацию для dante-server
cat > /etc/danted.conf <<EOL
logoutput: stderr
internal: 0.0.0.0 port = $port
external: $INTERFACE
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error
}

socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        method: username
        protocol: tcp udp
        log: error
}
EOL

# Открываем порт в брандмауэре
ufw allow $port/tcp

# Перезапускаем и включаем dante-server в автозагрузку
systemctl restart danted
systemctl enable danted

# Выводим информацию
ip=$(curl -s ifconfig.me)
echo "============================================================="
echo "SOCKS5-прокси установлен. Подключение:"
echo "IP: $ip"
echo "Порт: $port"
echo "Логин: $username"
echo "Пароль: $password"
echo "============================================================="
echo "Готовая строка для антидетект браузеров:"
echo "$ip:$port:$username:$password"
echo "$username:$password@$ip:$port"
echo "============================================================="

echo "Спасибо за использование скрипта! Вы можете оставить чаевые по QR-коду ниже:"
qrencode -t ANSIUTF8 "https://pay.cloudtips.ru/p/7410814f"
echo "Ссылка на чаевые: https://pay.cloudtips.ru/p/7410814f"
echo "============================================================="
echo "Рекомендуемые хостинги для VPN и прокси:"
echo "Хостинг #1: https://vk.cc/ct29NQ (промокод off60 для 60% скидки на первый месяц)"
echo "Хостинг #2: https://vk.cc/czDwwy (будет действовать 15% бонус в течение 24 часов!)"
echo "============================================================="
