#!/bin/bash

# Устанавливаем необходимые пакеты
# Добавляем 'curl' в список установки, так как он используется для получения публичного IP
apt update && apt install -y dante-server apache2-utils qrencode curl -y

# Определяем сетевой интерфейс. Пользователь явно указал 'eth0'.
INTERFACE="eth0"
echo "Определён сетевой интерфейс: $INTERFACE"

# --- Определение IPv4-адреса для входящих подключений ---
TARGET_IPV4="80.87.108.107"
EXTERNAL_IPV4_FOR_CLIENTS=$(ip -4 addr show dev "$INTERFACE" scope global | grep -oP "inet \K$TARGET_IPV4")

if [ -z "$EXTERNAL_IPV4_FOR_CLIENTS" ]; then
    echo "Ошибка: Указанный IPv4-адрес '$TARGET_IPV4' не найден на интерфейсе '$INTERFACE'."
    echo "Пожалуйста, убедитесь, что адрес '$TARGET_IPV4' настроен на '$INTERFACE'."
    exit 1
fi
echo "Выбран внешний IPv4-адрес для подключения к прокси: $EXTERNAL_IPV4_FOR_CLIENTS"

# --- Определение IPv6-адреса для исходящих соединений прокси ---
# Целевой префикс подсети IPv6, если требуется конкретный.
# Пользователь предоставил пример: 2a01:5560:1001:df4f::1/64
TARGET_SUBNET_PREFIX="2a01:5560:1001:df4f"

IPV6_ADDRESSES_ON_IF=$(ip -6 addr show dev "$INTERFACE" scope global | grep -oP 'inet6 \K[^/]+' | grep -v '^fe80:')
EXTERNAL_IPV6_FOR_PROXY=""

if [ -z "$IPV6_ADDRESSES_ON_IF" ]; then
    echo "Ошибка: На интерфейсе $INTERFACE не найдено глобальных IPv6-адресов."
    echo "Для работы IPv6-прокси требуется наличие глобального IPv6-адреса."
    exit 1
fi

# Пытаемся найти IPv6-адрес, соответствующий примеру подсети пользователя
for addr in $IPV6_ADDRESSES_ON_IF; do
    if [[ "$addr" == "$TARGET_SUBNET_PREFIX"* ]]; then
        EXTERNAL_IPV6_FOR_PROXY="$addr"
        break
    fi
done

# Если адрес из конкретной подсети не найден, используем первый доступный глобальный IPv6-адрес
if [ -z "$EXTERNAL_IPV6_FOR_PROXY" ]; then
    echo "Внимание: На интерфейсе $INTERFACE не найден IPv6-адрес, начинающийся с префикса $TARGET_SUBNET_PREFIX."
    echo "Будет использован первый доступный глобальный IPv6-адрес на этом интерфейсе для исходящих соединений прокси."
    EXTERNAL_IPV6_FOR_PROXY=$(echo "$IPV6_ADDRESSES_ON_IF" | head -n 1)
fi
echo "Выбран внешний IPv6-адрес для исходящих соединений прокси: $EXTERNAL_IPV6_FOR_PROXY"


# Функция для генерации случайного порта
function generate_random_port() {
    while :; do
        port=$((RANDOM % 64512 + 1024))
        # Проверяем, не занят ли порт для IPv4 на нашем IP
                if ! ss -tulnp | awk '{print $4}' | grep -q "$EXTERNAL_IPV4_FOR_CLIENTS:$port"; then
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
        read -p "Введите порт (1024-65535, не занятый на $EXTERNAL_IPV4_FOR_CLIENTS): " port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] && 
           ! ss -tulnp | awk '{print $4}' | grep -q "$EXTERNAL_IPV4_FOR_CLIENTS:$port"; then
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
# internal: $EXTERNAL_IPV4_FOR_CLIENTS port = $port - Dante слушает только на указанном IPv4
# external: $EXTERNAL_IPV6_FOR_PROXY - Исходящие соединения Dante будут использовать этот IPv6
# client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 } - Разрешает IPv4-клиентам подключаться к прокси
# socks pass { from: 0.0.0.0/0 to: ::/0 } - Разрешает IPv4-клиентам проксировать трафик на ЛЮБЫЕ IPv6-адреса
cat > /etc/danted.conf <<EOL
logoutput: stderr
internal: $EXTERNAL_IPV4_FOR_CLIENTS port = $port
external: $EXTERNAL_IPV6_FOR_PROXY
socksmethod: username
user.privileged: root
user.notprivileged: nobody

client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error
}

socks pass {
        from: 0.0.0.0/0 to: ::/0
        method: username
        protocol: tcp udp
        log: error
}
EOL

# Открываем порт в брандмауэре для входящих IPv4-соединений
ufw allow proto tcp from any to $EXTERNAL_IPV4_FOR_CLIENTS port $port comment "Dante SOCKS5 IPv4 Client, IPv6 Proxy"

# Перезапускаем и включаем dante-server в автозагрузку
systemctl restart danted
systemctl enable danted

# Выводим информацию
PUBLIC_IPV6=$(curl -s6 https://ipv6.icanhazip.com || echo "Не удалось получить публичный IPv6-адрес (проверьте сетевое подключение).")
echo "============================================================="
echo "SOCKS5-прокси установлен. Подключение (ВХОДЯЩЕЕ IPv4, ВЫХОДЯЩЕЕ IPv6):"
echo "IP для подключения: $EXTERNAL_IPV4_FOR_CLIENTS"
echo "Порт: $port"
echo "Логин: $username"
echo "Пароль: $password"
echo "-------------------------------------------------------------"
echo "SOCKS5-прокси будет использовать для исходящих соединений IPv6: [$PUBLIC_IPV6]"
echo "============================================================="
echo "Готовая строка для антидетект браузеров:"
echo "$EXTERNAL_IPV4_FOR_CLIENTS:$port:$username:$password"
echo "$username:$password@$EXTERNAL_IPV4_FOR_CLIENTS:$port"
echo "============================================================="

echo "Спасибо за использование скрипта! Вы можете оставить чаевые по QR-коду ниже:"
qrencode -t ANSIUTF8 "https://pay.cloudtips.ru/p/7410814f"
echo "Ссылка на чаевые: https://pay.cloudtips.ru/p/7410814f"
echo "============================================================="
echo "Рекомендуемые хостинги для VPN и прокси:"
echo "Хостинг #1: https://vk.cc/ct29NQ (промокод off60 для 60% скидки на первый месяц)"
echo "Хостинг #2: https://vk.cc/czDwwy (будет действовать 15% бонус в течение 24 часов!)"
echo "============================================================="
