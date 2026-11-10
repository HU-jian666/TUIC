#!/bin/bash

# Constants and Configuration

readonly SCRIPT_VERSION="2026.23"
readonly LOG_FILE="nokey.log"
readonly URL_FILE="nokey.url"
readonly DEFAULT_DOMAIN="www.bing.com"
readonly OFFICIAL_REPO="https://github.com/SagerNet/sing-box"
readonly GITHUB_URL="https://github.com/SagerNet/sing-box"
readonly OFFICIAL_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
readonly SINGBOX_SERVICE_NAME="sing-box.service"
readonly SINGBOX_SERVICE_NAME_ALPINE="sing-box"
readonly SINGBOX_CONFIG_DIR="/etc/sing-box"

current_hostname=$(hostname)

# Color definitions (suppressed when stdout is not a TTY)
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

# Helper functions
error() {
    echo -e "\n${red}$1${none}\n" \vert{} tee -a "$LOG_FILE"
}

warn() {
    echo -e "\n${yellow}$1${none}\n" \vert{} tee -a "$LOG_FILE"
}

info() {
    echo -e "${yellow}$1${none}" \vert{} tee -a "$LOG_FILE"
}

task_start() {
    echo -n -e "${yellow}$1 ... ${none}" \vert{} tee -a "$LOG_FILE"
}

task_done() {
    echo -e "[${green}OK${none}]" \vert{} tee -a "$LOG_FILE"
}

task_done_with_info() {
    echo -e "${cyan}$1${none} [${green}OK${none}]" \vert{} tee -a "$LOG_FILE"
}

task_fail() {
    echo -e "[${red}FAILED${none}]" \vert{} tee -a "$LOG_FILE"
}

log_verbose() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_info() {
    echo -e "${yellow}$1${none}" >> "$LOG_FILE"
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
        *) 
            # 兼容其他常见的输出格式
            if echo "$m" | grep -Eqi "arm|aarch"; then
                echo "arm64"
            else
                echo "amd64"
            fi
            ;;
    esac
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请以root身份运行此脚本 / Please run as root: ${red}sudo -i${none}"
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
    echo "Detected interface / 找到网卡: $Public_IPv4 $Public_IPv6" >> "$LOG_FILE"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

generate_password() {
    openssl rand -base64 16
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
            * )
                printf -v o '%%%02x' "'$c"
                ;;
        esac
        encoded="${encoded}${o}"
    done
    echo "${encoded}"
}

install_dependencies() {
    task_start "工具链检查 / Tool check"

    local tools=("curl" "ss" "openssl")

    declare -A os_package_command=(
        [apt]="apt install -y"
        [yum]="yum install -y"
        [dnf]="dnf install -y"
        [pacman]="pacman -Sy --noconfirm"
        [apk]="apk add --no-cache"
        [zypper]="zypper install -y"
        [xbps-install]="xbps-install -Sy"
    )

    local manager=""
    for candidate in "${!os_package_command[@]}"; do
        if command -v "$candidate" > /dev/null 2>&1; then
            manager=$candidate
            break
        fi
    done

    if [[ -z "$manager" ]]; then
        task_fail
        error "无法识别包管理器 / Cannot detect package manager"
        exit 1
    fi

    local install_cmd="${os_package_command[$manager]}"

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            local package_name="$tool"
            [[ "$tool" == "ss" ]] && package_name="iproute2"
            eval "$install_cmd" "$package_name" >> "$LOG_FILE" 2>&1
            if ! command -v "$tool" > /dev/null 2>&1; then
                task_fail
                error "安装$tool失败，请手动安装后重新运行脚本 / Failed to install '$tool'."
                exit 1
            fi
        fi
    done

    task_done
}

initialize_ip_from_netstack() {
    task_start "监测IP / Detect IP"
    if [[ -z "${IPv4:-}" && -z "${IPv6:-}" ]]; then
        detect_network_interfaces
    fi
    if [[ -n "$IPv4" ]]; then
        netstack=4
    elif [[ -n "$IPv6" ]]; then
        netstack=6
    else
        task_fail
        error "没有获取到公共IP / No public IP detected"
        exit 1
    fi

    if [[ "$netstack" == "4" ]]; then
        ip=${IPv4}
    else
        ip=${IPv6}
    fi
    task_done_with_info "$ip"
}

