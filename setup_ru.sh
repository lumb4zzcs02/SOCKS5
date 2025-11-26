#!/bin/bash

# --- Конфигурационные параметры (НЕ МЕНЯЙТЕ ВРУЧНУЮ В СКРИПТЕ!) ---
# Вместо этого, эти параметры будут использоваться из окружения,
# или будут автоматически получены, если не заданы.
# IPv4 адрес для входящих подключений
IPV4_LISTEN="80.87.108.107"
# Префикс IPv6 подсети для исходящих подключений (первые 64 бита)
IPV6_SUBNET_PREFIX="2a01:5560:1001:df4f"
# Сетевой интерфейс для работы
INTERFACE="eth0"
# --- Конец конфигурационных параметров ---

# Функция для вывода ошибок и завершения работы скрипта
function die() {
    echo -e "\033[31m[ОШИБКА]\033[0m $1" >&2
    exit 1
}

echo -e "\033[32m[ИНФО]\033[0m Начинаем настройку SOCKS5 прокси."

# 1. Проверка предусловий
echo -e "\033[32m[ИНФО]\033[0m Проверка наличия интерфейса и IP-адресов..."

if ! ip link show "$INTERFACE" &>/dev/null; then
    die "Интерфейс '$INTERFACE' не найден. Убедитесь, что он существует."
fi

if ! ip -4 addr show dev "$INTERFACE" | grep -q "$IPV4_LISTEN/32"; then
    die "IPv4 адрес '$IPV4_LISTEN' не настроен на интерфейсе '$INTERFACE'. Пожалуйста, настройте его перед запуском скрипта."
fi

# Проверяем, что подсеть IPv6 (хотя бы ::1) присутствует на интерфейсе
if ! ip -6 addr show dev "$INTERFACE" | grep -q "${IPV6_SUBNET_PREFIX}::1/64"; then
    echo -e "\033[33m[ПРЕДУПРЕЖДЕНИЕ]\033[0m IPv6 подсеть '${IPV6_SUBNET_PREFIX}::1/64' не найдена на интерфейсе '$INTERFACE'. Убедитесь, что она корректно настроена и маршрутизируется провайдером. Иначе исходящий IPv6 работать не будет."
fi

echo -e "\033[32m[ИНФО]\033[0m Предварительные проверки успешно пройдены."

# 2. Устанавливаем необходимые пакеты
echo -e "\033[32m[ИНФО]\033[0m Обновляем список пакетов и устанавливаем dante-server, qrencode..."
apt update -y && apt install -y dante-server qrencode || die "Не удалось установить необходимые пакеты."

# 3. Функция для генерации случайного порта
function generate_random_port() {
    while :; do
        port=$((RANDOM % 64512 + 1024))
        if ! ss -tulnp | awk '{print $4}' | grep -q ":$port"; then
            echo $port
            return
        fi
    done
}

# 4. Получение логина, пароля и порта
read -p "Хотите ввести логин и пароль вручную? (y/n): " choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    read -p "Введите имя пользователя: " username
    read -s -p "Введите пароль: " password
    echo
else
    username=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 8)
    password=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)
        echo -e "\033[32m[ИНФО]\033[0m Сгенерированы логин и пароль:"
    echo "Логин: $username"
    echo "Пароль: $password"
fi

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
    echo -e "\033[32m[ИНФО]\033[0m Сгенерирован случайный порт: $port"
fi

# 5. Создаём системного пользователя для аутентификации
echo -e "\033[32m[ИНФО]\033[0m Создаем системного пользователя '$username' для Dante..."
useradd -r -s /bin/false "$username" || die "Не удалось создать системного пользователя."
echo -e "$password\n$password" | passwd "$username" || die "Не удалось установить пароль для пользователя."

# 6. Генерируем уникальный IPv6 адрес и добавляем его на интерфейс
echo -e "\033[32m[ИНФО]\033[0m Генерируем уникальный IPv6 адрес для исходящих подключений..."
GENERATED_IPV6=""
for i in {1..10}; do # Попытаемся несколько раз, если вдруг будет коллизия
    RAND_HEX=$(openssl rand -hex 8 | sed 's/\(....\)/\1:/g;s/:$//') # Генерируем 64 случайных бита и форматируем их
    TEMP_IPV6="${IPV6_SUBNET_PREFIX}::${RAND_HEX}"
    if ! ip -6 addr show dev "$INTERFACE" | grep -q "$TEMP_IPV6"; then
        GENERATED_IPV6="$TEMP_IPV6"
        break
    fi
    sleep 0.1
