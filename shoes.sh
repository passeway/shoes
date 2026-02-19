#!/bin/bash

# ================== 颜色代码 ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ================== 常量定义 ==================
SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONF_DIR="/etc/shoes"
SHOES_CONF_FILE="${SHOES_CONF_DIR}/config.yaml"
SHOES_LINK_FILE="${SHOES_CONF_DIR}/config.txt"
SYSTEMD_FILE="/etc/systemd/system/shoes.service"
TMP_DIR="/tmp/shoesdl"
SHORTCUT_CMD="/usr/local/bin/ss"

# ================== Root 检查 ==================
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}必须使用 root 权限运行此脚本！${RESET}"
        exit 1
    fi
}

# ================== 创建快捷命令 ==================
install_shortcut() {
    if [[ ! -f "${SHORTCUT_CMD}" ]]; then
        if [[ -f "$0" ]]; then
            cp "$(realpath "$0")" "${SHORTCUT_CMD}" 2>/dev/null
            chmod +x "${SHORTCUT_CMD}" 2>/dev/null
            echo -e "${CYAN}快捷命令已创建：输入 ss 可打开管理菜单${RESET}"
        fi
    fi
}

# ================== glibc 版本 ==================
get_glibc_version() {
    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    GLIBC_MAJOR=$(echo "$GLIBC_VERSION" | cut -d. -f1)
    GLIBC_MINOR=$(echo "$GLIBC_VERSION" | cut -d. -f2)
}

# ================== 架构检测 ==================
check_arch() {
    case "$(uname -m)" in
        x86_64)
            GNU_FILE="shoes-x86_64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-x86_64-unknown-linux-musl.tar.gz"
            ;;
        aarch64|arm64)
            GNU_FILE="shoes-aarch64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-aarch64-unknown-linux-musl.tar.gz"
            ;;
        *)
            echo -e "${RED}不支持的 CPU 架构！${RESET}"
            exit 1
            ;;
    esac
}

# ================== 最新版本 ==================
get_latest_version() {
    LATEST_VER=$(curl -s https://api.github.com/repos/cfal/shoes/releases/latest \
        | grep '"tag_name":' \
        | sed -E 's/.*"v?([^"]+)".*/\1/')
    [[ -z "$LATEST_VER" ]] && {
        echo -e "${RED}无法获取 Shoes 最新版本！${RESET}"
        exit 1
    }
}

# ================== 运行测试 ==================
test_shoes_binary() {
    ${SHOES_BIN} generate-reality-keypair >/dev/null 2>&1
}

# ================== 下载 Shoes ==================
download_shoes() {
    get_glibc_version
    check_arch
    get_latest_version

    if (( GLIBC_MAJOR < 2 )) || (( GLIBC_MAJOR == 2 && GLIBC_MINOR < 38 )); then
        DOWNLOAD_FILE="${MUSL_FILE}"
    else
        DOWNLOAD_FILE="${GNU_FILE}"
    fi

    mkdir -p "${TMP_DIR}"
    cd "${TMP_DIR}" || exit 1

    DOWNLOAD_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${DOWNLOAD_FILE}"

    wget -q -O shoes.tar.gz "$DOWNLOAD_URL" || {
        DOWNLOAD_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
        wget -q -O shoes.tar.gz "$DOWNLOAD_URL" || exit 1
    }

    tar -xzf shoes.tar.gz
    mv shoes "${SHOES_BIN}"
    chmod +x "${SHOES_BIN}"

    test_shoes_binary || {
        echo -e "${RED}Shoes 无法运行${RESET}"
        exit 1
    }
}

# ================== 更新 ==================
update_shoes() {
    echo -e "${GREEN}开始更新 Shoes...${RESET}"
    download_shoes
    systemctl restart shoes
    echo -e "${GREEN}更新完成并已重启${RESET}"
}

