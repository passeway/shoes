<div align="center">

# Shoes

**Rust 驱动 · 多协议共用内核 · 灵活转发**

[Shoes](https://github.com/cfal/shoes) 是使用 **Rust** 编写的高性能多协议代理内核。\
一个服务承载多种接入方式，结合灵活的路由与配置热重载，让部署和管理更集中。

![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu%20%7C%20Alpine-2563eb?style=flat-square)
![Architecture](https://img.shields.io/badge/架构-x86__64%20%7C%20ARM64-0f766e?style=flat-square)
![Protocols](https://img.shields.io/badge/协议-VLESS%20%7C%20AnyTLS%20%7C%20SS2022-7c3aed?style=flat-square)

</div>

## 为什么选择 Shoes

### 一个内核，三种接入

**VLESS Reality Vision、AnyTLS、Shadowsocks 2022 可以在同一个 Shoes 进程中运行。** 每个节点使用独立端口，三个协议统一使用 `config.yaml`，共用一套内核、日志和服务管理，方便按客户端与使用场景选择协议。

### Rust 实现，关注传输效率

Shoes 使用 Rust 构建原生可执行程序，将性能与内存安全作为实现基础。支持 **Reality + XTLS Vision**；Vision 可在识别到符合条件的 TLS 流量后进入直通模式，优化 TLS 套 TLS 场景的传输路径。

### 配置热重载，调整更方便

内核默认监听配置变化并重新加载，支持将多个配置一起载入。调整规则或维护多个接入配置时，可减少手动重启操作。

### 路由与转发，按需扩展

| 内核能力 | 可以做什么 |
| --- | --- |
| IP / CIDR / 域名规则 | 根据目标地址选择放行或转发方式 |
| TLS SNI 分流 | 根据客户端请求的域名匹配服务配置 |
| 上游代理链与负载均衡 | 按需构建多级转发，并分配上游连接 |
| TCP / QUIC 传输 | 为合适的协议与部署场景选择传输方式 |

以上是 Shoes 内核可按需配置的能力。本仓库默认提供三个接入节点，更多组合方式可查阅[上游配置文档](https://github.com/cfal/shoes/blob/v0.3.2/CONFIG.md)。

### GNU / MUSL，兼顾不同 Linux 环境

Shoes 提供 GNU 与 MUSL 预编译内核。脚本根据系统选择可运行的版本，覆盖 **Debian、Ubuntu、Alpine**，支持 **x86_64 与 ARM64**，方便在不同 VPS 上部署。

## 本项目让部署更简单

- **一键安装三个协议**：自动处理依赖、密钥与端口，安装后直接输出分享链接。
- **集中管理服务**：菜单完成启停、重启、日志查看与内核更新。
- **保留已有节点**：更新保留端口、凭据和启停状态；重复安装保留已有配置。
- **检查后再替换**：下载摘要可用时进行校验，新内核通过运行与配置检查后再替换；启动失败会显示日志。

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

## 日常管理

| 选项 | 功能 |
| --- | --- |
| `1` | 安装三个协议；已有安装保留原有配置和凭据 |
| `2` | 确认后卸载服务 |
| `3` / `4` / `5` | 启动 / 停止 / 重启 |
| `6` | 查看全部分享链接 |
| `7` | 查看日志，按 `Ctrl+C` 返回菜单 |
| `8` | 更新内核，保留现有配置及服务启停状态 |
| `0` | 退出 |

安装后选择 `6` 查看全部分享链接。三个协议的服务端配置统一保存在 `/etc/shoes/config.yaml`，方便集中查看与维护。

## 客户端连接

复制安装后显示的链接，导入支持对应协议的客户端。使用 v2rayN 导入 AnyTLS 时，请确认节点启用了“允许不安全连接”，以使用脚本生成的自签名证书。

如果暂时无法连接，可先通过菜单检查运行状态和日志，再核对端口放行情况。公网 IPv4 自动获取失败时，脚本会提示手动输入，不会输出地址为空的节点。

---

<div align="center">

[上游项目](https://github.com/cfal/shoes) · [版本发布](https://github.com/cfal/shoes/releases) · [反馈问题](https://github.com/passeway/shoes/issues)

</div>
