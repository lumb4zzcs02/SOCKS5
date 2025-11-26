#!/bin/bash

# --- Настройки и переменные ---
DANTE_CONF_DIR="/etc/dante/proxies" # Директория для хранения конфигов отдельных прокси
DANTE_LOG_DIR="/var/log/dante"      # Директория для логов отдельных прокси
PROXY_DETAILS_FILE="/root/socks5_proxies_details.txt" # Файл для сохранения деталей прокси
DEFAULT_USER_PREFIX="proxyuser"
DEFAULT_PASSWORD_LENGTH=16

# --- Проверка прав суперпользователя ---
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени пользователя root."
   exit 1
fi

# --- Установка необходимых пакетов ---
echo "Обновление списка пакетов и установка dante-server, apache2-utils, qrencode, curl..."
apt update -qq && apt install -y dante-server apache2-utils qrencode curl > /dev/null

# --- Настройка UFW (если не включен) ---
if ! ufw status | grep -q "Status: active"; then
    echo "UFW не активен. Включаем UFW и разрешаем SSH (порт 22)."
    ufw enable <<< "y" # Автоматическое подтверждение
    ufw allow 22/tcp
    ufw reload
fi

# --- Определение сетевого интерфейса и публичного IP-адреса ---
INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n 1)
echo "Автоматически определён сетевой интерфейс: $INTERFACE"

IPV4_ADDRESS=$(ip a show dev "$INTERFACE" | grep 'inet ' | grep 'global' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

if [ -z "$IPV4_ADDRESS" ]; then
    echo "Ошибка: Не удалось определить публичный IPv4-адрес для интерфейса $INTERFACE."
    echo "Проверьте сетевые настройки или наличие IPv4-адреса на интерфейсе."
    exit 1
fi
echo "Определён публичный IPv4-адрес для интерфейса $INTERFACE: $IPV4_ADDRESS"

# --- Функция для генерации случайного порта ---
function generate_random_port() {
    while :; do
        # Диапазон портов: 1024-65535. Избегаем низких системных портов.
        port=$((RANDOM % 64512 + 1024))
        # Проверяем, не занят ли порт
        if ! ss -tulnp | awk '{print $4}' | grep -q ":$port"; then
            echo $port
            return
        fi
    done
}

# --- Спрашиваем у пользователя количество прокси ---
num_proxies=0
while true; do
    read -p "Сколько SOCKS5 прокси вы хотите создать? (Введите число > 0): " input_num
    if [[ "$input_num" =~ ^[1-9][0-9]*$ ]]; then
        num_proxies=$input_num
        break
    else
        echo "Некорректный ввод. Пожалуйста, введите число больше 0."
    fi
done

# --- Подготовка директорий ---
mkdir -p "$DANTE_CONF_DIR"
mkdir -p "$DANTE_LOG_DIR"
chmod 700 "$DANTE_CONF_DIR"
chmod 700 "$DANTE_LOG_DIR"
echo "=============================================================" > "$PROXY_DETAILS_FILE"
echo "Детали созданных SOCKS5 прокси:" >> "$PROXY_DETAILS_FILE"
echo "=============================================================" >> "$PROXY_DETAILS_FILE"
chmod 600 "$PROXY_DETAILS_FILE" # Защищаем файл с данными от случайного чтения

# --- Цикл создания прокси ---
for i in $(seq 1 $num_proxies); do
    echo -e "\nНастройка прокси #$i из $num_proxies..."

    local_username=""
    local_password=""
    local_port=""

    # Если создаём только один прокси, предлагаем ручной ввод
    if [ "$num_proxies" -eq 1 ]; then
        read -p "Хотите ввести логин и пароль вручную для этого прокси? (y/n): " choice_creds
        if [[ "$choice_creds" == "y" || "$choice_creds" == "Y" ]]; then
            read -p "Введите имя пользователя: " local_username
            read -s -p "Введите пароль: " local_password
            echo
        fi

        read -p "Хотите ввести порт вручную для этого прокси? (y/n): " choice_port
        if [[ "$choice_port" == "y" || "$choice_port" == "Y" ]]; then
            while :; do
                read -p "Введите порт (1024-65535, не занятый системой): " input_port
                if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1024 ] && [ "$input_port" -le 65535 ] && ! ss -tulnp | awk '{print $4}' | grep -q ":$input_port"; then
                    local_port="$input_port"
                    break
                else
                    echo "Этот порт недоступен или некорректный. Попробуйте снова."
                fi
            done
        fi
    fi

    # Если не введены вручную, генерируем
    if [ -z "$local_username" ]; then
        local_username="${DEFAULT_USER_PREFIX}$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    fi
    if [ -z "$local_password" ]; then
        local_password=$(tr -dc 'a-zA-Z0-9!@#$%^&*()_+' </dev/urandom | head -c $DEFAULT_PASSWORD_LENGTH)
    fi
    if [ -z "$local_port" ]; then
        local_port=$(generate_random_port)
    fi

    echo "  Данные для прокси #$i:"
    echo "    Логин: $local_username"
    echo "    Пароль: $local_password"
    echo "    Порт: $local_port"

    # Создаём системного пользователя для аутентификации
    # `-r` создает системного пользователя, `-s /bin/false` запрещает ему логиниться
    useradd -r -s /bin/false "$local_username"
    echo "$local_username:$local_password" | chpasswd

    # Создаём конфигурационный файл для dante-server инстанса
    DANTE_INSTANCE_CONF="$DANTE_CONF_DIR/danted-proxy-$i.conf"
    DANTE_INSTANCE_LOG="$DANTE_LOG_DIR/danted-proxy-$i.log"
    DANTE_INSTANCE_PID="/run/danted-proxy-$i.pid" # PID-файл для каждого инстанса

    cat > "$DANTE_INSTANCE_CONF" <<EOL
