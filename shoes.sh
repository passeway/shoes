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

# ======= 获取 glibc 版本 =======
get_glibc_version() {
    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    echo -e "${GREEN}系统 glibc 版本：${YELLOW}${GLIBC_VERSION}${RESET}"

    # glibc 数字部分提取
    GLIBC_MAJOR=$(echo "$GLIBC_VERSION" | cut -d. -f1)
    GLIBC_MINOR=$(echo "$GLIBC_VERSION" | cut -d. -f2)
}

# ======= CPU 架构检测 =======
check_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            GNU_FILE="shoes-x86_64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-x86_64-unknown-linux-musl.tar.gz"
            ;;
        aarch64|arm64)
            GNU_FILE="shoes-aarch64-unknown-linux-gnu.tar.gz"
            MUSL_FILE="shoes-aarch64-unknown-linux-musl.tar.gz"
            ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: $arch${RESET}"
            exit 1
            ;;
    esac
}

# ======= 获取最新 Shoes 版本 =======
get_latest_version() {
    LATEST_VER=$(curl -s https://api.github.com/repos/cfal/shoes/releases/latest | \
        grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        echo -e "${RED}无法获取 Shoes 最新版本！${RESET}"
        exit 1
    fi
}

# ======= 测试 Shoes 是否可运行（不使用 --version） =======
test_shoes_binary() {
    if ${SHOES_BIN} generate-reality-keypair >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ======= 自动选择 GNU/MUSL 并下载 =======
download_shoes() {
    get_glibc_version
    check_arch
    get_latest_version

    echo -e "${GREEN}Shoes 最新版本：${YELLOW}v${LATEST_VER}${RESET}"

    # 判断 glibc 是否小于 2.38
    if (( GLIBC_MAJOR < 2 )) || (( GLIBC_MAJOR == 2 && GLIBC_MINOR < 38 )); then
        echo -e "${YELLOW}你的 glibc 版本低于 2.38，无法运行 GNU 版本！${RESET}"
        echo -e "${CYAN}将直接下载 MUSL 静态版本…${RESET}"

        DOWNLOAD_FILE=${MUSL_FILE}
        DOWNLOAD_TYPE="MUSL"
    else
        echo -e "${GREEN}你的系统支持 Shoes GNU 版本，将优先尝试 GNU…${RESET}"

        DOWNLOAD_FILE=${GNU_FILE}
        DOWNLOAD_TYPE="GNU"
    fi

    mkdir -p /tmp/shoesdl
    cd /tmp/shoesdl

    DOWNLOAD_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${DOWNLOAD_FILE}"

    echo -e "${CYAN}下载 ${DOWNLOAD_TYPE} 版本: ${YELLOW}${DOWNLOAD_URL}${RESET}"
    wget -O shoes.tar.gz "$DOWNLOAD_URL" || {
        echo -e "${RED}${DOWNLOAD_TYPE} 下载失败！${RESET}"

        # GNU 失败 → 尝试 MUSL
        if [[ "$DOWNLOAD_TYPE" == "GNU" ]]; then
            echo -e "${YELLOW}尝试改为下载 MUSL 版本...${RESET}"
            DOWNLOAD_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
            wget -O shoes.tar.gz "$DOWNLOAD_URL" || {
                echo -e "${RED}MUSL 版本也无法下载，安装失败！${RESET}"
                exit 1
            }
        else
            exit 1
        fi
    }

    tar -xzf shoes.tar.gz
    mv shoes ${SHOES_BIN}
    chmod +x ${SHOES_BIN}

    # 测试运行
    if test_shoes_binary; then
        echo -e "${GREEN}Shoes (${DOWNLOAD_TYPE}) 可正常运行！${RESET}"
    else
        # GNU 失败 → fallback
        if [[ "$DOWNLOAD_TYPE" == "GNU" ]]; then
            echo -e "${YELLOW}GNU 无法运行，自动切换 MUSL…${RESET}"

            DOWNLOAD_URL="https://github.com/cfal/shoes/releases/download/v${LATEST_VER}/${MUSL_FILE}"
            wget -O shoes.tar.gz "$DOWNLOAD_URL"
            tar -xzf shoes.tar.gz
            mv shoes ${SHOES_BIN}
            chmod +x ${SHOES_BIN}

            if test_shoes_binary; then
                echo -e "${GREEN}MUSL 版本运行成功！${RESET}"
            else
                echo -e "${RED}MUSL 版本也无法运行，系统无法支持 Shoes！${RESET}"
                exit 1
            fi
        else
            echo -e "${RED}MUSL 版本无法运行，系统不支持 Shoes！${RESET}"
            exit 1
        fi
    fi
}


# ======= 安装 Shoes =======
install_shoes() {
    echo -e "${CYAN}开始安装 Shoes...${RESET}"

    get_glibc_version
    check_arch
    get_latest_version
    download_shoes
    test_shoes_binary

    mkdir -p ${SHOES_CONF_DIR}

    # 生成 Reality 信息
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHID=$(openssl rand -hex 8)
    KEYPAIR=$(shoes generate-reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep PrivateKey | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep PublicKey | awk '{print $2}')

    PORT=$(shuf -i 20000-60000 -n 1)
    SNI="www.ua.edu"

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
