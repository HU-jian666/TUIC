# Sing-box 多协议一键配置脚本

一个强大的 Sing-box 自动化部署工具，支持 SS/HY2/TUIC/VLESS Reality/AnyTLS Reality 协议自选配置和线路机 VLESS Reality 中转的完整解决方案。

---

## ✨ 主要特性

### 🚀 部署机功能

- ✅ **一键安装** - 自动配置 Sing-box 最新服务端
- ✅ **自动生成** - 自动生成密钥和配置文件，现实自选或默认 SNI
- ✅ **多系统支持** - 支持 Alpine, Debian, Ubuntu, CentOS, RHEL, Fedora 等操作系统
- ✅ **开机自启动** - 自动配置 Systemd / OpenRC 启动自启动，崩溃自动拉起服务端
- ✅ **连接 IP** - 自动获取公网 IP 或手动输入连接 IP/DDNS 域名并生成客户端链接
- ✅ **管理工具** - 输入 `sb` 指令进入管理界面查看节点链接、重置端口、服务端控制查看等功能

### 🔗 线路机功能

- ✅ **一键生成** - 从落地机直接生成线路机安装脚本
- ✅ **Reality 入口** - 自动部署 VLESS Reality 入口
- ✅ **利用端口** - 支持自动寻找空闲端口或手动指定
- ✅ **流量转发** - 自动转发流量至落地机 SS 节点
- ✅ **完整链接** - 生成可用的 VLESS Reality 客户端链接

---

## 🚀 一键安装 / Quick Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install.sh)
```

## 带参数安装 / With Parameters

```bash
# 直接安装指定协议（跳过选择菜单）
bash install.sh --protocol vless
bash install.sh --protocol ss
bash install.sh --protocol hy2
bash install.sh --protocol tuic
bash install.sh --protocol anytls

# 安装线路机中转
bash install.sh --relay

# 卸载
bash install.sh --uninstall
```

---

## 📋 协议列表

| 协议 | 标识 | 特点 |
|------|------|------|
| Shadowsocks 2022 | `ss` | 轻量高效，多路复用 |
| Hysteria2 | `hy2` | 基于 QUIC，弱网优化 |
| TUIC v5 | `tuic` | 低延迟 QUIC，BBR 拥塞控制 |
| VLESS Reality | `vless` | 无需域名，流量伪装 |
| AnyTLS Reality | `anytls` | 最新协议，Reality 伪装 |
| 线路机中转 | `relay` | VLESS Reality 入口转发 |

---

## 🛠 管理工具 / Management

安装完成后输入 `sb` 进入管理界面：

```
── Sing-box 管理界面 ──────────────────────────
状态 / Status: 运行中

1) 查看节点链接 / Show node links
2) 重启服务 / Restart service
3) 停止服务 / Stop service
4) 启动服务 / Start service
5) 查看日志 / View logs
6) 重置端口 / Reset port
7) 查看配置 / View config
0) 退出 / Exit
```

---

## ⚙️ 系统要求

- **系统**: Alpine / Debian / Ubuntu / CentOS / RHEL / Fedora
- **权限**: root
- **内存**: 64MB+（低内存自动创建 Swap）
- **网络**: 可访问 GitHub

---

## 📁 文件结构

```
.
├── install.sh      # 主安装脚本（含所有协议）
├── uninstall.sh    # 快速卸载
└── README.md
```

---

## 📱 客户端推荐

| 平台 | 客户端 |
|------|--------|
| Windows | [Hiddify](https://github.com/hiddify/hiddify-next) / [v2rayN](https://github.com/2dust/v2rayN) |
| Android | [Hiddify](https://github.com/hiddify/hiddify-next) / [v2rayNG](https://github.com/2dust/v2rayNG) |
| iOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) / [Sing-box](https://apps.apple.com/app/sing-box/id6451272673) |
| macOS | [Hiddify](https://github.com/hiddify/hiddify-next) |

---

*live free or die hard*
