#!/bin/bash
set -euo pipefail # Строгий режим: выход при ошибке, неопределенной переменной, сбое пайпа

echo "=== Запуск скрипта установки SOCKS5-прокси с IPv6 исходящим трафиком ==="

# Устанавливаем необходимые пакеты
echo "Обновляем списки пакетов и устанавливаем необходимые зависимости..."
apt update && apt install -y dante-server apache2-utils qrencode curl openssl

# Определяем правильный сетевой интерфейс
INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1)
echo "Автоматически определён сетевой интерфейс: $INTERFACE"

# Определяем публичный IPv4-адрес для этого интерфейса (для входящих подключений)
IPV4_ADDRESS=$(ip a show dev "$INTERFACE" | grep 'inet ' | grep 'global' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

if [ -z "$IPV4_ADDRESS" ]; then
    echo "Ошибка: Не удалось определить публичный IPv4-адрес для интерфейса $INTERFACE."
    echo "Проверьте сетевые настройки или наличие IPv4-адреса на интерфейсе."
    exit 1
fi
echo "Определён публичный IPv4-адрес для входящих подключений: $IPV4_ADDRESS"

# --- Логика для IPv6 адреса для исходящего трафика ---
IPV6_SUBNET_PREFIX="2a01:5560:1001:bc20"
GENERATED_IPV6_ADDRESS=""

echo "Генерируем уникальный IPv6-адрес для исходящего трафика из подсети ${IPV6_SUBNET_PREFIX}::/64..."

# Функция для генерации случайного IPv6 суффикса
function generate_random_ipv6_suffix() {
    # Генерируем 64 бита случайных данных (16 шестнадцатеричных символов)
    local random_hex=$(openssl rand -hex 8)
    # Форматируем в стандартный вид IPv6 (например, ab:cd:ef:gh:ij:kl:mn:op)
    echo "${random_hex}" | sed 's/\(..\)/\1:/g; s/:$//'
}

while [ -z "$GENERATED_IPV6_ADDRESS" ]; do
    RANDOM_IPV6_SUFFIX=$(generate_random_ipv6_suffix)
    TEMP_IPV6_ADDR="${IPV6_SUBNET_PREFIX}:${RANDOM_IPV6_SUFFIX}"

    # Проверяем, что сгенерированный адрес не существует на интерфейсе
    if ! ip -6 addr show dev "$INTERFACE" | grep -q "$TEMP_IPV6_ADDR"; then
        GENERATED_IPV6_ADDRESS="$TEMP_IPV6_ADDR"
    fi
done

echo "Сгенерирован уникальный IPv6-адрес: $GENERATED_IPV6_ADDRESS"

# Добавляем сгенерированный IPv6-адрес на интерфейс eth0
echo "Добавляем IPv6-адрес $GENERATED_IPV6_ADDRESS/64 на интерфейс $INTERFACE..."
sudo ip -6 addr add "$GENERATED_IPV6_ADDRESS/64" dev "$INTERFACE"

# Проверяем, что адрес успешно добавлен
if ! ip -6 addr show dev "$INTERFACE" | grep -q "$GENERATED_IPV6_ADDRESS"; then
    echo "Ошибка: Не удалось добавить IPv6-адрес $GENERATED_IPV6_ADDRESS на интерфейс $INTERFACE."
        echo "Возможно, подсеть уже полностью использована или есть другая проблема с сетью."
    exit 1
fi
echo "IPv6-адрес успешно добавлен на интерфейс $INTERFACE."
echo "Внимание: Этот IPv6-адрес может быть утерян после перезагрузки. Для постоянства настройте его через netplan/systemd-networkd."
# --- Конец логики для IPv6 ---


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
echo "Создаем системного пользователя $username..."
useradd -r -s /bin/false "$username"
(echo "$password"; echo "$password") | passwd "$username"

# Создаём конфигурацию для dante-server
echo "Создаем конфигурацию для dante-server в /etc/danted.conf..."
cat > /etc/danted.conf <<EOL
logoutput: stderr
internal: 0.0.0.0 port = $port # Слушаем на всех IPv4 адресах
external: $GENERATED_IPV6_ADDRESS # Исходящие соединения через сгенерированный IPv6
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

# Открываем порт в брандмауэре (для IPv4, так как internal: 0.0.0.0)
echo "Открываем порт $port/tcp в брандмауэре UFW..."
ufw allow "$port"/tcp

# Перезапускаем и включаем dante-server в автозагрузку
echo "Перезапускаем и включаем dante-server в автозагрузку..."
systemctl restart danted
systemctl enable danted

# Выводим информацию
echo "============================================================="
echo "SOCKS5-прокси установлен."
echo "-------------------------------------------------------------"
echo "Для подключения к прокси (используйте этот IP/Порт/Логин/Пароль):"
echo "IP: $IPV4_ADDRESS"
echo "Порт: $port"
echo "Логин: $username"
echo "Пароль: $password"
echo "-------------------------------------------------------------"
echo "ВАЖНО: Исходящий трафик с этого прокси будет идти через IPv6-адрес:"
echo "$GENERATED_IPV6_ADDRESS"
echo "-------------------------------------------------------------"
echo "Готовая строка для антидетект браузеров:"
echo "$IPV4_ADDRESS:$port:$username:$password"
echo "$username:$password@$IPV4_ADDRESS:$port"
echo "=========================== 
=================================="

echo "Спасибо за использование скрипта! Вы можете оставить чаевые по QR-коду ниже:"
qrencode -t ANSIUTF8 "https://pay.cloudtips.ru/p/7410814f"
echo "Ссылка на чаевые: https://pay.cloudtips.ru/p/7410814f"
echo "============================================================="
echo "Рекомендуемые хостинги для VPN и прокси:"
echo "Хостинг #1: https://vk.cc/ct29NQ (промокод off60 для 60% скидки на первый месяц)"
echo "Хостинг #2: https://vk.cc/czDwwy (будет действовать 15% бонус в течение 24 часов!)"
echo "============================================================="
