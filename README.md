<div align="center">

# Shoes

**轻量部署 · 三协议接入 · 简洁管理**

基于 [cfal/shoes](https://github.com/cfal/shoes) 的 Linux 服务管理脚本。\
一键部署 VLESS Reality Vision、AnyTLS 与 Shadowsocks 2022，让安装、更新和日常维护更直接。

![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu%20%7C%20Alpine-2563eb?style=flat-square)
![Architecture](https://img.shields.io/badge/架构-x86__64%20%7C%20ARM64-0f766e?style=flat-square)
![Protocols](https://img.shields.io/badge/协议-VLESS%20%7C%20AnyTLS%20%7C%20SS2022-7c3aed?style=flat-square)

</div>

## 快速开始

使用 **root** 用户执行：

```bash
bash <(curl -fsSL shoes-black-one.vercel.app)
```

精简系统如未安装 Bash 或 curl，先执行对应命令：

```bash
# Debian / Ubuntu
apt-get update && apt-get install -y bash curl ca-certificates

# Alpine
apk add --no-cache bash curl ca-certificates
```

选择 `1` 完成安装，终端将显示三个节点的分享链接。请在云平台安全组及系统防火墙中放行提示的 **三个 TCP 端口**。

## 协议与平台

| 接入协议 | 部署方式 |
| --- | --- |
| VLESS | Reality + XTLS Vision |
| AnyTLS | TLS，自签名证书；分享链接包含 `insecure=1` |
| SS2022-128 | `2022-blake3-aes-128-gcm`，独立的 16 字节随机密钥 |

Shadowsocks 分享链接采用 [SIP002](https://shadowsocks.org/doc/sip002.html) 格式，可导入支持 SS2022 的客户端。Shoes 的 Shadowsocks UDP 使用 **UDP over TCP（UoT）**，需要客户端支持并启用该模式；不是原生 Shadowsocks UDP 监听。

| 系统 | 服务管理 | 架构 |
| --- | --- | --- |
| Debian / Ubuntu | systemd | x86_64 / ARM64 |
| Alpine | OpenRC | x86_64 / ARM64 |

需要正常运行对应服务管理器的 Linux 环境。脚本自动安装所需依赖；Debian / Ubuntu 优先尝试 GNU 内核，不兼容时使用 MUSL，Alpine 使用 MUSL。

本脚本默认部署上表中的三个协议，Shoes 内核的更多能力可查阅[上游文档](https://github.com/cfal/shoes#readme)。

## 日常管理

| 选项 | 功能 |
| --- | --- |
| `1` | 安装三个协议；已有安装自动补齐 SS2022-128，保留原有端口和凭据 |
| `2` | 确认后卸载服务 |
| `3` / `4` / `5` | 启动 / 停止 / 重启 |
| `6` | 查看分享链接，并修正旧 AnyTLS 链接参数 |
| `7` | 查看日志，按 `Ctrl+C` 返回菜单 |
| `8` | 更新内核，保留现有配置及服务启停状态 |
| `0` | 退出 |

更新前会检查下载文件、内核运行能力及现有配置。已运行的服务在更新后重启；原本停止的服务继续保持停止。启动失败时会显示日志，便于定位问题。

已有安装重新运行脚本后，选择 `1` 补齐 SS2022-128，再选择 `6` 查看全部分享链接。再次执行安装会保留已有 SS 端口和密钥。

## 客户端连接

复制安装后显示的链接，导入支持对应协议的客户端。使用 v2rayN 导入 AnyTLS 时，请确认节点启用了“允许不安全连接”，以使用脚本生成的自签名证书。

如果暂时无法连接，可先通过菜单检查运行状态和日志，再核对端口放行情况。公网 IPv4 自动获取失败时，脚本会提示手动输入，不会输出地址为空的节点。

---

<div align="center">

[上游项目](https://github.com/cfal/shoes) · [版本发布](https://github.com/cfal/shoes/releases) · [反馈问题](https://github.com/passeway/shoes/issues)

</div>