initialize_variables() {
    initialize_ip_from_netstack

    task_start "随机选择可用端口 (10000-59999) / Select a Random Available Port"

    port=""
    for attempt in $(seq 1 200); do
        candidate=$((10000 + RANDOM % 50000))

        if ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${candidate}$"; then
            continue
        fi

        port="$candidate"
        break
    done

    if [[ -z "$port" ]]; then
        task_fail
        error "无法找到随机可用端口 / Could not find a random available port."
        exit 1
    fi
    task_done_with_info "$port"

    domain="$DEFAULT_DOMAIN"
}

generate_crypto() {
    task_start "生成一个UUID / Generate UUID"
    uuid=$(generate_uuid)
    task_done

    task_start "生成一个密码 / Generate Password"
    password=$(generate_password)
    task_done_with_info "${password}"

    task_start "生成自签名证书 / Generate self-signed certificate"
    mkdir -p "$SINGBOX_CONFIG_DIR"
    cert_path="${SINGBOX_CONFIG_DIR}/cert.pem"
    key_path="${SINGBOX_CONFIG_DIR}/private.key"
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_path" -out "$cert_path" -days 36500 -nodes \
        -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >> "$LOG_FILE" 2>&1; then
        task_fail
        error "生成自签名证书失败 / Failed to generate self-signed certificate."
        exit 1
    fi
    task_done
}

build_singbox_config() {
    local config_path="${SINGBOX_CONFIG_DIR}/config.json"
    task_start "正在生成配置文件 / Configuring $config_path"

    if ! cat > "$config_path" <<EOF
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
    then
        task_fail
        error "写入sing-box配置文件失败: $config_path"
        [[ -f "$config_path" ]] && rm -f "$config_path"
        exit 1
    fi

    if ! /usr/local/bin/sing-box check -c "$config_path" >> "$LOG_FILE" 2>&1; then
        task_fail
        error "生成的 sing-box 配置文件语法校验失败，请检查 $LOG_FILE"
        exit 1
    fi

    task_done
    log_info "--- ${config_path} ---"
    cat "$config_path" >> "$LOG_FILE"
}

install_singbox_binary() {
    task_start "从官方源安装 SING-BOX / Install SING-BOX from official source"

    local is_alpine=0
    if [ "${ID:-}" = "alpine" ] \vert{}\vert{} [[ "${ID_LIKE:-}" == *alpine* ]]; then
        is_alpine=1
        rc-service "$SINGBOX_SERVICE_NAME_ALPINE" stop 2>/dev/null || true
    else
        systemctl stop "$SINGBOX_SERVICE_NAME" 2>/dev/null || true
    fi

    local arch_name
    arch_name="$(resolve_arch_name)" \vert{}\vert{} { task_fail; error "不支持的架构: $(uname -m)"; exit 1; }

    mkdir -p /usr/local/bin "$SINGBOX_CONFIG_DIR" || { task_fail; error "创建 sing-box 目录失败"; exit 1; }

    local release_json tag version asset_name download_url tmp_dir
    release_json="$(curl -fsSL --retry 3 --retry-delay 3 -H 'Accept: application/vnd.github+json' "$OFFICIAL_API")" || {
        task_fail; error "无法从 sing-box 官方 GitHub API 获取版本信息"; exit 1;
    }
    tag="$(printf '\%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    version="${tag#v}"
    if [[ -z "$version" ]]; then
        task_fail; error "无法解析官方 sing-box 版本号"; exit 1
    fi

    if [[ "$is_alpine" -eq 1 ]]; then
        asset_name="sing-box-${version}-linux-${arch_name}-musl.tar.gz"
    else
        asset_name="sing-box-${version}-linux-${arch_name}.tar.gz"
    fi
    download_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset_name}"
    log_info "官方项目: ${OFFICIAL_REPO} | 版本: ${tag} \vert{} 文件: ${asset_name}"

    tmp_dir="$(mktemp -d /tmp/sing-box-install.XXXXXX)" || { task_fail; error "无法创建临时目录"; exit 1; }
    if ! curl -fSL --retry 3 --retry-delay 5 "$download_url" -o "$tmp_dir/sing-box.tar.gz" >> "$LOG_FILE" 2>&1; then
        rm -rf "$tmp_dir"
        task_fail; error "官方安装包下载失败: ${download_url}"; exit 1
    fi
    if ! tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir" >> "$LOG_FILE" 2>&1; then
        rm -rf "$tmp_dir"
        task_fail; error "官方安装包解压失败"; exit 1
    fi
    local binary_path
    binary_path="$(find "$tmp_dir" -type f -name sing-box -perm /111 -print -quit)"
    if [[ -z "$binary_path" ]]; then
        rm -rf "$tmp_dir"
        task_fail; error "官方压缩包中没有找到可执行的 sing-box 文件"; exit 1
    fi
    install -m 755 "$binary_path" /usr/local/bin/sing-box || {
        rm -rf "$tmp_dir"; task_fail; error "安装 sing-box 二进制文件失败"; exit 1;
    }
    rm -rf "$tmp_dir"

    if [[ "$is_alpine" -eq 1 ]]; then
        cat > /etc/init.d/"$SINGBOX_SERVICE_NAME_ALPINE" <<'OPENRC_EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
OPENRC_EOF
        chmod 755 /etc/init.d/"$SINGBOX_SERVICE_NAME_ALPINE"
        rc-update add "$SINGBOX_SERVICE_NAME_ALPINE" default >> "$LOG_FILE" 2>&1 || {
            task_fail; error "启用 OpenRC 服务失败"; exit 1;
        }
    else
        cat > /etc/systemd/system/"$SINGBOX_SERVICE_NAME" <<'SYSTEMD_EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { task_fail; error "systemd daemon-reload 失败"; exit 1; }
        systemctl enable "$SINGBOX_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用 systemd 服务失败"; exit 1; }
    fi

    if ! /usr/local/bin/sing-box version >> "$LOG_FILE" 2>&1; then
        task_fail; error "官方 sing-box 二进制文件无法运行，请检查系统架构"; exit 1
    fi
    task_done_with_info "官方 sing-box ${tag} 已安装"
}

