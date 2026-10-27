# Xray Manager

面向 Debian/Ubuntu 的中文交互式 Xray 部署与管理工具。单文件 Bash 入口，内嵌 Python 标准库后端。

当前版本：`0.1.1`。

## 功能

- 默认部署 **VLESS + XHTTP + REALITY**，TCP 443，`flow` 留空，无需自有域名或证书。
- 启动检查系统、架构、公网 IP、端口、已有部署及服务状态。
- 核心升级与管理脚本更新分开确认，支持指定核心版本。
- 添加 **RAW + REALITY + Vision** 备用入口，使用 `xtls-rprx-vision`。
- Cloudflare 扩展向导：域名/DNS 检查、证书签发、自动续期和 Nginx SNI 分流。
- 按用户分配 UUID 和入口权限，导出分享链接及客户端 JSON。
- 配置变更前备份，失败恢复，中断后继续恢复流程。

## 运行要求

- Debian/Ubuntu、systemd、x86_64 或 ARM64；建议 Debian 12+、Ubuntu 22.04+。
- Python 3.9+，root 或 sudo 权限，以及交互式 SSH 终端。
- 能访问 GitHub、发行版软件源和所选 REALITY 目标；CDN 扩展还需要自己的 Cloudflare 域名。
- 对外服务端口未被其他程序占用，并已在云平台安全组放行。

不自动接管其他安装器、面板或未知 Nginx 管理的服务。Nginx、Certbot 和 Cloudflare DNS 插件仅在启用 CDN 扩展并确认后安装。

## 安装

先准备 `curl` 和 CA 证书，再在 VPS 的交互终端执行：

```bash
(
  set -e
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT
  curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    https://raw.githubusercontent.com/amjunliang/config/main/script/xray-install.sh \
    -o "$installer"
  if [ "$(id -u)" -eq 0 ]; then
    bash "$installer"
  else
    sudo bash "$installer"
  fi
)
```

也可以下载本仓库，在 VPS 上运行 `sudo bash script/xray-install.sh`。菜单需要终端，不支持 `curl | bash`。

首次部署成功后使用固定命令：

```bash
sudo xray-manager          # 打开管理菜单
sudo xray-manager --status # 只读查看状态
xray-manager --help        # 查看帮助
```

root 用户可省略 `sudo`。向导中输入 `q` 返回菜单；执行变更必须明确输入 `yes`。仅查看状态不会安装依赖。

## 管理菜单

| 菜单 | 操作 |
| --- | --- |
| 1 安装 / 检查 | 安装主入口；已有部署时保留版本和凭据，确认后检查或启动服务 |
| 2 升级核心 | 查看 Latest、发布说明或指定版本，校验下载后切换，失败回退 |
| 3 扩展接入 | 新增 Vision 入口，或开始/继续 Cloudflare 向导 |
| 4 用户 / 导出 | 新增用户、选择入口授权、删除用户、导出连接 |
| 5 修改配置 | 公网地址、REALITY 目标、入口端口、移除可选入口 |
| 6 备份 / 回退 | 创建快照，或恢复到历史部署状态 |
| 7 日志 / 诊断 | 服务日志、配置检查、完整代理连接测试、证书续期演练 |
| 8 更新脚本 | 从仓库固定提交更新管理脚本，或回退上一版脚本 |

重复运行不会重新安装、轮换 UUID/密钥或自动升级。修改配置会重启相关服务，现有连接可能短暂中断。改变地址、端口或 REALITY 目标后，受影响的客户端需要重新导入。

管理脚本更新与核心升级相互独立。更新脚本时显示明确的来源提交，经确认后替换，下次启动生效。未知状态格式会被拒绝，不会自动清空数据。

## 扩展入口

### Vision

默认建议 TCP 2443，也可选择其他空闲端口。选择授权用户后生成独立连接，原 XHTTP 的公网地址、端口及凭据保持不变。

### Cloudflare CDN

使用专用子域名，向导按以下顺序操作：

1. 填写域名，保存进度。
2. 按提示设置 A/AAAA、橙云代理、Full (strict)、gRPC 和 HTTP/2；脚本检测公开解析。
3. 在 VPS 本地隐藏输入仅授权目标域名区域 DNS 编辑的 API Token。
4. 确认安装 Nginx/stream、Certbot 和 DNS 插件，并向 CA 提交邮箱、同意服务条款。
5. 通过 DNS 验证签发证书，并演练续期。
6. 选择授权用户，确认切换，分别测试原节点和新增 CDN 节点。

后台 DNS/TLS/gRPC 设置由用户完成；DNS Token 不用于修改这些区域设置。没有公网 IPv6 时不要添加 AAAA；避免 Access 登录或交互式挑战拦截代理路径。Token 仅保存在服务器 root 专用文件中，用于 DNS 验证和续期。

默认拓扑：

```text
公网 443 → Nginx SNI 分流
           ├─ REALITY 目标域名 → 127.0.0.1:1443 → 原 XHTTP + REALITY
           └─ 自有 CDN 域名  → 127.0.0.1:1444 → Nginx TLS / HTTP2
                                                  → 127.0.0.1:10080 → XHTTP

Vision → 独立公网端口，默认 2443
```

