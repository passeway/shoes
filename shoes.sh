#!/usr/bin/env bash
# Shoes manager: Debian / Ubuntu (systemd), Alpine (OpenRC).

SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONF_DIR="/etc/shoes"
SHOES_CONF_FILE="${SHOES_CONF_DIR}/config.yaml"
SHOES_LINK_FILE="${SHOES_CONF_DIR}/config.txt"
SS2022_CONF_FILE="${SHOES_CONF_DIR}/ss2022.json"
SS2022_LINK_FILE="${SHOES_CONF_DIR}/ss2022.txt"
SS2022_METHOD="2022-blake3-aes-128-gcm"
SYSTEMD_FILE="/etc/systemd/system/shoes.service"
OPENRC_FILE="/etc/init.d/shoes"
LOG_FILE="/var/log/shoes.log"
LOCK_FILE="/run/shoes-manager.lock"
OS_RELEASE_FILE="/etc/os-release"

error() { printf '错误：%s\n' "$*" >&2; }

require_root() {
    [[ $EUID -eq 0 ]] || { error '请使用 root 权限运行。'; return 1; }
}

detect_system() {
    local ID=''
    [[ -r "$OS_RELEASE_FILE" ]] || { error '无法识别操作系统。'; return 1; }
    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"
    case "$ID" in
        debian|ubuntu) OS_ID="$ID"; SERVICE_MANAGER=systemd ;;
        alpine) OS_ID=alpine; SERVICE_MANAGER=openrc ;;
        *) error '仅支持 Debian、Ubuntu 和 Alpine。'; return 1 ;;
    esac
}

ensure_dependencies() {
    local command missing=0 manager=systemctl
    [[ "$SERVICE_MANAGER" == openrc ]] && manager=rc-service
    for command in curl tar gzip openssl jq shuf ss flock timeout sha256sum "$manager"; do
        command -v "$command" >/dev/null 2>&1 || missing=1
    done
    [[ -r /etc/ssl/certs/ca-certificates.crt ]] || missing=1
    if (( missing )); then
        printf '安装必要软件包\n'
        case "$OS_ID" in
            debian|ubuntu)
                apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    ca-certificates curl tar gzip openssl jq coreutils iproute2 util-linux || return 1 ;;
            alpine)
                apk add --no-cache bash ca-certificates curl tar gzip openssl jq \
                    coreutils iproute2 util-linux openrc || return 1 ;;
        esac
    fi
    for command in curl tar gzip openssl jq shuf ss flock timeout sha256sum "$manager"; do
        command -v "$command" >/dev/null 2>&1 || { error "缺少依赖：$command"; return 1; }
    done
    if [[ "$SERVICE_MANAGER" == systemd && ! -d /run/systemd/system ]]; then
        error '当前环境未运行 systemd，无法管理服务。'
        return 1
    fi
}

# Each modifying operation runs in a subshell; its trap only removes its own staging directory.
begin_operation() {
    umask 077
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { error '另一个 Shoes 管理操作正在执行。'; return 1; }
    mkdir -p "${SHOES_BIN%/*}" || return 1
    WORK_DIR=$(mktemp -d "${SHOES_BIN%/*}/.shoes-stage.XXXXXX") || return 1
    trap 'rm -rf -- "$WORK_DIR"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

fetch_file() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 180 --retry 2 --output "$2" "$1"
}

check_arch() {
    case "$(uname -m)" in
        x86_64) ARCH=x86_64 ;;
        aarch64|arm64) ARCH=aarch64 ;;
        *) error '仅支持 x86_64 和 ARM64。'; return 1 ;;
    esac
}