restart_singbox_service() {
    task_start "启动服务 / Starting Service"
    if [ "$ID" = "alpine" ] \vert{}\vert{} [ "$ID_LIKE" = "alpine" ]; then
        restart_cmd=(rc-service "$SINGBOX_SERVICE_NAME_ALPINE" restart)
    else
        restart_cmd=(systemctl restart "$SINGBOX_SERVICE_NAME")
    fi
    if ! "${restart_cmd[@]}" >> "$LOG_FILE" 2>&1; then
        task_fail
        error "重启 sing-box 服务失败，详细日志："
        if [ "$ID" = "alpine" ]; then
            rc-service "$SINGBOX_SERVICE_NAME_ALPINE" status \vert{} tee -a "$LOG_FILE"
        else
            systemctl status "$SINGBOX_SERVICE_NAME" --no-pager \vert{} tee -a "$LOG_FILE"
        fi
        exit 1
    fi
    task_done
}

open_firewall_port() {
    task_start "自动放行 UDP 端口 / Opening UDP firewall port"

    local firewall_handled=0

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/udp" >> "$LOG_FILE" 2>&1 || {
            task_fail; error "UFW 放行 UDP ${port} 失败"; exit 1;
        }
        firewall_handled=1
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port="${port}/udp" >> "$LOG_FILE" 2>&1 || {
            task_fail; error "Firewalld 临时放行 UDP ${port} 失败"; exit 1;
        }
        firewall-cmd --permanent --add-port="${port}/udp" >> "$LOG_FILE" 2>&1 || {
            task_fail; error "Firewalld 永久放行 UDP ${port} 失败"; exit 1;
        }
        firewall_handled=1
    fi

    if [[ "$firewall_handled" -eq 0 ]] && command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT >> "$LOG_FILE" 2>&1 || {
                task_fail; error "iptables 放行 UDP ${port} 失败"; exit 1;
            }
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
                ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT >> "$LOG_FILE" 2>&1 || true
        fi
        firewall_handled=1
    fi

    if [[ "$firewall_handled" -eq 0 ]]; then
        task_done_with_info "未检测到正在运行的受支持防火墙，跳过"
        return 0
    fi

    task_done_with_info "UDP ${port} 防火墙放行成功"
}

