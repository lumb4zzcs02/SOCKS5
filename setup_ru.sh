#!/bin/bash

# --- Настройки и переменные ---
DANTE_INSTANCES_CONF_DIR="/etc/dante/instances" # Директория для хранения конфигов отдельных прокси
DANTE_INSTANCES_LOG_DIR="/var/log/dante_instances" # Директория для логов отдельных прокси
PROXY_DETAILS_FILE="/root/dante_proxies_details.txt" # Файл для сохранения деталей прокси
DEFAULT_USER_PREFIX="danteuser"
DEFAULT_PASSWORD_LENGTH=16
HTTP_PORT_START=10000
SOCKS_PORT_START=20000

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Функции ---

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от пользователя root."
    fi
}

check_os() {
    if ! grep -q "Debian GNU/Linux 11" /etc/os-release; then
        log_warn "ОС не Debian 11. Скрипт разработан для Debian 11 и может работать некорректно на других системах."
        read -p "Продолжить на свой страх и риск? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[yY]$ ]]; then
            log_error "Выход по запросу пользователя."
        fi
    fi
}

update_system() {
    log_info "Обновление системы..."
    apt update -qq && apt upgrade -y > /dev/null || log_error "Ошибка при обновлении системы."
    apt autoremove -y > /dev/null
    log_info "Система обновлена."
}

install_dante_ufw() {
    log_info "Установка dante-server, ufw, iproute2, net-tools, openssl..."
    apt install -y dante-server ufw iproute2 net-tools openssl > /dev/null || log_error "Ошибка при установке dante-server, ufw или других зависимостей."
    log_info "dante-server, ufw и другие зависимости установлены."
}

configure_ufw_base() {
    log_info "Настройка UFW..."
    ufw --force reset > /dev/null
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null
    ufw allow 22/tcp comment "Allow SSH" > /dev/null
    ufw enable <<< "y" > /dev/null || log_error "Ошибка при включении UFW."
    log_info "UFW настроен и включен (разрешен SSH)."
}

