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

# ================== Root 检查 ==================
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}必须使用 root 权限运行此脚本！${RESET}"
        exit 1
    fi
}

# ================== glibc 版本 ==================
get_glibc_version() {
    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    GLIBC_MAJOR=$(echo "$GLIBC_VERSION" | cut -d. -f1)
    GLIBC_MINOR=$(echo "$GLIBC_VERSION" | cut -d. -f2)
    echo -e "${GREEN}系统 glibc 版本：${YELLOW}${GLIBC_VERSION}${RESET}"
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
    echo -e "${GREEN}Shoes 最新版本：${YELLOW}v${LATEST_VER}${RESET}"
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
        echo -e "${YELLOW}glibc < 2.38，使用 MUSL 版本${RESET}"
        DOWNLOAD_FILE="${MUSL_FILE}"
        DOWNLOAD_TYPE="MUSL"
    else
        echo -e "${GREEN}glibc >= 2.38，优先 GNU${RESET}"
        DOWNLOAD_FILE="${GNU_FILE}"
        DOWNLOAD_TYPE="GNU"
    fi

    mkdir -p "${TMP_DIR}"
    cd "${TMP_DIR}" || exit 1

    DOWNLOAD_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${DOWNLOAD_FILE}"
    echo -e "${CYAN}下载 ${DOWNLOAD_TYPE}: ${YELLOW}${DOWNLOAD_URL}${RESET}"

    wget -O shoes.tar.gz "$DOWNLOAD_URL" || {
        if [[ "$DOWNLOAD_TYPE" == "GNU" ]]; then
            echo -e "${YELLOW}GNU 失败，尝试 MUSL${RESET}"
            DOWNLOAD_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
            wget -O shoes.tar.gz "$DOWNLOAD_URL" || exit 1
        else
            exit 1
        fi
    }

    tar -xzf shoes.tar.gz
    mv shoes "${SHOES_BIN}"
    chmod +x "${SHOES_BIN}"

    if test_shoes_binary; then
        echo -e "${GREEN}Shoes (${DOWNLOAD_TYPE}) 正常运行${RESET}"
        return
    fi

    if [[ "$DOWNLOAD_TYPE" == "GNU" ]]; then
        echo -e "${YELLOW}GNU 无法运行，切换 MUSL${RESET}"
        wget -O shoes.tar.gz \
            "https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
        tar -xzf shoes.tar.gz
        mv shoes "${SHOES_BIN}"
        chmod +x "${SHOES_BIN}"
        test_shoes_binary || {
            echo -e "${RED}MUSL 无法运行${RESET}"
            exit 1
        }
    else
        echo -e "${RED}MUSL 无法运行${RESET}"
        exit 1
    fi
}

# ================== 安装 ==================
install_shoes() {
    echo -e "${CYAN}开始安装 Shoes${RESET}"
    download_shoes
    mkdir -p "${SHOES_CONF_DIR}"

    SNI="www.ua.edu"
    SHID=$(openssl rand -hex 8)
    PORT=$(shuf -i 20000-60000 -n 1)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$(shoes generate-reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "private key" | awk '{print $4}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "public key" | awk '{print $4}')


    

    cat > "${SHOES_CONF_FILE}" <<EOF
- address: "0.0.0.0:${PORT}"
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
    systemctl enable shoes
    systemctl restart shoes

    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep ip | awk -F= '{print $2}')
    COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)

    cat > "${SHOES_LINK_FILE}" <<EOF
vless://${UUID}@${HOST_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=random&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${COUNTRY}
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
    systemctl daemon-reload
    echo -e "${GREEN}Shoes 已卸载${RESET}"
}

# ================== 状态 ==================
check_installed() { command -v shoes >/dev/null 2>&1; }
check_running() { systemctl is-active --quiet shoes; }

# ================== 菜单 ==================
show_menu() {
    clear
    echo -e "${GREEN}=== Shoes 管理工具 ===${RESET}"
    echo -e "安装状态: $(check_installed && echo -e "${GREEN}已安装${RESET}" || echo -e "${RED}未安装${RESET}")"
    echo -e "运行状态: $(check_running && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")"
    echo ""
    echo "1. 安装 Shoes 服务"
    echo "2. 卸载 Shoes 服务"
    echo "3. 启动 Shoes 服务"
    echo "4. 停止 Shoes 服务"
    echo "5. 重启 Shoes 服务"
    echo "6. 查看 Shoes 配置"
    echo "7. 查看 Shoes 日志"
    echo "0. 退出"
    echo -e "${GREEN}=====================${RESET}"
    echo ""
    read -p "请输入选项: " choice
}

# ================== 主循环 ==================
require_root
while true; do
    show_menu
    case "$choice" in
        1) install_shoes ;;
        2) uninstall_shoes ;;
        3) systemctl start shoes ;;
        4) systemctl stop shoes ;;
        5) systemctl restart shoes ;;
        6) cat "${SHOES_LINK_FILE}" ;;
        7) journalctl -u shoes -f ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
    read -p "按 Enter 继续..."
done
