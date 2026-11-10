#!/bin/bash

# Constants and Configuration
readonly SCRIPT_VERSION="2026.25"
readonly LOG_FILE="singbox.log"
readonly URL_FILE="singbox.url"
readonly DEFAULT_DOMAIN="www.bing.com"
readonly OFFICIAL_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
readonly SINGBOX_SERVICE_NAME="sing-box.service"
readonly SINGBOX_CONFIG_DIR="/etc/sing-box"

current_hostname=$(hostname)

# Color definitions
if [[ -t 1 ]]; then
    readonly red='\e[91m'
    readonly green='\e[92m'
    readonly yellow='\e[93m'
    readonly magenta='\e[95m'
    readonly cyan='\e[96m'
    readonly none='\e[0m'
else
    readonly red=''
    readonly green=''
    readonly yellow=''
    readonly magenta=''
    readonly cyan=''
    readonly none=''
fi

init_output_files() {
    : > "$LOG_FILE"
    : > "$URL_FILE"
}

error() {
    echo -e "\n${red}$1${none}\n" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${yellow}$1${none}" | tee -a "$LOG_FILE"
}

task_start() {
    echo -n -e "${yellow}$1 ... ${none}" | tee -a "$LOG_FILE"
}

task_done() {
    echo -e "[${green}OK${none}]" | tee -a "$LOG_FILE"
}

task_done_with_info() {
    echo -e "${cyan}$1${none} [${green}OK${none}]" | tee -a "$LOG_FILE"
}

task_fail() {
    echo -e "[${red}FAILED${none}]" | tee -a "$LOG_FILE"
}

separator() {
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${none}"
}

resolve_arch_name() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64|x64) echo "amd64" ;;
        aarch64|arm64)    echo "arm64" ;;
        *) echo "amd64" ;;
    esac
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请以 root 身份运行此脚本: sudo -i"
        exit 1
    fi
}

