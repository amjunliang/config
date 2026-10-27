# Config

本目录是 `amjunliang/config` 的本地 Git 仓库，保留原有 `shadowrocket-custom-rules.module`，新增 Xray 交互管理脚本和说明。本地提交尚未推送，上传前需要用户确认。

## Xray 交互部署与管理

- 脚本：`xray-install.sh`，版本 `0.1.0`。
- 目标：运行 systemd 的 Debian/Ubuntu VPS，支持 x86_64、ARM64；需要 root/sudo、交互式 SSH 终端以及访问 GitHub/软件源的网络。
- 默认入口：VLESS + XHTTP + REALITY，TCP 443，`flow` 留空，不需要自有域名、证书或 CDN。
- 可选扩展：RAW + REALITY + Vision 备用入口，以及 Cloudflare 域名/TLS/CDN 完整向导。
- 发布状态：**本地待审阅，尚未上传 GitHub。**

这是 Bash 单文件入口，内嵌 Python 3 标准库后端；不安装 Python 第三方库。缺少 Python 时先确认是否安装；其他基础依赖缺失也会先提示确认。Nginx、Certbot 和 DNS 插件仅在选择 CDN 扩展并确认后安装。

## 如何执行

目前可以把本地脚本上传到 VPS 后执行，例如：

```bash
# 在 Mac 上执行，将 VPS_IP 替换为服务器地址；也可以换成有 sudo 权限的 SSH 用户。
scp '/Users/majunliang/Workspace/Inbox/config/xray-install.sh' root@VPS_IP:/tmp/xray-install.sh

# 登录 VPS 后执行
sudo bash /tmp/xray-install.sh
```

首次部署成功后安装固定管理命令；日后使用：

```bash
sudo xray-manager
sudo xray-manager --status
```

只有 `--help` 可在 Mac 上直接运行。`--status` 和 `--check-state` 是只读操作，不安装依赖。交互输入 `q` 返回菜单；提交操作需要明确输入 `yes`。不要使用 `curl | bash`，菜单需要终端。

**以下 Raw URL 命令只在用户确认并完成仓库发布后可用，现在尚未发布：**

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/amjunliang/config/main/xray-install.sh -o /tmp/xray-install.sh && sudo bash /tmp/xray-install.sh
```

计划向公开仓库 `amjunliang/config` 的 `main` 分支新增稳定文件名 `xray-install.sh` 和说明。仅发布代码和说明，不发布服务器配置、UUID、密钥、Token、草稿或备份。远程分支、PR 和提交推送都须先获用户明确确认。

## 菜单与重复运行

| 菜单 | 行为 |
| --- | --- |
| 1 安装 / 检查 | 新服务器进入安装向导；已部署时保持版本和凭据，只在确认后检查、启动停服入口和测试连接 |
| 2 升级核心 | 展示当前版本、Latest 和发布说明；选择版本，校验官方 SHA-256 后切换；失败恢复原部署 |
| 3 扩展 | 添加 Vision 备用入口，或继续 Cloudflare 完整向导 |
| 4 用户 / 导出 | 用户使用独立 UUID；创建时选择入口授权；可删除用户、导出链接和客户端 JSON |
| 5 配置 | 修改公网地址、REALITY 目标、入口端口，或移除可选入口；明确提示客户端重导入影响 |
| 6 备份 / 回退 | 手动备份，或选择操作前快照恢复；回退前另存当前快照 |
| 7 诊断 | 系统与公网信息、近期服务日志、配置和完整代理连接测试、证书续期演练 |
| 8 管理脚本 | 从仓库明确提交更新脚本，或回退管理脚本；不隐式升级核心 |

重跑脚本不重装、不轮换 UUID/密钥、不自动升级。核心升级和管理脚本更新相互独立。核心下载从官方 Release 获取，缺少官方 SHA-256 摘要的旧发布会被拒绝，而不是跳过校验。

操作前检测受管理文件和核心摘要；手工修改这些文件会使后续变更停止，避免静默覆盖。不接管其他工具安装的 Xray、面板、sing-box 或未知 Nginx 配置。

修改配置会重启相关服务，可能造成短暂重连；不是无中断热更新。管理脚本更新后退出，下次运行生效。状态格式目前为 `schema=1`，未知格式会停止；不自动清空数据，也没有针对未来格式的臆测迁移。

## 首次安装向导

1. 检测系统、架构、IPv4/IPv6、端口和已有服务。
2. 确认客户端连接地址，默认建议自动检测到的 IPv4；检测失败时手工填写公网 IP 或直接解析到 VPS 的域名。这里的 REALITY 直连域名不能开启 CDN 代理。
3. 选择端口（默认 443）和 REALITY 目标（默认 `www.microsoft.com`）。检查目标的 TLS 1.3、HTTP/2 和证书；不满足时提示更换。
4. 展示版本、地址、端口和变更，确认后下载并校验官方核心。
5. 生成 UUID、X25519 密钥、Short ID、随机 XHTTP 路径；检查配置，创建专用非 root 核心服务。
6. 检查服务，并用临时 Xray 客户端经该入口代理访问 HTTPS；失败回退。
7. 导出 `vless://` 和客户端 JSON，提示云安全组需要放行的 TCP 端口。

