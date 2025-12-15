#!/bin/bash

# ======= 颜色变量 =======
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

# ======= 检查系统架构（amd64 / arm64） =======
check_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64) ARCH_TAG="x86_64-unknown-linux-gnu" ;;
        aarch64 | arm64) ARCH_TAG="aarch64-unknown-linux-gnu" ;;
        *)
            echo -e "${RED}不支持的 CPU 架构：$arch${RESET}"
            exit 1
        ;;
    esac
}

# ======= 获取 GitHub 最新版本号 =======
get_latest_version() {
    LATEST_VER=$(curl -s https://api.github.com/repos/cfal/shoes/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        echo -e "${RED}无法获取最新版 Shoes！${RESET}"
        exit 1
    fi
}

# ======= 安装 Shoes =======
install_shoes() {
    echo -e "${CYAN}开始安装 Shoes...${RESET}"

    check_arch
    get_latest_version

    echo -e "${GREEN}检测到架构: ${YELLOW}${ARCH_TAG}${RESET}"
    echo -e "${GREEN}检测到 Shoes 最新版本: ${YELLOW}${LATEST_VER}${RESET}"

    URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/shoes-${ARCH_TAG}.tar.gz"

    mkdir -p /tmp/shoesdl
    cd /tmp/shoesdl

    echo -e "${CYAN}下载 Shoes 中...${RESET}"
    wget -O shoes.tar.gz "$URL"

    echo -e "${CYAN}解压 Shoes...${RESET}"
    tar -xzf shoes.tar.gz
    mv shoes /usr/local/bin/
    chmod +x /usr/local/bin/shoes

    # ======= 生成配置目录 =======
    mkdir -p $SHOES_CONF_DIR

    # ======= 自动生成参数 =======
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHID=$(openssl rand -hex 8)
    KEYPAIR=$(shoes generate-reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep PublicKey | awk '{print $2}')

    PORT=$(shuf -i 20000-60000 -n 1)
    SNI="www.ua.edu"

cat > $SHOES_CONF_FILE <<EOF
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

    # ======= systemd 服务 =======
cat > /etc/systemd/system/shoes.service <<EOF
[Unit]
Description=Shoes Proxy Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/shoes /etc/shoes/config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shoes
    systemctl restart shoes

    # ======= 获取 IP 并生成客户端链接 =======
    HOST_IP=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F= '{print $2}')
    COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)

cat > $SHOES_LINK_FILE <<EOF
vless://${UUID}@${HOST_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHID}&type=tcp#${COUNTRY}
EOF

    echo -e "${GREEN}Shoes 安装完成！${RESET}"
    echo -e "连接链接：${YELLOW}"
    cat $SHOES_LINK_FILE
    echo -e "${RESET}"
}

# ======= 卸载 Shoes =======
uninstall_shoes() {
    systemctl stop shoes
    systemctl disable shoes
    rm -f /etc/systemd/system/shoes.service
    rm -rf $SHOES_CONF_DIR
    rm -f /usr/local/bin/shoes

    systemctl daemon-reload

    echo -e "${GREEN}Shoes 已彻底卸载${RESET}"
}

# ======= 状态检查 =======
check_shoes_installed() {
    if command -v shoes &>/dev/null; then return 0; else return 1; fi
}

check_shoes_running() {
    if systemctl is-active --quiet shoes; then return 0; else return 1; fi
}

# ======= 显示菜单 =======
show_menu() {
    clear
    echo -e "${GREEN}====== Shoes 管理工具 ======${RESET}"

    check_shoes_installed
    installed=$?

    check_shoes_running
    running=$?

    echo -e "安装状态: $( [[ $installed -eq 0 ]] && echo -e \"${GREEN}已安装${RESET}\" || echo -e \"${RED}未安装${RESET}\" )"
    echo -e "运行状态: $( [[ $running -eq 0 ]] && echo -e \"${GREEN}运行中${RESET}\" || echo -e \"${RED}未运行${RESET}\" )"

    echo ""
    echo "1. 安装 Shoes 服务"
    echo "2. 卸载 Shoes 服务"
    echo "3. 启动 Shoes 服务"
    echo "4. 停止 Shoes 服务"
    echo "5. 重启 Shoes 服务"
    echo "6. 查看 Shoes 配置"
    echo "7. 查看 Shoes 日志"
    echo "0. 退出"
    echo ""

    read -p "请输入编号: " choice
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
        6) cat $SHOES_CONF_FILE ;;
        7) journalctl -u shoes -f ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    read -p "按 Enter 继续..."
done