detect_network_interfaces() {
    Public_IPv4=$(curl -4s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    Public_IPv6=$(curl -6s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    if [[ -z "$Public_IPv6" ]]; then
        Public_IPv6=$(curl -6s -m 2 https://ip.sb)
    fi
    [[ -n "$Public_IPv4" ]] && IPv4="$Public_IPv4"
    [[ -n "$Public_IPv6" ]] && IPv6="$Public_IPv6"
    
    if [[ -n "$IPv4" ]]; then
        netstack=4
        ip=${IPv4}
    elif [[ -n "$IPv6" ]]; then
        netstack=6
        ip=${IPv6}
    else
        error "无法检测到公网 IP"
        exit 1
    fi
}

install_dependencies() {
    task_start "工具链检查 / Tool check"
    local tools=("curl" "ss" "openssl" "tar")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            if command -v apt > /dev/null 2>&1; then
                apt update && apt install -y curl iproute2 openssl tar >> "$LOG_FILE" 2>&1
            elif command -v yum > /dev/null 2>&1; then
                yum install -y curl iproute openssl tar >> "$LOG_FILE" 2>&1
            elif command -v apk > /dev/null 2>&1; then
                apk add --no-cache curl iproute2 openssl tar >> "$LOG_FILE" 2>&1
            fi
        fi
    done
    
    # 最终确保 openssl 存在
    if ! command -v openssl > /dev/null 2>&1; then
        task_fail
        error "系统缺少 openssl，无法生成证书。请手动安装后重试。"
        exit 1
    fi
    
    task_done
}

initialize_variables() {
    task_start "随机选择可用端口 / Select a Random Available Port"
    port=""
    for attempt in $(seq 1 200); do
        candidate=$((10000 + RANDOM % 50000))
        if ! ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${candidate}$"; then
            port="$candidate"
            break
        fi
    done
    [[ -z "$port" ]] && port=$((10000 + RANDOM % 40000))
    task_done_with_info "$port"
    
    domain="$DEFAULT_DOMAIN"
}

install_singbox_binary() {
    task_start "开始，安装 SING-BOX / Install SING-BOX"
    local arch
    arch="$(resolve_arch_name)"
    
    mkdir -p /usr/local/bin "$SINGBOX_CONFIG_DIR"
    
    local release_json tag version download_url tmp_dir
    release_json="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$OFFICIAL_API")" || {
        task_fail; error "获取 sing-box 版本失败"; exit 1;
    }
    tag="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    version="${tag#v}"
    if [[ -z "$version" ]]; then
        task_fail; error "解析 sing-box 版本号失败"; exit 1;
    fi
    
    download_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-linux-${arch}.tar.gz"
    tmp_dir="$(mktemp -d)"
    
    if ! curl -fSL --retry 3 "$download_url" -o "$tmp_dir/sing-box.tar.gz" >> "$LOG_FILE" 2>&1; then
        task_fail; error "sing-box 安装包下载失败"; exit 1;
    fi
    
    tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir" >> "$LOG_FILE" 2>&1
    local binary_path
    binary_path="$(find "$tmp_dir" -type f -name sing-box -perm /111 -print -quit)"
    if [[ -z "$binary_path" ]]; then
        task_fail; error "未找到 sing-box 可执行文件"; exit 1;
    fi
    
    install -m 755 "$binary_path" /usr/local/bin/sing-box
    rm -rf "$tmp_dir"
    task_done
}

configure_singbox() {
    task_start "快好了，手搓 / Configuring ${SINGBOX_CONFIG_DIR}/config.json"
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    password=$(openssl rand -base64 16)
    
    cert_path="${SINGBOX_CONFIG_DIR}/cert.pem"
    key_path="${SINGBOX_CONFIG_DIR}/private.key"
    
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_path" -out "$cert_path" -days 36500 -nodes \
        -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >> "$LOG_FILE" 2>&1

    cat > "${SINGBOX_CONFIG_DIR}/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [
        {
          "name": "nokey",
          "uuid": "${uuid}",
          "password": "${password}"
        }
      ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${cert_path}",
        "key_path": "${key_path}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    if ! /usr/local/bin/sing-box check -c "${SINGBOX_CONFIG_DIR}/config.json" >> "$LOG_FILE" 2>&1; then
        task_fail; error "配置文件校验失败"; exit 1;
    fi

    # Systemd service
    cat > /etc/systemd/system/${SINGBOX_SERVICE_NAME} <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c ${SINGBOX_CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable ${SINGBOX_SERVICE_NAME} >> "$LOG_FILE" 2>&1
    task_done
}

open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/udp" >> "$LOG_FILE" 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port="${port}/udp" --permanent >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
    fi
}

start_service() {
    task_start "冲刺，开启服务 / Starting Service"
    systemctl restart ${SINGBOX_SERVICE_NAME} >> "$LOG_FILE" 2>&1
    task_done
}

enable_bbr() {
    task_start "最后，打开 BBR / Finishing, Enabling BBR"
    touch /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p >> "$LOG_FILE" 2>&1 || true
    task_done
}

check_service_status() {
    task_start "检查服务状态 / Checking Service"
    if systemctl is-active --quiet ${SINGBOX_SERVICE_NAME}; then
        task_done
    else
        task_fail
        error "sing-box 服务启动失败，请检查日志 singbox.log"
        exit 1
    fi
}

urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c" ;;
        esac
        encoded="${encoded}${o}"
    done
    echo "${encoded}"
}

output_results() {
    echo -e "${green}舒服了 / Done:${none}\n" | tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    
    local encoded_password
    encoded_password=$(urlencode "$password")
    
    local link_ip="$ip"
    [[ $netstack == "6" ]] && link_ip="[$ip]"
    local tuic_url="tuic://${uuid}:${encoded_password}@${link_ip}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${domain}&allow_insecure=1#${current_hostname}"
    
    echo -e "  ${green}✓${none} Sing-box TUIC (v2rayN / Shadowrocket)" | tee -a "$LOG_FILE"
    echo -e "${magenta}${tuic_url}${none}" | tee -a "$LOG_FILE"
    echo "$tuic_url" >> "$URL_FILE"
    
    if [[ $netstack == "4" && -n "${IPv6:-}" ]]; then
        local ipv6_link="tuic://${uuid}:${encoded_password}@[${IPv6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${domain}&allow_insecure=1#${current_hostname}-ipv6"
        echo "" | tee -a "$LOG_FILE"
        echo -e "  ${green}✓${none} Sing-box TUIC (IPv6)" | tee -a "$LOG_FILE"
        echo -e "${magenta}${ipv6_link}${none}" | tee -a "$LOG_FILE"
        echo "$ipv6_link" >> "$URL_FILE"
    fi
    
    separator | tee -a "$LOG_FILE"
}

main() {
    SECONDS=0
    check_root
    init_output_files
    install_dependencies
    detect_network_interfaces
    initialize_variables
    install_singbox_binary
    configure_singbox
    open_firewall
    start_service
    enable_bbr
    check_service_status
    output_results
    
    info "总用时 / Elapsed Time:  ${green}$SECONDS 秒${none}"
    echo -e "---------- ${cyan}live free or die hard${none} -------------" | tee -a "$LOG_FILE"
}

main "$@"
