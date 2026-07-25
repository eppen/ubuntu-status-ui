# ServerStatus（macOS / iPad / iPhone）

通过 SSH 监控 Ubuntu **或 macOS**：系统指标 + Docker 状态（免装 Agent）。

采集脚本自动识别远端系统（Linux `/proc` / Darwin Mach+sysctl）。

## 平台

| 平台 | 最低版本 | 导航 |
|------|----------|------|
| macOS | 14+ | 侧栏 + 详情 |
| iPadOS | 17+ | 侧栏 + 详情 |
| iOS | 17+ | 列表推进详情 |

## 用 Xcode 运行（推荐）

```bash
cd macos/ServerStatus
open ServerStatus.xcodeproj
```

在 Scheme 目标里选择：
- **My Mac**
- **iPad 模拟器 / 真机**
- **iPhone 模拟器 / 真机**

> 若 Xcode 提示缺少 iOS Platform，到 **Xcode → Settings → Components** 安装对应 iOS 运行时。

重新生成工程（改源文件列表后）：

```bash
python3 generate_xcodeproj.py
```

## 仅 macOS 命令行

```bash
swift run
```

## 功能

- 服务器管理（密码进 Keychain / 私钥导入沙盒）
- CPU / 内存 / 磁盘 / 网络 / 温度 / 负载 / Top 进程
- Docker：版本、运行数、容器 CPU/内存/端口

SSH 用户需能执行 `docker`（加入 `docker` 组）。