done

if [ -z "$GENERATED_IPV6" ]; then
    die "Не удалось сгенерировать уникальный IPv6 адрес после нескольких попыток."
fi

echo -e "\033[32m[ИНФО]\033[0m Сгенерирован IPv6: $GENERATED_IPV6"
ip -6 addr add "${GENERATED_IPV6}/64" dev "$INTERFACE" || die "Не удалось добавить сгенерированный IPv6 адрес на интерфейс $INTERFACE. Возможно, подсеть уже полностью заполнена или есть проблемы с routing."
echo -e "\033[32m[ИНФО]\033[0m IPv6 адрес '$GENERATED_IPV6' успешно добавлен на интерфейс '$INTERFACE'."


# 7. Создаём конфигурацию для dante-server
echo -e "\033[32m[ИНФО]\033[0m Создаем конфигурационный файл Dante (/etc/danted.conf)..."
cat > /etc/danted.conf <<EOL
logoutput: /var/log/danted.log
internal: ${IPV4_LISTEN} port = $port
external: ${GENERATED_IPV6}
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
echo -e "\033[32m[ИНФО]\033[0m Конфигурационный файл Dante успешно создан."

# 8. Открываем порт в брандмауэре UFW
echo -e "\033[32m[ИНФО]\033[0m Настраиваем UFW..."
ufw --force enable || echo -e "\033[33m[ПРЕДУПРЕЖДЕНИЕ]\033[0m UFW уже включен или возникла проблема при его включении. Продолжаем."
ufw allow from any to "$IPV4_LISTEN" port "$port" proto tcp comment "Dante SOCKS5 Proxy" || die "Не удалось добавить правило UFW для IPv4."
echo -e "\033[32m[ИНФО]\033[0m Порт $port открыт для IPv4 '$IPV4_LISTEN' в UFW."
ufw status verbose | grep -q "inactive" && ufw --force enable # Проверяем, что UFW включен

# 9. Перезапускаем и включаем dante-server в автозагрузку
echo -e "\033[32m[ИНФО]\033[0m Перезапускаем и включаем dante-server..."
systemctl daemon-reload
systemctl restart danted || die "Не удалось перезапустить dante-server. Проверьте /var/log/danted.log и journalctl -xeu danted."
systemctl enable danted || die "Не удалось включить dante-server в автозагрузку."
systemctl is-active --quiet danted || die "Dante SOCKS5 прокси не запущен. Проверьте логи."
echo -e "\033[32m[ИНФО]\033[0m Dante SOCKS5 прокси успешно запущен и включен в автозагрузку."

# 10. Выводим информацию
echo -e "\n============================================================="
echo -e "\033[32mSOCKS5-прокси установлен и настроен!\033[0m"
echo " "
echo -e "\033[1mПараметры подключения к прокси:\033[0m"
echo "  IP-адрес для подключения: $IPV4_LISTEN"
echo "  Порт: $port"
echo "  Логин: $username"
echo "  Пароль: $password"
echo " "
echo -e "\033[1mИсходящий IPv6-адрес (используется для выхода в интернет):\033[0m $GENERATED_IPV6"
echo " "
echo -e "\033[1mГотовые строки для антидетект браузеров и других клиентов:\033[0m"
echo "  $IPV4_LISTEN:$port:$username:$password"
echo "  $username:$password@$IPV4_LISTEN:$port"
echo " "
echo -e "============================================================="

echo -e "\nСпасибо за использование скрипта! Вы можете оставить чаевые по QR-коду ниже:"
qrencode -t ANSIUTF8 "https://pay.cloudtips.ru/p/7410814f"
echo "Ссылка на чаевые: https://pay.cloudtips.ru/p/7410814f"
echo "============================================================="
echo "Рекомендуемые хостинги для VPN и прокси:"
echo "Хостинг #1: https://vk.cc/ct29NQ (промокод off60 для 60% скидки на первый месяц)"
echo "Хостинг #2: https://vk.cc/czDwwy (будет действовать 15% бонус в течение 24 часов!)"
echo "============================================================="

echo -e "\033[32m[ИНФО]\033[0m Скрипт завершил свою работу."
echo -e "\033[33m[ВАЖНО]\033[0m Если сервер перезагрузится, сгенерированный IPv6 адрес '$GENERATED_IPV6' будет утерян, и прокси перестанет работать с этим IPv6. Вам нужно будет запустить скрипт заново или добавить IPv6 в постоянную конфигурацию (например, /etc/netplan или /etc/network/interfaces)."