download_shoes() {
    local flavor asset url digest archive member version
    local -a flavors=(gnu musl)
    check_arch || return 1
    [[ "$OS_ID" == alpine ]] && flavors=(musl)
    fetch_file 'https://api.github.com/repos/cfal/shoes/releases/latest' "$WORK_DIR/release.json" || return 1
    RELEASE_TAG=$(jq -er '.tag_name | select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.-]+)?$"))' \
        "$WORK_DIR/release.json") || { error '无法解析 Shoes 最新版本。'; return 1; }
    printf 'Shoes 最新版本：%s\n' "$RELEASE_TAG"
    for flavor in "${flavors[@]}"; do
        asset="shoes-${ARCH}-unknown-linux-${flavor}.tar.gz"
        url=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' \
            "$WORK_DIR/release.json") || continue
        [[ "$url" == "https://github.com/cfal/shoes/releases/download/${RELEASE_TAG}/${asset}" ]] || continue
        digest=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty' \
            "$WORK_DIR/release.json") || return 1
        archive="$WORK_DIR/$asset"
        printf '下载 %s 内核\n' "${flavor^^}"
        fetch_file "$url" "$archive" || continue
        if [[ -n "$digest" ]]; then
            if [[ ! "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] ||
                ! printf '%s  %s\n' "${digest#sha256:}" "$archive" | sha256sum -c - >/dev/null; then
                error "${flavor^^} 下载校验失败。"
                continue
            fi
        else
            printf '提示：上游未提供该文件的 SHA-256 摘要。\n' >&2
        fi
        tar -tzf "$archive" > "$WORK_DIR/members" || continue
        member=$(grep -Ex '(\./)?shoes' "$WORK_DIR/members") || continue
        [[ "$member" != *$'\n'* ]] || continue
        CANDIDATE="$WORK_DIR/shoes.$flavor"
        tar -xOzf "$archive" "$member" > "$CANDIDATE" || continue
        [[ -s "$CANDIDATE" ]] || continue
        chmod 755 "$CANDIDATE" || continue
        version=$(timeout 15 "$CANDIDATE" --version 2>/dev/null) || continue
        [[ "$version" == "shoes ${RELEASE_TAG#v}" ]] || continue
        timeout 15 "$CANDIDATE" generate-reality-keypair >/dev/null 2>&1 || continue
        printf '%s 内核运行检查通过\n' "${flavor^^}"
        return 0
    done
    error '没有下载到可运行的 Shoes 内核，现有内核未替换。'
    return 1
}

validate_config() {
    local binary="$1"
    shift
    if ! timeout 30 "$binary" --dry-run "$@" > "$WORK_DIR/validate.log" 2>&1; then
        error '配置检查失败：'
        cat "$WORK_DIR/validate.log" >&2
        return 1
    fi
}

service_config_files() {
    SHOES_CONFIGS=("$SHOES_CONF_FILE")
    [[ ! -e "$SS2022_CONF_FILE" ]] || SHOES_CONFIGS+=("$SS2022_CONF_FILE")
}

validate_service_config() {
    service_config_files
    validate_config "$1" "${SHOES_CONFIGS[@]}"
}

choose_port() {
    local reserved port listeners attempt taken
    for ((attempt=0; attempt<128; attempt++)); do
        port=$(shuf -i 20000-60000 -n 1) || return 1
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        taken=0
        for reserved in "$@"; do
            [[ "$port" != "$reserved" ]] || taken=1
        done
        ((taken == 0)) || continue
        listeners=$(ss -H -lntu "sport = :$port") || { error '无法检查端口占用。'; return 1; }
        if [[ -z "$listeners" ]]; then printf '%s\n' "$port"; return 0; fi
    done
    error '未能找到可用端口。'
    return 1
}

valid_ipv4() {
    local ip="$1" part
    local -a parts
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
    [[ "$ip" != 0.0.0.0 && "$ip" != 127.* ]]
}

get_public_ip() {
    local reply
    reply=$(curl -4fsSL --connect-timeout 5 --max-time 12 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || reply=''
    HOST_IP=$(printf '%s\n' "$reply" | sed -n 's/^ip=//p' | tr -d '\r')
    if ! valid_ipv4 "$HOST_IP"; then
        HOST_IP=$(curl -4fsSL --connect-timeout 5 --max-time 12 https://api.ipify.org 2>/dev/null) || HOST_IP=''
    fi
    if ! valid_ipv4 "$HOST_IP"; then
        read -r -p '无法获取公网 IPv4，请手动输入服务器 IPv4：' HOST_IP || return 1
        valid_ipv4 "$HOST_IP" || { error 'IPv4 地址无效。'; return 1; }
    fi
    COUNTRY=$(curl -4fsSL --connect-timeout 5 --max-time 8 "https://ipinfo.io/${HOST_IP}/country" 2>/dev/null) || COUNTRY=''
    COUNTRY=${COUNTRY//$'\n'/}; COUNTRY=${COUNTRY//$'\r'/}
    [[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || COUNTRY=Shoes
}

generate_credentials() {
    local keypair
    SNI=www.ua.edu
    SHID=$(openssl rand -hex 8) || return 1
    UUID=$(cat /proc/sys/kernel/random/uuid) || return 1
    keypair=$(timeout 15 "$CANDIDATE" generate-reality-keypair) || return 1
    PRIVATE_KEY=$(printf '%s\n' "$keypair" | awk '/^REALITY private key: / {print $4}')
    PUBLIC_KEY=$(printf '%s\n' "$keypair" | awk '/^REALITY public key: / {print $4}')
    [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ && "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ &&
        "$SHID" =~ ^[a-f0-9]{16}$ && "$UUID" =~ ^[a-f0-9-]{36}$ ]] || { error '生成凭据失败。'; return 1; }
    VLESS_PORT=$(choose_port) || return 1
    ANYTLS_PORT=$(choose_port "$VLESS_PORT") || return 1
    generate_ss2022_credentials "$VLESS_PORT" "$ANYTLS_PORT" || return 1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
        -subj '/CN=www.bing.com' -addext 'subjectAltName=DNS:www.bing.com' >/dev/null 2>&1 || return 1
}

generate_ss2022_credentials() {
    SS2022_PORT=$(choose_port "$@") || return 1
    SS2022_PASSWORD=$(openssl rand -base64 16) || return 1
    [[ "$SS2022_PASSWORD" =~ ^[A-Za-z0-9+/]{22}==$ ]] || { error '生成 SS2022 密钥失败。'; return 1; }
}

write_ss2022_config() {
    # JSON is also valid YAML, and allows reading the existing key without shell parsing.
    jq -n --arg address "0.0.0.0:$SS2022_PORT" --arg method "$SS2022_METHOD" \
        --arg password "$SS2022_PASSWORD" \
        '[{address:$address, protocol:{type:"shadowsocks", cipher:$method, password:$password, udp_enabled:true}}]' > "$1"
}

write_ss2022_link() {
    local encoded_password
    encoded_password=$(printf '%s' "$SS2022_PASSWORD" | jq -sRr @uri) || return 1
    # SIP002: AEAD-2022 uses percent-encoded method:password, not Base64 userinfo.
    printf 'ss://%s:%s@%s:%s#%s-ss2022-128\n' \
        "$SS2022_METHOD" "$encoded_password" "$HOST_IP" "$SS2022_PORT" "$COUNTRY" > "$1"
}

atomic_private_file() (
    local staged destination="$2"
    umask 077
    staged=$(mktemp "${destination%/*}/.ss2022.XXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT
    install -m 600 "$1" "$staged" && mv -f "$staged" "$destination"
)

write_config() {
    local destination="$1" cert_dir="$2"
    cat > "$destination" <<EOF
- address: "0.0.0.0:${VLESS_PORT}"
  protocol:
    type: tls
    reality_targets:
      "${SNI}":
        private_key: "${PRIVATE_KEY}"
        short_ids: ["${SHID}"]
        dest: "${SNI}:443"
        vision: true
        protocol:
          type: vless
          user_id: "${UUID}"
          udp_enabled: true
- address: "0.0.0.0:${ANYTLS_PORT}"
  protocol:
    type: tls
    tls_targets:
      "www.bing.com":
        cert: "${cert_dir}/cert.pem"
        key: "${cert_dir}/key.pem"
        protocol:
          type: anytls
          users:
            - name: anytls
              password: "${PUBLIC_KEY}"
          udp_enabled: true
EOF
}

write_links() {
    cat > "$1" <<EOF
vless://${UUID}@${HOST_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${COUNTRY}-vless
anytls://${PUBLIC_KEY}@${HOST_IP}:${ANYTLS_PORT}?insecure=1&security=tls&sni=www.bing.com&type=tcp&headerType=none#${COUNTRY}-anytls
EOF
}

secure_config() {
    local file
    [[ -d "$SHOES_CONF_DIR" ]] || return 0
    chmod 700 "$SHOES_CONF_DIR" || return 1
    for file in "$SHOES_CONF_FILE" "$SHOES_LINK_FILE" "$SS2022_CONF_FILE" "$SS2022_LINK_FILE" \
        "$SHOES_CONF_DIR/key.pem" "$SHOES_CONF_DIR/cert.pem"; do
        [[ ! -f "$file" ]] || chmod 600 "$file" || return 1
    done
}

repair_links() (
    [[ -f "$SHOES_LINK_FILE" ]] || return 0
    umask 077
    local staged
    staged=$(mktemp "$SHOES_CONF_DIR/.links.XXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT
    sed '/^anytls:\/\//s/\([?&]\)allowInsecure=1\([&#]\|$\)/\1insecure=1\2/g' \
        "$SHOES_LINK_FILE" > "$staged" && chmod 600 "$staged" && mv -f "$staged" "$SHOES_LINK_FILE"
)

install_service() {
    local config_args
    service_config_files
    config_args="${SHOES_CONFIGS[*]}"
    if [[ "$SERVICE_MANAGER" == systemd ]]; then
        cat > "$WORK_DIR/service" <<EOF
[Unit]
Description=Shoes Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
ExecStartPre=${SHOES_BIN} --dry-run ${config_args}
ExecStart=${SHOES_BIN} ${config_args}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        install -m 644 "$WORK_DIR/service" "$SYSTEMD_FILE" && systemctl daemon-reload
    else
        cat > "$WORK_DIR/service" <<EOF
#!/sbin/openrc-run
name="Shoes Proxy Server"
description="Shoes Proxy Server"
command="${SHOES_BIN}"
command_args="${config_args}"
command_background="yes"
pidfile="/run/shoes.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() { need net; }
start_pre() {
    checkpath -f -m 0600 -o root:root "\$output_log" || return 1
    /usr/bin/timeout 30 "\$command" --dry-run ${config_args}
}
EOF
        install -m 755 "$WORK_DIR/service" "$OPENRC_FILE"
    fi
}

service_action() {
    if [[ "$SERVICE_MANAGER" == systemd ]]; then systemctl "$1" shoes 9>&-
    else rc-service shoes "$1" 9>&-; fi
}

check_installed() { [[ -x "$SHOES_BIN" && -s "$SHOES_CONF_FILE" ]]; }
check_running() {
    if [[ "$SERVICE_MANAGER" == systemd ]]; then systemctl is-active --quiet shoes
    else rc-service shoes status >/dev/null 2>&1; fi
}

show_recent_logs() {
    if [[ "$SERVICE_MANAGER" == systemd ]]; then journalctl -u shoes -n 30 --no-pager
    elif [[ -f "$LOG_FILE" ]]; then tail -n 30 "$LOG_FILE"; fi
}

wait_running() {
    local i stable=0
    for ((i=0; i<8; i++)); do
        sleep 1
        if check_running; then
            stable=$((stable+1))
            ((stable >= 2)) && return 0
        else stable=0; fi
    done
    return 1
}

start_checked() {
    if ! service_action "$1" || ! wait_running; then
        error 'Shoes 未能正常运行，请检查下方日志。'
        show_recent_logs >&2
        return 1
    fi
}

install_shoes() (
    if [[ -e "$SHOES_CONF_FILE" ]]; then
        check_installed || { error '安装不完整，请检查现有文件，或先卸载后再安装。'; return 1; }
        secure_config && repair_links || return 1
        if [[ ! -s "$SS2022_CONF_FILE" || ! -s "$SS2022_LINK_FILE" ]]; then
            add_ss2022
            return $?
        fi
        printf '已有配置，已保留端口与凭据。更新内核请选择 8；启动服务请选择 3。\n'
        return 0
    fi
    if [[ -e "$SHOES_BIN" || -e "$SYSTEMD_FILE" || -e "$OPENRC_FILE" || -e "$SS2022_CONF_FILE" ]]; then
        error '发现不完整的安装，请检查现有文件，或先通过菜单卸载后再安装。'
        return 1
    fi
    ensure_dependencies && begin_operation || return 1
    printf '开始安装 Shoes\n'
    download_shoes && get_public_ip && generate_credentials || return 1
    write_config "$WORK_DIR/config.yaml" "$WORK_DIR" && write_ss2022_config "$WORK_DIR/ss2022.json" &&
        validate_config "$CANDIDATE" "$WORK_DIR/config.yaml" "$WORK_DIR/ss2022.json" || return 1
    install -d -m 700 "$SHOES_CONF_DIR" || return 1
    install -m 600 "$WORK_DIR/key.pem" "$WORK_DIR/cert.pem" "$SHOES_CONF_DIR/" || return 1
    write_config "$WORK_DIR/config.yaml" "$SHOES_CONF_DIR" &&
        validate_config "$CANDIDATE" "$WORK_DIR/config.yaml" "$WORK_DIR/ss2022.json" || return 1
    write_links "$WORK_DIR/config.txt" && write_ss2022_link "$WORK_DIR/ss2022.txt" || return 1
    install -m 600 "$WORK_DIR/config.yaml" "$SHOES_CONF_FILE" &&
        install -m 600 "$WORK_DIR/config.txt" "$SHOES_LINK_FILE" &&
        atomic_private_file "$WORK_DIR/ss2022.json" "$SS2022_CONF_FILE" &&
        atomic_private_file "$WORK_DIR/ss2022.txt" "$SS2022_LINK_FILE" &&
        mv -f "$CANDIDATE" "$SHOES_BIN" && install_service || return 1
    if [[ "$SERVICE_MANAGER" == systemd ]]; then systemctl enable shoes || return 1
    else rc-update add shoes default || return 1; fi
    start_checked start || return 1
    printf 'Shoes 安装完成！\n'
    printf '请在云平台安全组及系统防火墙放行 TCP 端口 %s、%s、%s。\n' "$VLESS_PORT" "$ANYTLS_PORT" "$SS2022_PORT"
    cat "$SHOES_LINK_FILE" "$SS2022_LINK_FILE"
)

add_ss2022() (
    check_installed || { error '请先安装 Shoes。'; return 1; }
    ensure_dependencies && begin_operation && secure_config || return 1
    local was_running=0 ports
    local -a reserved_ports=()
    check_running && was_running=1
    if [[ -e "$SS2022_CONF_FILE" ]]; then
        # An interrupted addition can be retried without regenerating the key.
        validate_service_config "$SHOES_BIN" || return 1
        if [[ ! -s "$SS2022_LINK_FILE" ]]; then
            SS2022_PORT=$(jq -er '.[0].address | split(":") | last | tonumber' "$SS2022_CONF_FILE") &&
                SS2022_PASSWORD=$(jq -er --arg method "$SS2022_METHOD" \
                    '.[0].protocol | select(.type=="shadowsocks" and .cipher==$method) | .password' "$SS2022_CONF_FILE") || return 1
            get_public_ip && write_ss2022_link "$WORK_DIR/ss2022.txt" &&
                atomic_private_file "$WORK_DIR/ss2022.txt" "$SS2022_LINK_FILE" || return 1
        fi
        printf 'SS2022-128 已存在，保留原有端口与密钥。\n'
    else
        # Also reserve configured ports while the old service is stopped.
        ports=$(awk '/^[[:space:]]*(-[[:space:]]*)?address:/ {
            line=$0; sub(/#.*/, "", line); gsub(/[[:space:]"\047]/, "", line)
            sub(/^.*:/, "", line); if (line ~ /^[0-9]+$/) print line
        }' "$SHOES_CONF_FILE") || return 1
        if [[ -n "$ports" ]]; then mapfile -t reserved_ports <<< "$ports"; fi
        get_public_ip && generate_ss2022_credentials "${reserved_ports[@]}" &&
            write_ss2022_config "$WORK_DIR/ss2022.json" &&
            validate_config "$SHOES_BIN" "$SHOES_CONF_FILE" "$WORK_DIR/ss2022.json" &&
            write_ss2022_link "$WORK_DIR/ss2022.txt" || return 1
        atomic_private_file "$WORK_DIR/ss2022.json" "$SS2022_CONF_FILE" &&
            atomic_private_file "$WORK_DIR/ss2022.txt" "$SS2022_LINK_FILE" || return 1
        printf '请在云平台安全组及系统防火墙放行 TCP 端口 %s。\n' "$SS2022_PORT"
    fi
    install_service || return 1
    if ((was_running)); then start_checked restart || return 1
    else printf '服务保持停止状态，可选择 3 启动。\n'; fi
    printf 'SS2022-128 配置完成。\n'
    cat "$SS2022_LINK_FILE"
)

update_shoes() (
    check_installed || { error '请先安装 Shoes。'; return 1; }
    ensure_dependencies && begin_operation || return 1
    local was_running=0
    check_running && was_running=1
    secure_config && repair_links && download_shoes && validate_service_config "$CANDIDATE" || return 1
    install_service && mv -f "$CANDIDATE" "$SHOES_BIN" || return 1
    if ((was_running)); then start_checked restart || return 1; fi
    printf 'Shoes 内核已更新到 %s，端口与凭据已保留。\n' "$RELEASE_TAG"
    ((was_running)) || printf '服务保持停止状态，可选择 3 启动。\n'
)

manage_service() (
    check_installed || { error '请先安装 Shoes。'; return 1; }
    ensure_dependencies && begin_operation && secure_config || return 1
    if [[ "$1" == stop ]]; then
        service_action stop || return 1
        if check_running; then error '服务仍在运行。'; return 1; fi
        printf 'Shoes 已停止。\n'
    else
        validate_service_config "$SHOES_BIN" && start_checked "$1" || return 1
        printf 'Shoes 正在运行。\n'
    fi
)

uninstall_shoes() (
    local answer service_file="$SYSTEMD_FILE"
    read -r -p '卸载将删除 Shoes 配置和凭据，确认卸载？[y/N] ' answer || return 1
    [[ "$answer" == y || "$answer" == Y ]] || { printf '已取消卸载。\n'; return 0; }
    ensure_dependencies && begin_operation || return 1
    [[ "$SERVICE_MANAGER" == openrc ]] && service_file="$OPENRC_FILE"
    if [[ -f "$service_file" ]]; then
        service_action stop || return 1
        if check_running; then error '服务尚未停止，取消删除。'; return 1; fi
        if [[ "$SERVICE_MANAGER" == systemd ]]; then systemctl disable shoes || return 1
        else rc-update del shoes default || return 1; fi
    fi
    rm -f -- "$SHOES_BIN" "$service_file" || return 1
    rm -rf -- "$SHOES_CONF_DIR" || return 1
    if [[ "$SERVICE_MANAGER" == systemd ]]; then systemctl daemon-reload || return 1; fi
    printf 'Shoes 已卸载。\n'
)

show_links() {
    [[ -s "$SHOES_LINK_FILE" ]] || { error '尚无分享链接，请先完成安装。'; return 1; }
    secure_config && repair_links && cat "$SHOES_LINK_FILE" || return 1
    [[ ! -s "$SS2022_LINK_FILE" ]] || cat "$SS2022_LINK_FILE"
}

show_logs() (
    check_installed || { error '请先安装 Shoes。'; return 1; }
    # Ctrl+C leaves log following and returns to the menu.
    trap ':' INT
    if [[ "$SERVICE_MANAGER" == systemd ]]; then journalctl -u shoes -n 30 -f
    else tail -n 30 -F "$LOG_FILE"; fi
)

show_menu() {
    local version='—'
    [[ ! -t 1 ]] || clear 2>/dev/null || :
    if [[ -x "$SHOES_BIN" ]] && command -v timeout >/dev/null 2>&1; then
        version=$(timeout 3 "$SHOES_BIN" --version 2>/dev/null) || version='未知'
    fi
    printf '=== Shoes 管理工具 ===\n'
    printf '安装状态: %s\n' "$(check_installed && echo 已安装 || echo 未安装)"
    printf '运行状态: %s\n' "$(check_running 2>/dev/null && echo 运行中 || echo 未运行)"
    printf '运行版本: %s\n\n' "$version"
    printf '%s\n' '1. 安装 Shoes 服务' '2. 卸载 Shoes 服务' '3. 启动 Shoes 服务' \
        '4. 停止 Shoes 服务' '5. 重启 Shoes 服务' '6. 查看 Shoes 配置' '7. 查看 Shoes 日志' \
        '8. 更新 Shoes 内核' '0. 退出' '====================='
}

main() {
    local choice
    set -o pipefail
    require_root && detect_system || return 1
    while true; do
        show_menu
        read -r -p '请输入选项编号: ' choice || { printf '\n'; break; }
        case "$choice" in
            1) install_shoes ;;
            2) uninstall_shoes ;;
            3) manage_service start ;;
            4) manage_service stop ;;
            5) manage_service restart ;;
            6) show_links ;;
            7) trap ':' INT; show_logs; trap - INT ;;
            8) update_shoes ;;
            0) return 0 ;;
            *) printf '无效选项。\n' ;;
        esac
        read -r -p '按 Enter 继续...' || { printf '\n'; break; }
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