# ================== 安装 ==================
install_shoes() {

    download_shoes
    mkdir -p "${SHOES_CONF_DIR}"

    read -p "请输入 VLESS+Reality 端口(默认随机): " VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-$(shuf -i 20000-60000 -n 1)}

    read -p "请输入 AnyTLS 端口(默认随机): " ANYTLS_PORT
    ANYTLS_PORT=${ANYTLS_PORT:-$(shuf -i 20000-60000 -n 1)}

    read -p "请输入 Hysteria2 端口(默认随机): " HY2_PORT
    HY2_PORT=${HY2_PORT:-$(shuf -i 20000-60000 -n 1)}

    SNI="www.ua.edu"
    SHID=$(openssl rand -hex 8)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$(shoes generate-reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "private key" | awk '{print $4}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "public key" | awk '{print $4}')
    HY2_PASS=$(openssl rand -hex 8)

    openssl ecparam -genkey -name prime256v1 -out "${SHOES_CONF_DIR}/key.pem" || exit 1
    openssl req -new -x509 -days 3650 -key "${SHOES_CONF_DIR}/key.pem" \
        -out "${SHOES_CONF_DIR}/cert.pem" -subj "/CN=bing.com" || exit 1

    cat > "${SHOES_CONF_FILE}" <<EOF
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
        cert: "/etc/shoes/cert.pem"
        key: "/etc/shoes/key.pem"
        protocol:
          type: anytls
          users:
            - name: anylts
              password: "${PUBLIC_KEY}"
          udp_enabled: true

- address: "0.0.0.0:${HY2_PORT}"
  transport: quic
  quic_settings:
    cert: "/etc/shoes/cert.pem"
    key: "/etc/shoes/key.pem"
    alpn_protocols: ["h3"]
  protocol:
    type: hysteria2
    password: "${HY2_PASS}"
    udp_enabled: true
EOF

    cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=Shoes Proxy Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${SHOES_BIN} ${SHOES_CONF_FILE}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shoes

    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep ip | awk -F= '{print $2}')
    COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)

    cat > "${SHOES_LINK_FILE}" <<EOF
vless://${UUID}@${HOST_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=random&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${HOST_IP}-${COUNTRY}-VLESS
anytls://${PUBLIC_KEY}@${HOST_IP}:${ANYTLS_PORT}?security=tls&sni=www.bing.com&allowInsecure=1&type=tcp&insecure=1#${HOST_IP}-${COUNTRY}-ANYTLS
hy2://${HY2_PASS}@${HOST_IP}:${HY2_PORT}?udp=true&type=quic&alpn=h3&insecure=1#${HOST_IP}-${COUNTRY}-HY2
EOF

    echo -e "${GREEN}Shoes 安装完成！${RESET}"
    cat "${SHOES_LINK_FILE}"
}

# ================== 卸载 ==================
uninstall_shoes() {
    systemctl stop shoes
    systemctl disable shoes
    rm -f "${SYSTEMD_FILE}"
    rm -rf "${SHOES_CONF_DIR}"
    rm -f "${SHOES_BIN}"
    rm -f "${SHORTCUT_CMD}"
    systemctl daemon-reload
    echo -e "${GREEN}Shoes 已卸载${RESET}"
}

check_installed() { command -v shoes >/dev/null 2>&1; }
check_running() { systemctl is-active --quiet shoes; }

# ================== 菜单 ==================
show_menu() {
    clear
    echo -e "${GREEN}    === Shoes 服务管理工具 ===${RESET}"  
    echo -e "${GREEN}  目前支持hy2、anytls、vless+reality ${RESET}"  
    echo -e "${GREEN}=== 首次运行后ss可快速打开管理工具 ===${RESET}"
    echo ""
    echo "1. 一键部署 Shoes 三协议服务"
    echo "2. 更新 Shoes 服务"
    echo "3. 卸载 Shoes 服务"
    echo "4. 启动 Shoes 服务"
    echo "5. 停止 Shoes 服务"
    echo "6. 重启 Shoes 服务"
    echo "7. 查看 Shoes 配置"
    echo "8. 查看 Shoes 日志"
    echo "0. 退出"
    echo ""
    read -p "请输入选项: " choice
}

require_root
install_shortcut

while true; do
    show_menu
    case "$choice" in
        1) install_shoes ;;
        2) update_shoes ;;
        3) uninstall_shoes ;;
        4) systemctl start shoes ;;
        5) systemctl stop shoes ;;
        6) systemctl restart shoes ;;
        7) cat "${SHOES_LINK_FILE}" ;;
        8) journalctl -u shoes -f ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
    read -p "按 Enter 继续..."
done
