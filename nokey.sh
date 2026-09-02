#!/bin/bash

# Constants and Configuration

readonly SCRIPT_VERSION="2026.20"
readonly LOG_FILE="nokey.log"
readonly URL_FILE="nokey.url"
readonly DEFAULT_DOMAIN="www.bing.com"
readonly GITHUB_URL="https://github.com/livingfree2023/nokey"
readonly GITHUB_RELEASE_BASE_URL="https://github.com/livingfree2023/nokey/releases/latest/download"
readonly GITHUB_SINGBOX_SERVICE_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/sing-box.service"
readonly GITHUB_SINGBOX_RC_URL="https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/sing-box.rc"
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
    echo -e "\n${red}$1${none}\n" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "\n${yellow}$1${none}\n" | tee -a "$LOG_FILE"
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

log_verbose() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_info() {
    echo -e "${yellow}$1${none}" >> "$LOG_FILE"
}

separator() {
    echo -e "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${none}"
}

resolve_singbox_arch_name() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "sing-box_amd64" ;;
        aarch64|arm64) echo "sing-box_arm64" ;;
        *) return 1 ;;
    esac
}

resolve_arch_name() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

resolve_os_family() {
    if [ "${ID:-}" = "alpine" ] || [ "${ID_LIKE:-}" = "alpine" ]; then
        echo "alpine"
    else
        echo "debian/systemd-compatible"
    fi
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
    # 16 random bytes, base64 — used as the TUIC auth password
    openssl rand -base64 16
}

