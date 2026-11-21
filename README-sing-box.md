# sing-box 安全一键安装与管理

`sing-box-install.sh` 是自包含安装脚本，会安装官方 sing-box 核心和 `sb` 管理命令。目标为 Debian/Ubuntu、systemd、Python 3.8+，支持 amd64/arm64。

## 安装

```sh
sudo bash sing-box-install.sh
sudo bash sing-box-install.sh --port 443 --sni www.cloudflare.com
sudo bash sing-box-install.sh --version 1.14.4
sudo bash sing-box-install.sh --update
sudo bash sing-box-install.sh --status
sudo bash sing-box-install.sh --uninstall
```

首次安装会生成 VLESS Reality 入站，默认 TCP 8443。初始客户端参数保存在 `/etc/sing-box/client.txt`，仅 root 可读。安装器不会自动更改防火墙、SSH 或内核参数。

## ACME 证书签发与续期

```sh
sudo sb acme issue --domain vpn.example.com --email admin@example.com
# 或使用现有 Web 服务的 webroot：
sudo sb acme issue --domain vpn.example.com --email admin@example.com --webroot /var/www/html
sb acme status
sudo sb acme renew

sudo sb add trojan --port 443 --domain vpn.example.com --acme
sudo sb add hysteria2 --port 9443 --domain vpn.example.com --acme
```

默认用 Certbot standalone 做 HTTP-01 验证，需要公网 TCP/80 可达且签发/续期时端口空闲。若已有 Web 服务，可用 `--webroot`，但需确保该 Web 服务把 `/.well-known/acme-challenge/` 映射到指定目录。脚本安装续期部署钩子：证书更新后复制到 `/etc/sing-box/certs/`，设置 `root:sing-box` 与最小读取权限，校验配置后重启服务。不会打开防火墙端口。HTTP-01 不支持通配符证书；IDN 域名请先转为 punycode。

## 协议与管理命令

```sh
sb info                                      # 列出摘要，不显示密钥
sb add reality --port 10443 --server my.example.com
sb add ss --port 8388                       # Shadowsocks 2022
sb add socks --port 1080
sb add trojan --port 443 --domain vpn.example.com --acme
sb add vless-ws --port 10444 --domain vpn.example.com --acme --path /ws
sb gen reality --port 12443                 # 只生成配置草案
sb change reality-10443 --port 11443
sb change reality-11443 --sni cdn.example.com --rotate-key
sb change ss-8388 --method 2022-blake3-aes-256-gcm
sb url reality-11443 --server my.example.com
sb qr reality-11443 --server my.example.com # 系统需已有 qrencode
sb import ./xray.json                       # 预览后输入 IMPORT 确认
sb import ./v2ray.json
sb edit                                      # 编辑完整 JSON，校验后应用
sb del reality-11443                         # 交互确认
sb bbr                                        # 预览，不修改系统
sudo sb bbr --apply                          # 明确确认后持久启用 BBR
sb bin version                               # 直通 sing-box 核心命令
sb status
```

常见协议模板包括 VLESS Reality、VMess/VLESS TCP、VMess/VLESS/Trojan 的 WebSocket、HTTP、QUIC、HTTPUpgrade，以及 Shadowsocks、SOCKS、Trojan、AnyTLS、TUIC、Hysteria2。TLS 协议可以用已有证书路径，也可通过 `--acme` 选择本脚本管理的 ACME 证书。

Xray/V2Ray 导入器转换常见 VMess、VLESS、Trojan、Shadowsocks、SOCKS、HTTP 入站，以及 TCP/WS/HTTP/gRPC/HTTPUpgrade/QUIC 传输和 TLS/Reality。它只导入 `inbounds`，不迁移 outbounds、routing、DNS、sniffing 等全局行为。alterId 非零的 VMess、TCP 头伪装、WS 自定义 headers、KCP/mKCP、复杂回落和多证书 TLS 会明确拒绝自动转换；请在预览后使用 `sb edit` 手动处理，不会静默丢弃这些配置。

## 安全与稳定性

- 从 SagerNet 官方 GitHub Release 获取稳定版，并验证 Release API 的 SHA-256 digest；缺少校验值时停止安装。
- 使用独立系统账号运行；systemd 开启文件系统隔离、失败重启和最小 capability。只有监听 1024 以下端口时才授予绑定低端口所需权限。
- 配置修改使用文件锁、变更前备份、`sing-box check` 校验、原子替换；服务启动失败时恢复旧配置。
- 凭据由安全随机源生成；信息摘要隐藏密码；导入和删除需确认。
- 续期钩子只部署 Certbot 对应 lineage 的证书；替换失败时恢复上一组证书并重启旧配置。
- 卸载会移除程序、配置和服务单元，但保留 sing-box 系统用户/组，避免误删可能被复用的账户。

## 参考

- [233Boy sing-box 脚本介绍](https://233boy.com/sing-box/sing-box-script/)
- [sing-box 官方 GitHub Releases](https://github.com/SagerNet/sing-box/releases)
- [sing-box 官方入站文档](https://sing-box.sagernet.org/configuration/inbound/)
- [sing-box V2Ray Transport 文档](https://sing-box.sagernet.org/configuration/shared/v2ray-transport/)
- [sing-box TLS/Reality 文档](https://sing-box.sagernet.org/configuration/shared/tls/)
- [Certbot 官方用法与续期钩子文档](https://eff-certbot.readthedocs.io/en/stable/using.html)