客户端自测地址为 `https://www.gstatic.com/generate_204`。如果该测试地址、服务器出站或 DNS 不可用，即使端口已正常监听，操作也不会报告完整连接成功，会回退并显示原因。

## Vision 扩展

- 默认建议 TCP 2443；占用时提示重新选择。
- 为选定用户增加 RAW + REALITY + Vision 授权，设置 `flow=xtls-rprx-vision`。
- 现有 XHTTP 的公网地址、端口、UUID、密钥和路径保持不变。
- 主机防火墙和云安全组都需要允许该端口。切换客户端节点需使用新增的导入链接。

## Cloudflare 扩展向导

使用专用子域名，例如 `proxy.example.com`；需要能操作该域名的 Cloudflare 账户。REALITY 借用的目标域名和自己的 CDN 域名不能相同。

1. 输入子域名，保存草稿。
2. 按提示在 Cloudflare 建立 A/AAAA，指向 VPS 真正拥有的对应 IP，开启橙云；没有公网 IPv6 时不要填写 AAAA。
3. 配置 SSL/TLS **Full (strict)**、开启 gRPC 和 HTTP/2；避免 Access 登录或交互式挑战拦截代理路径。脚本检测公开解析是否落在 Cloudflare 的代理网段，再用实际代理连接验证回源；受限 DNS Token 不读取或修改区域 TLS/gRPC 设置，因此后台步骤仍需用户完成。
4. 输入邮箱和限制到目标域名区域的 DNS 编辑 Token。Token 在 VPS 终端隐藏输入，保存为 root 专用文件；不要把 Token 发到聊天中。
5. 确认安装 Nginx/stream、Certbot、Cloudflare DNS 插件，以及向 CA 提交邮箱并同意服务条款。使用 DNS 验证自动创建和清理 TXT，不需要临时占用 80。
6. 申请或复用证书，进行 ACME 测试环境的续期演练。
7. 选择新入口授权用户，确认切换，再检查所有原入口和经过 Cloudflare 的真实连接。失败恢复原本地部署，草稿保留，可再次进入向导。
8. 配置每日续期计时器；续期成功后先验证 Nginx 配置，再重载前端。

默认拓扑：

```text
原 XHTTP + REALITY 客户端 ─── IP:443 ─┐
                                   ├─ Nginx SNI 分流（不终止 REALITY）
CDN 客户端 ─ Cloudflare ─ 域名:443 ──┘       │
                         目标站点 SNI ────────┤→ 127.0.0.1:1443，原 XHTTP + REALITY
                         自有域名 SNI ────────┘→ 127.0.0.1:1444，Nginx TLS/HTTP2
                                                 → 127.0.0.1:10080，XHTTP

Vision 备用入口：独立公网端口，默认 2443
```

内部端口可在向导中调整；全部只监听回环地址，不需要在安全组放行。如果原 XHTTP 原本使用其他公网端口，则保留原端口，CDN 单独使用公网 443。

新增 CDN 客户端采用 **XHTTP + TLS**、HTTP/2、`stream-up`，不设置 Vision flow。原 REALITY 节点的公网连接参数保持不变，但服务会在扩展切换时短暂重连。

首版在检测到非本脚本安装的 Nginx 或运行中的系统 `nginx.service` 时停止，避免接管已有网站。CDN 启用后修改主入口端口，需要先从菜单移除 CDN 入口，再修改端口并重新运行 CDN 向导。更换 CDN 域名同样通过移除、重新引导完成。证书和 Token 不随移除入口自动删除，以便回退和恢复；自动续期任务会随 CDN 入口移除而停止。