get_network_info() {
    log_info "Сбор сетевой информации..."

    # Получаем основной интерфейс по умолчанию для IPv4
    PRIMARY_INTERFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
    if [ -z "$PRIMARY_INTERFACE" ]; then
        log_error "Не удалось определить основной сетевой интерфейс для IPv4."
    fi
        log_info "Основной сетевой интерфейс: $PRIMARY_INTERFACE"

    # Получаем IPv4 адрес VDS
    VDS_IPV4=$(ip a show dev "$PRIMARY_INTERFACE" | grep 'inet ' | grep 'global' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
    if [ -z "$VDS_IPV4" ]; then
        log_error "Не удалось получить публичный IPv4 адрес VDS с интерфейса $PRIMARY_INTERFACE."
    fi
    log_info "IPv4 адрес VDS: $VDS_IPV4"

    # Получаем все IPv6 /64 подсети на интерфейсе
    ALL_IPV6_ADDRS_64=($(ip -6 addr show dev "$PRIMARY_INTERFACE" | grep inet6 | grep '/64' | awk '{print $2}'))
    if [ ${#ALL_IPV6_ADDRS_64[@]} -eq 0 ]; then
        log_error "Не найдено ни одной IPv6 /64 подсети на интерфейсе $PRIMARY_INTERFACE. Убедитесь, что ваш провайдер назначил ее."
    fi

    # Выбираем случайную IPv6 /64 подсеть
    SELECTED_IPV6_CIDR=${ALL_IPV6_ADDRS_64[$((RANDOM % ${#ALL_IPV6_ADDRS_64[@]}))]}
    
    # Извлекаем префикс /64 из выбранного CIDR
    IPV6_PREFIX_PART=$(echo "$SELECTED_IPV6_CIDR" | cut -d'/' -f1 | awk -F: '{print $1":"$2":"$3":"$4}')
    log_info "Выбрана IPv6 /64 подсеть (префикс): ${IPV6_PREFIX_PART}::/64"
}

generate_ipv6_addr() {
    local prefix_part="$1" # e.g., 2001:db8:abcd:0001
    
    # Генерируем четыре 16-битных случайных сегмента для хостовой части
    RAND_HEX1=$(openssl rand -hex 2)
    RAND_HEX2=$(openssl rand -hex 2)
    RAND_HEX3=$(openssl rand -hex 2)
    RAND_HEX4=$(openssl rand -hex 2)

    # Собираем полный IPv6 адрес
    echo "${prefix_part}:${RAND_HEX1}:${RAND_HEX2}:${RAND_HEX3}:${RAND_HEX4}"
}

generate_random_string() {
    head /dev/urandom | tr -dc A-Za-z0-9_ | head -c "$1"
}

# --- Основная логика скрипта ---

check_root
check_os
update_system
install_dante_ufw
configure_ufw_base
get_network_info

# --- Спрашиваем у пользователя количество прокси ---
num_proxies=0
while true; do
    read -p "Сколько пар прокси (HTTP и SOCKS5) вы хотите создать? (Введите число > 0): " input_num
    if [[ "$input_num" =~ ^[1-9][0-9]*$ ]]; then
        num_proxies=$input_num
        break
    else
        log_warn "Некорректный ввод. Пожалуйста, введите число больше 0."
    fi
done

# --- Подготовка директорий ---
log_info "Подготовка директорий для конфигураций и логов Dante..."
mkdir -p "$DANTE_INSTANCES_CONF_DIR" || log_error "Не удалось создать директорию $DANTE_INSTANCES_CONF_DIR."
mkdir -p "$DANTE_INSTANCES_LOG_DIR" || log_error "Не удалось создать директорию $DANTE_INSTANCES_LOG_DIR."
chmod 700 "$DANTE_INSTANCES_CONF_DIR"
chmod 700 "$DANTE_INSTANCES_LOG_DIR"

echo "=============================================================" > "$PROXY_DETAILS_FILE"
echo "Детали созданных HTTP и SOCKS5 прокси:" >> "$PROXY_DETAILS_FILE"
echo "=============================================================" >> "$PROXY_DETAILS_FILE"
chmod 600 "$PROXY_DETAILS_FILE" # Защищаем файл с данными

# --- Цикл создания прокси ---
log_info "Начинается создание ${num_proxies} пар прокси..."
for i in $(seq 1 $num_proxies); do
    log_info "Настройка прокси #$i из $num_proxies..."

    local_username="${DEFAULT_USER_PREFIX}$(generate_random_string 6)"
    local_password=$(generate_random_string $DEFAULT_PASSWORD_LENGTH)
    local_http_port=$((HTTP_PORT_START + i - 1))
    local_socks_port=$((SOCKS_PORT_START + i - 1))
    generated_ipv6=$(generate_ipv6_addr "$IPV6_PREFIX_PART")

    log_info "  Данные для прокси #$i:"
    log_info "    Логин: $local_username"
    log_info "    Пароль: $local_password"
    log_info "    HTTP Порт: $local_http_port"
    log_info "    SOCKS5 Порт: $local_socks_port"
    log_info "    Исходящий IPv6: $generated_ipv6"

    # Создаём системного пользователя для аутентификации
    useradd -r -s /bin/false "$local_username" || log_error "Ошибка при создании пользователя $local_username."
    echo "$local_username:$local_password" | chpasswd || log_error "Ошибка при установке пароля для пользователя $local_username."

    # Добавляем сгенерированный IPv6 адрес на интерфейс
    ip -6 addr add "${generated_ipv6}/64" dev "$PRIMARY_INTERFACE" || log_error "Ошибка при добавлении IPv6 $generated_ipv6 на $PRIMARY_INTERFACE."
    log_info "  IPv6 ${generated_ipv6}/64 добавлен на $PRIMARY_INTERFACE."

    # Создаём конфигурационный файл для dante-server инстанса
    DANTE_INSTANCE_CONF="$DANTE_INSTANCES_CONF_DIR/danted-proxy-${i}.conf"
    DANTE_INSTANCE_LOG="$DANTE_INSTANCES_LOG_DIR/danted-proxy-${i}.log"
    DANTE_INSTANCE_PID_FILE="/run/danted-proxy-${i}.pid" # PID-файл для каждого инстанса

    cat > "$DANTE_INSTANCE_CONF" <<EOL
logoutput: stderr $DANTE_INSTANCE_LOG
internal: ${VDS_IPV4} port = ${local_http_port}
internal: ${VDS_IPV4} port = ${local_socks_port}
external: ${PRIMARY_INTERFACE}
socksmethod: username
clientmethod: username
user.privileged: root
user.notprivileged: nobody

# HTTP Proxy block
client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error connect disconnect
        proxy-address: ${generated_ipv6}
}

# SOCKS5 Proxy block
socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error connect disconnect
        method: username
        protocol: tcp udp
        proxy-address: ${generated_ipv6}
}
EOL
    chmod 640 "$DANTE_INSTANCE_CONF"
    chown root:root "$DANTE_INSTANCE_CONF"
    log_info "  Конфигурационный файл ${DANTE_INSTANCE_CONF} создан."

    # Создаём systemd unit файл для автозагрузки каждого прокси
    SYSTEMD_SERVICE_FILE="/etc/systemd/system/danted-proxy-${i}.service"
    cat > "$SYSTEMD_SERVICE_FILE" <<EOL
[Unit]
Description=Dante Proxy Service Instance ${i} (HTTP:${local_http_port}, SOCKS5:${local_socks_port})
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/danted -f ${DANTE_INSTANCE_CONF} -p ${DANTE_INSTANCE_PID_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=${DANTE_INSTANCE_PID_FILE}
LimitNOFILE=32768
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
    chmod 644 "$SYSTEMD_SERVICE_FILE"
    log_info "  Systemd юнит ${SYSTEMD_SERVICE_FILE} создан."

    # Открываем порты в брандмауэре
    log_info "  Открываем порты ${local_http_port}/tcp (HTTP) и ${local_socks_port}/tcp (SOCKS5) в UFW..."
    ufw allow "${local_http_port}/tcp" comment "Dante HTTP Proxy ${i}" > /dev/null
    ufw allow "${local_socks_port}/tcp" comment "Dante SOCKS5 Proxy ${i}" > /dev/null
    ufw reload > /dev/null

    # Перезагружаем systemd, включаем и запускаем новый сервис
    log_info "  Перезагружаем systemd и запускаем danted-proxy-${i}..."
    systemctl daemon-reload
    systemctl enable danted-proxy-"${i}" > /dev/null
    systemctl start danted-proxy-"${i}"

    if systemctl is-active --quiet danted-proxy-"${i}"; then
        log_info "  Прокси #$i (danted-proxy-${i}) успешно запущен."
    else
        log_error "  Ошибка: Прокси #$i (danted-proxy-${i}) не удалось запустить. Проверьте логи: journalctl -u danted-proxy-${i} --no-pager"
    fi

    # Выводим информацию и сохраняем в файл
    echo "=============================================================" >> "$PROXY_DETAILS_FILE"
    echo "Прокси #$i:" >> "$PROXY_DETAILS_FILE"
    echo "  Входящий IP (IPv4): $VDS_IPV4" >> "$PROXY_DETAILS_FILE"
    echo "  Исходящий IP (IPv6): $generated_ipv6" >> "$PROXY_DETAILS_FILE"
    echo "  -----------------------------------------------------------" >>
    "$PROXY_DETAILS_FILE"
    echo "  HTTP Прокси:" >> "$PROXY_DETAILS_FILE"
    echo "    Порт: $local_http_port" >> "$PROXY_DETAILS_FILE"
    echo "    Логин: $local_username" >> "$PROXY_DETAILS_FILE"
    echo "    Пароль: $local_password" >> "$PROXY_DETAILS_FILE"
    echo "    Строка (для антидетект): http://$local_username:$local_password@$VDS_IPV4:$local_http_port" >> "$PROXY_DETAILS_FILE"
    echo "  -----------------------------------------------------------" >> "$PROXY_DETAILS_FILE"
    echo "  SOCKS5 Прокси:" >> "$PROXY_DETAILS_FILE"
    echo "    Порт: $local_socks_port" >> "$PROXY_DETAILS_FILE"
    echo "    Логин: $local_username" >> "$PROXY_DETAILS_FILE"
    echo "    Пароль: $local_password" >> "$PROXY_DETAILS_FILE"
    echo "    Строка (для антидетект): socks5://$local_username:$local_password@$VDS_IPV4:$local_socks_port" >> "$PROXY_DETAILS_FILE"
    echo "=============================================================" >> "$PROXY_DETAILS_FILE"

done

# --- Финальные сообщения ---
echo -e "\n============================================================="
log_info "Все ${num_proxies} пар прокси успешно настроены и запущены."
log_info "Детали всех прокси сохранены в файле: ${PROXY_DETAILS_FILE}"
log_info "Прокси будут автоматически запускаться при старте сервера."
log_info "Не забудьте прочитать раздел 'Важно:' в гайде для сохранения IPv6 после перезагрузки."
echo "============================================================="

log_info "Для проверки используйте команды curl, как описано в гайде, используя данные из ${PROXY_DETAILS_FILE}."
log_info "Пример проверки HTTP-прокси:"
log_info "curl -x http://ЛОГИН:ПАРОЛЬ@ВАШ_IPV4:HTTP_ПОРТ ifconfig.co"
log_info "Пример проверки SOCKS5-прокси:"
log_info "curl -x socks5h://ЛОГИН:ПАРОЛЬ@ВАШ_IPV4:SOCKS5_ПОРТ ifconfig.co"