logoutput: stderr $DANTE_INSTANCE_LOG
internal: 0.0.0.0 port = $local_port
external: $IPV4_ADDRESS
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
    chmod 640 "$DANTE_INSTANCE_CONF"
    chown root:root "$DANTE_INSTANCE_CONF"

    # Создаём systemd unit файл для автозагрузки каждого прокси
    SYSTEMD_SERVICE_FILE="/etc/systemd/system/danted-proxy-$i.service"
    cat > "$SYSTEMD_SERVICE_FILE" <<EOL
[Unit]
Description=SOCKS (dante) proxy service instance #$i
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/danted -f $DANTE_INSTANCE_CONF -p $DANTE_INSTANCE_PID
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=$DANTE_INSTANCE_PID
LimitNOFILE=32768
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
    chmod 644 "$SYSTEMD_SERVICE_FILE"

    # Открываем порт в брандмауэре
    echo "  Открываем порт $local_port/tcp в UFW..."
    ufw allow "$local_port"/tcp > /dev/null

    # Перезагружаем systemd, включаем и запускаем новый сервис
    echo "  Перезагружаем systemd и запускаем danted-proxy-$i..."
    systemctl daemon-reload
    systemctl enable danted-proxy-"$i" > /dev/null
    systemctl start danted-proxy-"$i"

    if systemctl is-active --quiet danted-proxy-"$i"; then
        echo "  Прокси #$i (danted-proxy-$i) успешно запущен."
    else
        echo "  Ошибка: Прокси #$i (danted-proxy-$i) не удалось запустить. Проверьте логи: journalctl -u danted-proxy-$i"
    fi

    # Выводим информацию и сохраняем в файл
    echo "============================================================="
    echo "SOCKS5-прокси #$i установлен и запущен."
    echo "IP: $IPV4_ADDRESS"
    echo "Порт: $local_port"
    echo "Логин: $local_username"
    echo "Пароль: $local_password"
    echo "============================================================="
    echo "Готовая строка для антидетект браузеров:"
    echo "$IPV4_ADDRESS:$local_port:$local_username:$local_password"
    echo "$local_username:$local_password@$IPV4_ADDRESS:$local_port"
    echo "============================================================="

    echo "Прокси #$i:" >> "$PROXY_DETAILS_FILE"
    echo "IP: $IPV4_ADDRESS" >> "$PROXY_DETAILS_FILE"
    echo "Порт: $local_port" >> "$PROXY_DETAILS_FILE"
    echo "Логин: $local_username" >> "$PROXY_DETAILS_FILE"
    echo "Пароль: $local_password" >> "$PROXY_DETAILS_FILE"
    echo "Строка (для антидетект): $username:$password@$IPV4_ADDRESS:$port" >> "$PROXY_DETAILS_FILE"
    echo "Сервис Systemd: danted-proxy-$i" >> "$PROXY_DETAILS_FILE"
    echo "-------------------------------------------------------------" >> "$PROXY_DETAILS_FILE"
done

# --- Финальные сообщения ---
echo -e "\n============================================================="
echo "Все $num_proxies SOCKS5-прокси успешно настроены и запущены."
echo "Детали всех прокси сохранены в файле: $PROXY_DETAILS_FILE"
echo "Прокси будут автоматически запускаться при старте сервера."
echo "============================================================="

echo "Спасибо за использование скрипта! Вы можете оставить чаевые по QR-коду ниже:"
qrencode -t ANSIUTF8 "https://pay.cloudtips.ru/p/7410814f"
echo "Ссылка на чаевые: https://pay.cloudtips.ru/p/7410814f"
echo "============================================================="
echo "Рекомендуемые хостинги для VPN и прокси:"
echo "Хостинг #1: https://vk.cc/ct29NQ (промокод off60 для 60% скидки на первый месяц)"
echo "Хостинг #2: https://vk.cc/czDwwy (будет действовать 15% бонус в течение 24 часов!)"
echo "============================================================="