## 数据、权限与回退

| 路径 | 用途 |
| --- | --- |
| `/usr/local/sbin/xray-manager` | 本地固定管理入口 |
| `/usr/local/lib/xray-manager/versions/` | 不同版本的核心；`current` 链接指向生效版本 |
| `/etc/xray-manager/` | 脚本管理的核心、Nginx 配置和导出连接 |
| `/var/lib/xray-manager/state.json` | 入口、授权用户和凭据，root 读写 |
| `/var/lib/xray-manager/backups/` | 操作前快照，包括敏感配置 |
| `/var/lib/xray-manager/transaction.json` | 中断恢复记录；成功后删除 |
| `/var/lib/xray-manager/cdn-draft.json` | CDN 向导进度，不包含 Token 明文 |
| `/var/lib/xray-manager/credentials/` | DNS Token 文件，root 专用 |
| `/var/lib/xray-manager/acme/` | 独立 ACME 配置、证书和续期记录 |
| `/var/lib/xray-manager/script-backups/` | 管理脚本历史版本 |
| `/var/cache/xray-manager/` | Nginx 工作目录，不存放凭据 |

状态、Token、导出连接使用受限权限。核心服务使用专用系统账户；Nginx 主进程和证书续期服务需要 root 权限。核心默认只记录 warning/error，不开启访问日志。

更新失败或 Ctrl+C 中断变更时尝试恢复。进程被强制终止或机器掉电时，下次运行检测事务记录，要求先恢复再继续其他操作。快照保留核心引用和服务状态；旧核心、证书及凭据文件保留用于恢复，不自动删除。

本地回退不撤销：已安装的依赖包、已签发的证书、用户在 Cloudflare 后台修改的 DNS/TLS/gRPC 设置。回退旧用户快照可能使已删除的旧 UUID 恢复有效，菜单会在确认前提示。

UFW 已启用时，仅为缺少规则的公网端口添加带本次事务唯一标记的规则；不启用 UFW、不清空规则、不修改 SSH。遇到相同端口的拒绝或来源限制规则时停止并提示人工检查；自动失败回退只删除本事务自己新增的规则。移除入口、改端口或手动回退时不主动删除旧的已提交防火墙规则，请根据最终监听端口自行清理；云安全组不由脚本修改。

## 2026-10-27 验证记录

测试环境为本机 macOS ARM64；真实测试核心来自官方 Xray v26.10.21，下载包已与官方 Release 的 SHA-256 摘要比对。

已验证：

- Bash 与内嵌 Python 语法、帮助入口。
- 真实核心接受 XHTTP/REALITY、Vision、CDN 回环服务端和各客户端配置。
- 本机实际运行 Xray 服务端和客户端：XHTTP + REALITY、Vision 均成功代理访问 HTTPS；错误 UUID 被拒绝。
- **21 项自动检查通过**，覆盖 flow 区分、回环监听边界、导入链接/JSON 一致性、IPv6 链接、非法域名/路径、未知状态版本、端口冲突、最后授权用户保护、菜单输入及隐藏输入恢复回显。
- 模拟系统操作验证：下载摘要错误拒绝、受管理文件漂移保护、首次安装失败恢复、变更失败恢复、核心切换失败恢复原版本链接、中断恢复、成功扩展保持凭据、重复运行不下载或轮换凭据、UFW 精确回退。

尚未完成真实验收：

- Debian/Ubuntu 上的 apt 安装、systemd 权限隔离、UFW 实际操作和重启恢复。
- Linux Nginx SNI 分流与已有 REALITY 入口的回归连接。
- 真实 Cloudflare DNS、ACME 签发/自动续期及 CDN 全链路。
- 用户实际网络到 VPS 的抗干扰和稳定性。

**本地验证不能代替以上 VPS 验收；正式部署时应保留另一个 SSH 会话，并按菜单中的诊断结果逐步验证。**

官方参考：

- [Xray Releases](https://github.com/XTLS/Xray-core/releases)
- [XHTTP](https://github.com/XTLS/Xray-core/discussions/4113)
- [VLESS / Vision 配置](https://xtls.github.io/config/inbounds/vless.html)
- [Cloudflare gRPC 要求](https://developers.cloudflare.com/network/grpc-connections/)
- [Nginx SNI 预读](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html)
- [Certbot Cloudflare DNS 插件](https://certbot-dns-cloudflare.readthedocs.io/en/stable/)
