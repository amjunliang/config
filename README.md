# Config

个人网络配置与服务器管理工具集合。

| 内容 | 说明 |
| --- | --- |
| [Shadowrocket 规则](shadowrocket-custom-rules.module) | Claude、Cloudflare 验证、Tailscale、Apple 和 Google 等服务的路由规则 |
| [Xray Manager](script/README.md) | Debian/Ubuntu 上的 Xray 交互式部署、升级、扩展与回退工具 |

## Shadowrocket

模块地址：

```text
https://raw.githubusercontent.com/amjunliang/config/main/shadowrocket-custom-rules.module
```

在 Shadowrocket 中作为模块导入。规则包含个人域名和 IP 的直连策略，使用前请按自己的网络环境检查和调整。

## Xray Manager

脚本及其文档位于 [`script/`](script/README.md)：

```text
script/
├── xray-install.sh       # 交互管理入口
├── README.md             # 安装、功能与运行说明
├── test_xray_manager.py  # 自动化回归测试
└── test_proxy_integration.py # 可选真实代理集成测试
```

默认部署 VLESS + XHTTP + REALITY，可通过菜单增加 Vision 备用入口，或配置 Cloudflare CDN 接入。安装方法、权限模型和验证范围见 [脚本文档](script/README.md)。