内部端口可在向导中调整，只监听回环地址。原主入口若不是 443，则保留原端口，CDN 单独使用 443。CDN 客户端使用 **XHTTP + TLS / HTTP2 / stream-up**，`flow` 留空。

扩展后原 REALITY 客户端的公网连接参数保持不变。更换 CDN 域名或修改启用 CDN 后的主入口端口，需要先从菜单移除 CDN，再重新引导。

证书续期与部署变更共用一把变更锁，避免重载半更新的配置；停留在主菜单不会阻塞续期。续期成功后先检查 Nginx 配置再重载；部署占用锁时跳过本次续期，并由后续定时检查重试。

## 数据与权限

| 路径 | 用途 |
| --- | --- |
| `/usr/local/sbin/xray-manager` | 本地管理命令 |
| `/usr/local/lib/xray-manager/versions/` | 核心版本文件，`current` 指向生效版本 |
| `/etc/xray-manager/` | 核心、Nginx 配置和客户端导出 |
| `/var/lib/xray-manager/state.json` | 入口、用户和凭据，root 读写 |
| `/var/lib/xray-manager/backups/` | 部署快照，包含敏感配置 |
| `/var/lib/xray-manager/transaction.json` | 中断恢复记录 |
| `/var/lib/xray-manager/cdn-draft.json` | CDN 向导进度，不存放 Token 明文 |
| `/var/lib/xray-manager/credentials/` | root 专用 DNS Token 文件 |
| `/var/lib/xray-manager/acme/` | 独立 ACME 配置、证书和续期记录 |
| `/var/lib/xray-manager/script-backups/` | 管理脚本历史版本 |
| `/var/cache/xray-manager/` | Nginx 工作目录 |

Xray 使用专用非登录账户。配置目录显式设为 `750`，核心配置为 `640`，状态和连接凭据为 `600`；不复用未知同名用户或共享组。Nginx 主进程和证书续期任务需要 root。默认关闭访问日志。

健康检查使用临时、仅监听回环地址且需要随机密码的 SOCKS 入口；密码通过标准输入传给 curl，不写入进程启动参数。

核心从官方 Release 下载并校验 SHA-256，不接受缺少官方摘要的旧发布。配置、核心或受管理文件发生脚本外修改时停止变更，避免覆盖。

## 备份与恢复

配置先在暂存区生成并校验，变更前保存快照。服务停止失败时不删除配置；执行或回退失败时保留恢复记录，下次启动必须先完成恢复。

回退包含本脚本管理的核心、配置、入口和服务状态；不撤销已安装依赖、已签发证书或 Cloudflare 后台设置。旧核心、证书和凭据保留用于恢复，不自动清理。回退历史用户快照可能使已删除的旧 UUID 恢复有效。

UFW 已启用时只添加必要端口规则，不启用/清空防火墙，不修改 SSH。失败清理只删除本次事务标记的规则；清理失败保留恢复记录。移除入口、改端口和手动回退不会主动删除历史已提交规则，可按最终监听端口自行清理。云安全组需单独配置。

## 测试

测试不要求 root，不修改系统服务，不下载程序。默认使用模拟系统操作；真实核心校验需要显式提供可信的本机 Xray 可执行文件：

```bash
bash -n script/xray-install.sh
python3 script/test_xray_manager.py
XRAY_TEST_CORE=/path/to/trusted/xray python3 script/test_xray_manager.py
```

覆盖权限与账户隔离、重复运行、升级失败、事务恢复、防火墙回退、参数校验、分享链接、终端输入及移动后的自更新路径。

使用匹配的 Nginx 可执行文件与 stream 动态模块，还可以运行真实代理集成测试：

```bash
XRAY_TEST_CORE=/path/to/trusted/xray \
NGINX_TEST_BINARY=/path/to/nginx \
NGINX_TEST_MODULE=/path/to/ngx_stream_module.so \
python3 script/test_proxy_integration.py
```

集成测试只监听本机回环高端口，使用临时自签名证书和配置；需要 OpenSSL，以及访问测试目标的出站网络，不修改系统服务。

### 验证范围

已在 macOS ARM64 使用官方 Xray v26.10.21 检查配置，并使用官方 Nginx 1.24.0 源码构建的测试程序验证 SNI 分流：原 XHTTP + REALITY、独立 Vision、带证书校验的 XHTTP + TLS 均可代理访问 HTTPS；错误 UUID 和不受信的 TLS 证书被拒绝。Linux 安装流程使用模拟回归测试。

以下仍需要真实环境验收：Debian/Ubuntu 的 apt/systemd/UFW 和重启恢复，Cloudflare DNS、真实证书签发及自动续期、CDN 全链路，以及用户实际网络的稳定性。自动测试不代表这些项目已经验收。

## 参考

- [Xray Releases](https://github.com/XTLS/Xray-core/releases)
- [XHTTP](https://github.com/XTLS/Xray-core/discussions/4113)
- [VLESS / Vision](https://xtls.github.io/config/inbounds/vless.html)
- [Cloudflare gRPC](https://developers.cloudflare.com/network/grpc-connections/)
- [Nginx SNI 预读](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html)
- [Certbot Cloudflare DNS 插件](https://certbot-dns-cloudflare.readthedocs.io/en/stable/)
