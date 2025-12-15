#!/bin/bash

# ======= 颜色代码 =======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONF_DIR="/etc/shoes"
SHOES_CONF_FILE="${SHOES_CONF_DIR}/config.yaml"
SHOES_LINK_FILE="${SHOES_CONF_DIR}/config.txt"

# ======= 检查 root 权限 =======
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}必须使用 root 权限运行此脚本！${RESET}"
    exit 1
fi

# ======= CPU 架构检测 =======
check_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            GNU_FILE="shoes-x86_64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-x86_64-unknown-linux-musl.tar.gz"
            ;;
        aarch64 | arm64)
            GNU_FILE="shoes-aarch64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-aarch64-unknown-linux-musl.tar.gz"
            ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: $arch${RESET}"
            exit 1
            ;;
    esac
}

# ======= 获取 Shoes 最新版本 =======
get_latest_version() {
    LATEST_VER=$(curl -s https://api.github.com/repos/cfal/shoes/releases/latest | \
        grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        echo -e "${RED}无法获取 Shoes 最新版本！${RESET}"
        exit 1
    fi
}

# ======= 下载并自动选择 GNU / MUSL 版本 =======
download_and_select_shoes() {
    echo -e "${CYAN}开始获取 Shoes 最新版本...${RESET}"
    get_latest_version
    check_arch

    echo -e "${GREEN}最新版本: ${YELLOW}v${LATEST_VER}${RESET}"
    echo -e "${GREEN}CPU 架构: ${YELLOW}$(uname -m)${RESET}"

    mkdir -p /tmp/shoesdl
    cd /tmp/shoesdl

    # ==== ① 优先下载 GNU 版本 ====
    echo -e "${CYAN}尝试下载 GNU 版本...${RESET}"
    GNU_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${GNU_FILE}"

    if wget -O shoes.tar.gz "$GNU_URL" 2>/dev/null; then
        tar -xzf shoes.tar.gz
        mv shoes ${SHOES_BIN}
        chmod +x ${SHOES_BIN}

        echo -e "${CYAN}测试 GNU 版本是否能运行...${RESET}"

        if ${SHOES_BIN} --version >/dev/null 2>&1; then
            echo -e "${GREEN}✓ GNU 版本运行正常（已选择 GNU）${RESET}"
            return 0
        fi

        echo -e "${YELLOW}GNU 版本无法运行，自动切换 MUSL 版本...${RESET}"
    else
        echo -e "${RED}GNU 下载失败，切换 MUSL...${RESET}"
    fi

    # ==== ② 下载 MUSL 版本 ====
    echo -e "${CYAN}开始下载 MUSL 版本...${RESET}"
    MUSL_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"

    if wget -O shoes.tar.gz "$MUSL_URL"; then
        tar -xzf shoes.tar.gz
        mv shoes ${SHOES_BIN}
        chmod +x ${SHOES_BIN}

        echo -e "${CYAN}测试 MUSL 版本是否能运行...${RESET}"

        if ${SHOES_BIN} --version >/dev/null 2>&1; then
            echo -e "${GREEN}✓ MUSL 版本运行正常（已选择 MUSL）${RESET}"
            return 0
        fi

        echo -e "${RED}MUSL 版本仍无法运行！系统无法支持 Shoes${RESET}"
        exit 1
    else
        echo -e "${RED}MUSL 下载失败！无法安装 Shoes${RESET}"
        exit 1
    fi
}

# ======= 安装 Shoes =======
install_shoes() {
    echo -e "${CYAN}开始安装 Shoes...${RESET}"

    download_and_select_shoes

    mkdir -p ${SHOES_CONF_DIR}

    # 生成 Reality 信息
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHID=$(openssl rand -hex 8)
    KEYPAIR=$(${SHOES_BIN} generate-reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep PublicKey | awk '{print $2}')

    PORT=$(shuf -i 20000-60000 -n 1)
    SNI="www.yahoo.com"

cat > ${SHOES_CONF_FILE} <<EOF
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

# ======= 写入 systemd 服务 =======
cat > /etc/systemd/system/shoes.service <<EOF
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

cat > ${SHOES_LINK_FILE} <<EOF
vless://${UUID}@${HOST_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=random&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${COUNTRY}
EOF

    echo -e "${GREEN}Shoes 安装完成！${RESET}"
    echo -e "${YELLOW}你的连接链接：${RESET}"
    cat ${SHOES_LINK_FILE}
}

# ======= 卸载 Shoes =======
uninstall_shoes() {
    systemctl stop shoes
    systemctl disable shoes
    rm -f /etc/systemd/system/shoes.service
    rm -rf ${SHOES_CONF_DIR}
    rm -f ${SHOES_BIN}
    systemctl daemon-reload

    echo -e "${GREEN}Shoes 已卸载${RESET}"
}

# ======= 状态检测 =======
check_installed() { command -v shoes >/dev/null 2>&1; }
check_running() { systemctl is-active --quiet shoes; }

# ======= 菜单 =======
show_menu() {
    clear
    echo -e "${GREEN}====== Shoes 管理工具 ======${RESET}"

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

# ======= 主循环 =======
while true; do
    show_menu
    case "$choice" in
        1) install_shoes ;;
        2) uninstall_shoes ;;
        3) systemctl start shoes ;;
        4) systemctl stop shoes ;;
        5) systemctl restart shoes ;;
        6) cat ${SHOES_CONF_FILE} ;;
        7) journalctl -u shoes -f ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
    read -p "按 Enter 继续..."
done