install_dependencies() {
    task_start "工具链检查 / Tool check"

    local tools=("curl" "netstat" "openssl")

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
            [[ "$tool" == "netstat" ]] && package_name="net-tools"
            eval "$install_cmd" "$package_name" >> "$LOG_FILE" 2>&1
            if ! command -v "$tool" > /dev/null 2>&1; then
                task_fail
                error "安装$tool失败，请手动安装后重新运行脚本 / Failed to install '$tool'. Please install it manually and re-run the script."
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

# Returns 0 if <port> is free or already owned by our service.
is_port_reusable() {
    local check_port="$1"
    local process_name="$2"
    local systemd_service="$3"
    local openrc_service="$4"
    local port_in_use=0

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "sport = :$check_port" 2>/dev/null | grep -q .; then
            port_in_use=1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | grep -qE "[:]$check_port($| )"; then
            port_in_use=1
        fi
    else
        if (echo > /dev/tcp/127.0.0.1/"$check_port") >/dev/null 2>&1; then
            port_in_use=1
        fi
    fi

    if [[ $port_in_use -eq 0 ]]; then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltnp "sport = :$check_port" 2>/dev/null | grep -q "$process_name"; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltnp 2>/dev/null | grep -E "[:.]$check_port($| )" | grep -q "$process_name"; then
            return 0
        fi
    else
        if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
            if rc-service "$openrc_service" status >/dev/null 2>&1; then
                return 0
            fi
        else
            if systemctl is-active --quiet "$systemd_service"; then
                return 0
            fi
        fi
    fi
    return 1
}

initialize_variables() {
    initialize_ip_from_netstack

    task_start "寻找一个合适的端口 / Find an Available Port"
    if is_port_reusable 443 sing-box "$SINGBOX_SERVICE_NAME" "$SINGBOX_SERVICE_NAME_ALPINE"; then
        port=443
    else
        base=$((10000 + RANDOM % 50000))
        port_found=0
        for i in $(seq 0 1000); do
            port=$((base + i))
            if ! (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
                port_found=1
                break
            fi
        done
        if [[ $port_found -eq 0 ]]; then
            task_fail
            error "没有找到可用端口 / Could not find an unused port."
            exit 1
        fi
    fi
    task_done_with_info "$port"

    # TUIC doesn't camouflage against a live upstream (that's a REALITY-only
    # trick), so the TLS cert's SNI is just a fixed, arbitrary domain name.
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
    task_start "快好了，手搓 / Configuring $config_path"

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
        error "写入sing-box配置文件失败: $config_path / Failed to write sing-box config to $config_path."
        [[ -f "$config_path" ]] && rm -f "$config_path"
        exit 1
    fi
    task_done

    log_info "--- ${config_path} ---"
    cat "$config_path" >> "$LOG_FILE"
}

install_singbox_binary() {
    task_start "开始，安装SING-BOX / Install SING-BOX"

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        rc-service "$SINGBOX_SERVICE_NAME_ALPINE" stop 2>/dev/null || true
    else
        systemctl stop "$SINGBOX_SERVICE_NAME" 2>/dev/null || true
    fi

    local arch_binary_name=""
    local arch_name=""
    arch_binary_name="$(resolve_singbox_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }
    arch_name="$(resolve_arch_name)" || { task_fail; error "不支持的架构: $(uname -m)，仅支持amd64和arm64 / Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported."; exit 1; }

    log_info "检测到系统 / Detected OS: $(resolve_os_family) | 架构 / Architecture: ${arch_name}"

    mkdir -p /usr/local/bin "$SINGBOX_CONFIG_DIR" || { task_fail; error "创建sing-box目录失败 / Failed to create sing-box directories"; exit 1; }

    curl -fSL --retry 3 --retry-delay 5 "${GITHUB_RELEASE_BASE_URL}/${arch_binary_name}" -o /usr/local/bin/sing-box >> "$LOG_FILE" 2>&1 || { task_fail; error "下载${arch_binary_name}失败 / Failed to download ${arch_binary_name}"; exit 1; }
    chmod 755 /usr/local/bin/sing-box

    local svc_rc_tmp
    local svc_service_tmp
    svc_rc_tmp="$(mktemp /tmp/nokey.sing-box.rc.XXXXXX)" || { task_fail; error "创建sing-box.rc临时文件失败 / Failed to create temporary file for sing-box.rc"; exit 1; }
    svc_service_tmp="$(mktemp /tmp/nokey.sing-box.service.XXXXXX)" || { task_fail; error "创建sing-box.service临时文件失败 / Failed to create temporary file for sing-box.service"; exit 1; }

    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        curl -fSL "${GITHUB_SINGBOX_RC_URL}" -o "${svc_rc_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载sing-box.rc失败 / Failed to download sing-box.rc"; exit 1; }
        install -m 755 "${svc_rc_tmp}" /etc/init.d/"$SINGBOX_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "安装/etc/init.d/$SINGBOX_SERVICE_NAME_ALPINE失败 / Failed to install /etc/init.d/$SINGBOX_SERVICE_NAME_ALPINE"; exit 1; }
        rm -f "${svc_rc_tmp}" >> "$LOG_FILE" 2>&1
        rc-update add "$SINGBOX_SERVICE_NAME_ALPINE" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用OpenRC服务$SINGBOX_SERVICE_NAME_ALPINE失败 / Failed to enable OpenRC service $SINGBOX_SERVICE_NAME_ALPINE"; exit 1; }
    else
        curl -fSL "${GITHUB_SINGBOX_SERVICE_URL}" -o "${svc_service_tmp}" >> "$LOG_FILE" 2>&1 || { task_fail; error "下载sing-box.service失败 / Failed to download sing-box.service"; exit 1; }
        cp "${svc_service_tmp}" /etc/systemd/system/"$SINGBOX_SERVICE_NAME" || { task_fail; error "写入/etc/systemd/system/$SINGBOX_SERVICE_NAME失败 / Failed to write /etc/systemd/system/$SINGBOX_SERVICE_NAME"; exit 1; }
        rm -f "${svc_service_tmp}" >> "$LOG_FILE" 2>&1
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { task_fail; error "systemctl daemon-reload失败 / systemctl daemon-reload failed"; exit 1; }
        systemctl enable "$SINGBOX_SERVICE_NAME" >> "$LOG_FILE" 2>&1 || { task_fail; error "启用systemd服务$SINGBOX_SERVICE_NAME失败 / Failed to enable systemd service $SINGBOX_SERVICE_NAME"; exit 1; }
    fi

    task_done
}

restart_singbox_service() {
    task_start "冲刺，开启服务 / Starting Service"
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        restart_cmd=(rc-service "$SINGBOX_SERVICE_NAME_ALPINE" restart)
    else
        restart_cmd=(systemctl restart "$SINGBOX_SERVICE_NAME")
    fi
    if ! "${restart_cmd[@]}" >> "$LOG_FILE" 2>&1; then
        task_fail
        error "重启sing-box服务失败，请查看$LOG_FILE获取详情 / Failed to restart sing-box service. Check $LOG_FILE for details."
        exit 1
    fi
    task_done
}

configure_singbox() {
    initialize_variables
    generate_crypto
    build_singbox_config
    restart_singbox_service
}

enable_bbr() {
    task_start "最后，打开BBR / Finishing, Enabling BBR"

    if [[ ! -w /etc/sysctl.conf ]]; then
        task_done_with_info "跳过BBR：/etc/sysctl.conf不可写 / Skip BBR: /etc/sysctl.conf is not writable"
        return
    fi

    if [[ ! -e /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        task_done_with_info "跳过BBR：内核未暴露tcp_congestion_control / Skip BBR: kernel does not expose tcp_congestion_control"
        return
    fi

    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

    if [[ -e /proc/sys/net/core/default_qdisc ]]; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi

    sysctl -p >> "$LOG_FILE" 2>&1 || true
    local current_cc=""
    current_cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
    if [[ "$current_cc" == *bbr* ]]; then
        task_done
    else
        warn "BBR未生效：当前拥塞算法为 ${current_cc:-unknown} / BBR not active: current congestion control is ${current_cc:-unknown}"
    fi
}

show_banner() {
    echo -e "      ___         ___         ___         ___               "
    echo -e "     /__/\\       /  /\\       /__/|       /  /\\        ___   "
    echo -e "     \\  \\:\\     /  /::\\     |  |:|      /  /:/_      /__/|  "
    echo -e "      \\  \\:\\   /  /:/\\:\\    |  |:|     /  /:/ /\\    |  |:|  "
    echo -e "  _____\\__\\:\\ /  /:/  \\:\\ __|  |:|    /  /:/ /:/_   |  |:|  "
    echo -e " /__/::::::::/__/:/ \\__\\:/__/\_|:|___/__/:/ /:/ /\\__|__|:|  "
    echo -e " \\  \\:\\~~\\~~\\\\  \\:\\ /  /:\\  \\:\\/:::::\\  \\:\\/:/ /:/__/::::\\  "
    echo -e "  \\  \\:\\  ~~~ \\  \\:\\  /:/ \\  \\::/~~~~ \\  \\::/ /:/   ~\\~~\\:\\ "
    echo -e "   \\  \\:\\      \\  \\:\\/:/   \\  \\:\\      \\  \\:\\/:/      \\  \\:\\"
    echo -e "    \\  \\:\\      \\  \\::/     \\  \\:\\      \\  \\::/        \\__\\/"
    echo -e "     \\__\\/       \\__\\/       \\__\\/       \\__\\/              "

    echo "项目地址，欢迎点点点点星 / STAR ME PLEEEEEAAAASE"
    echo -e "${cyan}$GITHUB_URL${none}"
}

check_service_status() {
    task_start "检查服务状态 / Checking Service"
    if [ "$ID" = "alpine" ] || [ "$ID_LIKE" = "alpine" ]; then
        if rc-service "$SINGBOX_SERVICE_NAME_ALPINE" status >> "$LOG_FILE" 2>&1; then
            info "Sing-box服务运行中 / Sing-box is running"
        else
            error "Sing-box服务未运行 / Sing-box service is not active"
            rc-service "$SINGBOX_SERVICE_NAME_ALPINE" status | tee -a "$LOG_FILE"
            error "详细日志记录在 $LOG_FILE / See complete logs"
            exit 1
        fi
    else
        if systemctl is-active --quiet "$SINGBOX_SERVICE_NAME"; then
            info "Sing-box服务运行中 / Sing-box is running"
        else
            error "Sing-box服务未运行 / Sing-box service is not active"
            systemctl status "$SINGBOX_SERVICE_NAME" | tee -a "$LOG_FILE"
            error "详细日志记录在 $LOG_FILE / See complete logs"
            exit 1
        fi
    fi
    task_done
}

generate_share_links() {
    local link_ip="$ip"
    [[ $netstack == "6" ]] && link_ip="[$ip]"

    tuic_url="tuic://${uuid}:${password}@${link_ip}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${domain}&allow_insecure=1#${current_hostname}"

    info "分享链接 / Share Link:"
    echo -e "${magenta}${tuic_url}${none}" | tee -a "$LOG_FILE"
    echo "$tuic_url" >> "$URL_FILE"
}

generate_clash_config() {
    local server_ip_for_clash="$ip"
    [[ $netstack == "6" ]] && server_ip_for_clash=${ip:1:-1}

    clash_tuic_config=$(cat <<-EOF
- name: ${current_hostname}
  type: tuic
  server: ${server_ip_for_clash}
  port: ${port}
  uuid: ${uuid}
  password: ${password}
  alpn: [h3]
  disable-sni: false
  reduce-rtt: true
  udp-relay-mode: native
  congestion-controller: bbr
  sni: ${domain}
  skip-cert-verify: true
EOF
)
    info "Clash.meta 配置 / Clash.meta config:"
    echo -e "${cyan}${clash_tuic_config}${none}" | tee -a "$LOG_FILE"
    echo "$clash_tuic_config" >> "$URL_FILE"
}

# Emit an extra IPv6 share URL + clash entry when the box is dual-stack but the
# primary netstack is IPv4.
generate_ipv6_variants() {
    [[ $netstack == "4" && -n "${IPv6:-}" ]] || return 0

    local ipv6_link
    ipv6_link="tuic://${uuid}:${password}@[${IPv6}]:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${domain}&allow_insecure=1#${current_hostname}-ipv6"
    info "分享链接 (IPv6) / Share Link (IPv6):"
    echo -e "${magenta}${ipv6_link}${none}" | tee -a "$LOG_FILE"
    echo "$ipv6_link" >> "$URL_FILE"

    local ipv6_clash
    ipv6_clash=$(cat <<-EOF
- name: ${current_hostname}-ipv6
  type: tuic
  server: ${IPv6}
  port: ${port}
  uuid: ${uuid}
  password: ${password}
  alpn: [h3]
  disable-sni: false
  reduce-rtt: true
  udp-relay-mode: native
  congestion-controller: bbr
  sni: ${domain}
  skip-cert-verify: true
EOF
)
    info "Clash.meta 配置 (IPv6) / Clash.meta config (IPv6):"
    echo -e "${cyan}${ipv6_clash}${none}" | tee -a "$LOG_FILE"
    echo "$ipv6_clash" >> "$URL_FILE"
}

output_results() {
    check_service_status

    echo -e "${green}舒服了 / Done:${none}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    echo -e "  ${green}✓${none} Sing-box TUIC" | tee -a "$LOG_FILE"
    echo -e "  ${cyan}IP:Port${none} → ${ip}:${port}" | tee -a "$LOG_FILE"
    echo -e "  ${cyan}UUID${none} → ${uuid}" | tee -a "$LOG_FILE"
    separator | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    generate_share_links
    generate_clash_config
    generate_ipv6_variants
}

# Main function
main() {
    SECONDS=0

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    else
        error "无法识别的OS / Cannot determine OS."
        exit 1
    fi

    show_banner
    init_output_files
    echo -e "当前版本 / Version: ${cyan}${SCRIPT_VERSION}${none} " | tee -a "$LOG_FILE"

    check_root
    install_dependencies
    detect_network_interfaces

    install_singbox_binary
    configure_singbox
    enable_bbr

    output_results
    info "总用时 / Elapsed Time:  ${green}$SECONDS 秒${none}"
    echo -e "---------- ${cyan}live free or die hard${none} -------------" | tee -a "$LOG_FILE"
}

main "$@"