enable_bbr() {
    task_start "正在启用 BBR / Enabling BBR"

    if [[ ! -w /etc/sysctl.conf ]] || [[ ! -e /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        task_done_with_info "跳过 BBR"
        return
    fi

    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

    if [[ -e /proc/sys/net/core/default_qdisc ]]; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi

    sysctl -p >> "$LOG_FILE" 2>&1 || true
    task_done
}

show_banner() {
    echo -e "     ___         ___         ___         ___                 "
    echo -e "    /__/\\       /  /\\       /__/|       /  /\\       ___    "
    echo -e "    \\  \\:\\     /  /::\\     |  |:|      /  /:/_     /__/|   "
    echo -e "     \\  \\:\\   /  /:/\\:\\    |  |:|     /  /:/ /\\    |  |:|   "
    echo -e " _____\\__\\:\\ /  /:/  \\:\\ __|  |:|    /  /:/ /:/_   |  |:|   "
    echo -e " /__/::::::::/__/:/ \\__\\:/__/\\_|:|___/__/:/ /:/ /\\__|__|:|   "
    echo -e " \\  \\:\\~~\\~~\\\\  \\:\\ /  /:\\  \\:\\/:::::\\  \\:\\/:/ /:/__/::::\\   "
    echo -e "  \\  \\:\\  ~~~ \\  \\:\\  /:/ \\  \\::/~~~~ \\  \\::/ /:/   ~\\~~\\:\\  "
    echo -e "   \\  \\:\\      \\  \\:\\/:/   \\  \\:\\      \\  \\:\\/:/      \\  \\:\\ "
    echo -e "    \\  \\:\\      \\  \\::/     \\  \\:\\      \\  \\::/        \\__\\/"
    echo -e "     \\__\\/       \\__\\/       \\__\\/       \\__\\/               "
    echo "项目地址 / GitHub"
    echo -e "${cyan}$GITHUB_URL${none}"
}

check_service_status() {
    task_start "检查服务状态 / Checking Service"
    if [ "$ID" = "alpine" ] \vert{}\vert{} [ "$ID_LIKE" = "alpine" ]; then
        rc-service "$SINGBOX_SERVICE_NAME_ALPINE" status >> "$LOG_FILE" 2>&1 || { error "服务未运行"; exit 1; }
    else
        systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" || { error "服务未运行"; systemctl status "$SINGBOX_SERVICE_NAME" --no-pager \vert{} tee -a "$LOG_FILE"; exit 1; }
    fi
    task_done
}

generate_share_links() {
    local link_ip="$ip"
    [[ $netstack == "6" ]] && link_ip="[$ip]"

    local encoded_password
    encoded_password=$(urlencode "$password")

    tuic_url="tuic://${uuid}:${encoded_password}@${link_ip}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${domain}&allow_insecure=1#${current_hostname}"

    info "v2rayN / Shadowrocket 分享链接:"
    echo -e "${magenta}${tuic_url}${none}" \vert{} tee -a "$LOG_FILE"
    echo "$tuic_url" >> "$URL_FILE"
}

generate_ipv6_variants() {
    [[ $netstack == "4" && -n "${IPv6:-}" ]] || return 0

    local encoded_password
    encoded_password=$(urlencode "$password")

    local ipv6_link
    ipv6_link="tuic://${uuid}:${encoded_password}@[${IPv6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${domain}&allow_insecure=1#${current_hostname}-ipv6"
    
    info "分享链接 (IPv6):"
    echo -e "${magenta}${ipv6_link}${none}" \vert{} tee -a "$LOG_FILE"
    echo "$ipv6_link" >> "$URL_FILE"
}

output_results() {
    check_service_status

    echo -e "${green}部署完成 / Done:${none}" \vert{} tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    echo -e "  ${green}✓${none} Sing-box TUIC (v2rayN 7.25.6+ & Shadowrocket)" | tee -a "$LOG_FILE"
    echo -e "  ${cyan}IP:Port${none} →${ip}:${port}" \vert{} tee -a "$LOG_FILE"
    echo -e "  ${cyan}UUID${none}    → ${uuid}" \vert{} tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    generate_share_links
    generate_ipv6_variants
}

main() {
    SECONDS=0

    if [ -f /etc/os-release ]; then
        . /etc/os-release
    else
        error "无法识别的OS / Cannot determine OS."
        exit 1
    fi

    show_banner
    init_output_files
    echo -e "当前版本 / Version: ${cyan}${SCRIPT_VERSION}${none} " \vert{} tee -a "$LOG_FILE"

    check_root
    install_dependencies
    detect_network_interfaces

    install_singbox_binary
    configure_singbox
    enable_bbr

    output_results
    info "总用时 / Elapsed Time:  ${green}$SECONDS 秒${none}"
    echo -e "---------- ${cyan}live free or die hard${none} -------------" \vert{} tee -a "$LOG_FILE"
}

main "$@"
