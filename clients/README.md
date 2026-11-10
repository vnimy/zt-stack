# 客户端接入（Windows / Linux / macOS）

目标：用户只需要知道**一个服务器地址**（和可选的 token），执行一条命令就能把自建
planet 装到本机，然后 `zerotier-cli join <网络ID>` 加入网络。不需要人工拷贝文件。

三个平台的脚本做同一件事，顺序也一致：

1. 下载 `<服务器地址>/planet` 到**目标目录内的临时文件**（同一磁盘，保证后面可以原子改名）
2. 校验：大小必须在 128..65536 字节之间，并且**首字节必须是 0x01**
   （ZeroTier 的 `World::TYPE_PLANET`，见源码 `node/World.hpp`）；
   如果给了 sha256 还要比对
3. 现有 planet 备份成 `planet.bak.<时间戳>`
4. 用改名（rename）原子替换目标文件
5. 重启 ZeroTier One 服务（或明确告诉你手动怎么重启）
6. 打印 `join` 提示

**任何一步失败都不会动现有 planet**：临时文件被删掉，原来的 planet 原样保留。

## 文件

```
clients/
├── windows/install-planet.ps1     # PowerShell 5.1+ 安装脚本
├── windows/install-planet.cmd     # cmd 包装（可双击、可传参）
├── linux/install-planet.sh        # Linux bash 脚本
├── macos/install-planet.command   # macOS bash 脚本（.command 可双击）
├── test/mock-server.py            # 本地假 planet 服务器，用于验证下载路径
├── test/test-download.sh          # 端到端自测（Linux + 逻辑跑 macOS 脚本）
└── README.md
```

## 服务端契约（脚本假设的接口）

| 请求 | 期望 |
| --- | --- |
| `GET /planet` | 200 + 二进制 planet 文件 |
| `GET /healthz` | 200 |
| `GET /` | 下载页（HTML） |

token 传递方式（两种都支持，服务端 token 为空即不校验）：

- 查询参数：`/planet?token=xxx`
- 请求头：`Authorization: Bearer xxx`

脚本**同时**发这两种；token 里有特殊字符时会在查询参数里做百分号编码。

## 三平台路径与服务

| 平台 | planet 路径 | 服务 | 重启方式 |
| --- | --- | --- | --- |
| Windows | `C:\ProgramData\ZeroTier\One\planet` | 服务名 `ZeroTierOneService` | `Restart-Service ZeroTierOneService` 或 `net stop ZeroTierOneService && net start ZeroTierOneService`，也可用 `services.msc` |
| Linux | `/var/lib/zerotier-one/planet` | systemd 单元 `zerotier-one.service` | `sudo systemctl restart zerotier-one`；无 systemd 时 `sudo /etc/init.d/zerotier-one restart` |
| macOS | `/Library/Application Support/ZeroTier/One/planet` | launchd 标签 `com.zerotier.one`（plist: `/Library/LaunchDaemons/com.zerotier.one.plist`） | `sudo launchctl kickstart -k system/com.zerotier.one`，或 `sudo launchctl unload <plist> && sudo launchctl load <plist>` |

依据：ZeroTier 官方源码 `build.md`（Home Folder Locations）与各平台安装器/服务实现
（`windows/ZeroTierOne/ZeroTierOneService.h` 里的 `ZT_SERVICE_NAME`、
`ext/installfiles/mac/com.zerotier.one.plist`、`ext/installfiles/linux/zerotier-one.init.rhel6`）。
macOS 与 Linux 的 planet 都放在各自 home 目录下，ZeroTier 启动时读取
`<home>/planet`（`service/OneService.cpp` 里拼的就是 `.../planet`）。

> 服务不存在时脚本不会失败退出：它打印警告并给出手动重启命令，planet 文件已经就位，
> 下次服务启动就会生效。

## Windows 用法

需要**管理员权限**（写 `C:\ProgramData` 和重启服务都要）：

```powershell
# 以管理员身份打开 PowerShell
cd clients\windows
.\install-planet.ps1 -ServerUrl https://zt.example.com -Token <你的token>

# 需要固定校验值时
.\install-planet.ps1 -ServerUrl https://zt.example.com -Token abc123 -Sha256 <64位hex>
```

或双击 / 在 cmd 里：

```bat
install-planet.cmd -ServerUrl https://zt.example.com -Token abc123
```

测试/自定路径（不需要管理员，也不会碰真实 planet）：

```powershell
.\install-planet.ps1 -ServerUrl http://127.0.0.1:18089 -Token abc123 -Target D:\tmp\planet -SkipRestart
```

装完提示：

```
"C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat" join <网络ID>
```

## Linux 用法

```bash
sudo ./install-planet.sh --server-url https://zt.example.com --token <你的token>

# 常用选项
#   --sha256 <hex>   期望的 planet sha256
#   --no-restart     只替换文件，不重启服务
#   --target <path>  覆盖 planet 路径（测试用，非 root 也可）
```

环境变量写法（避免 token 出现在 shell 历史里）：

```bash
ZT_TOKEN=abc123 sudo -E ./install-planet.sh --server-url https://zt.example.com
```

脚本优先用 `curl`，没有则用 `wget`；重启依次尝试 systemd → `/etc/init.d/zerotier-one` → `service`。

## macOS 用法

```bash
sudo ./install-planet.command --server-url https://zt.example.com --token <你的token>
```

如果下载后双击打不开（NTFS/U 盘拷贝常见），先补执行位：

```bash
chmod +x install-planet.command
```

macOS 自带 `curl` 与 `shasum -a 256`，脚本不需要额外依赖。重启走
`launchctl kickstart -k system/com.zerotier.one`，失败再退到 unload/load。

## token 怎么带

- 命令行 `-Token` / `--token`：最直接，但会留在 shell 历史与进程列表里。
- 环境变量（Linux/macOS）：`ZT_TOKEN`（Windows 用 `$env:ZT_TOKEN` 不支持，
  请直接传 `-Token`，或用 PowerShell 变量拼参数）。
- 服务端如果关闭了 token 校验，三个平台都可以不带。

强烈建议服务端用 HTTPS（Caddy 反代），并在生产环境同时给 `--sha256`，
把「服务端可信」这件事变成「内容可信」。

获取正确 sha256 的方法（服务端或任一台已装好的机器上）：

```bash
curl -fsSL "https://zt.example.com/planet?token=abc123" | sha256sum
```

脚本每次都会打印下载文件的 sha256，可以和上面的值对照后写进 `--sha256`。

## 回滚

安装脚本每次都会把**原来那份** planet 存成同目录下的
`planet.bak.<yyyyMMdd-HHmmss>`，文件数目不设上限，可以按时间挑一个恢复：

```bash
# Linux
sudo cp -p /var/lib/zerotier-one/planet.bak.20250101-120000 /var/lib/zerotier-one/planet
sudo systemctl restart zerotier-one
```

```powershell
# Windows（管理员）
Copy-Item 'C:\ProgramData\ZeroTier\One\planet.bak.20250101-120000' 'C:\ProgramData\ZeroTier\One\planet' -Force
Restart-Service ZeroTierOneService
```

```bash
# macOS
sudo cp -p '/Library/Application Support/ZeroTier/One/planet.bak.20250101-120000' '/Library/Application Support/ZeroTier/One/planet'
sudo launchctl kickstart -k system/com.zerotier.one
```

## 常见错误

| 现象 | 原因 / 处理 |
| --- | --- |
| `401` / `403`，日志说下载失败 | token 错或没带。确认服务端 token，或在服务端关闭校验 |
| `404` | 服务器地址写错（缺少 `/planet` 之外的路径前缀这类问题），或服务端没部署 planet |
| `校验失败: 不是 planet 文件 (首字节 0x3C)` | 服务器把 HTML 页面当 planet 返回了（0x3C 是 `<`）。多半是地址指向了下载页/反代错误页 |
| `校验失败: 文件 N 字节` | 同上，返回的是短错误页；也可能是 planet 文件本身被截断 |
| `校验失败: sha256 不匹配` | 服务端文件被换过，或 `--sha256` 抄错。此时旧 planet 未被改动 |
| Windows：`Administrator rights required` | 用管理员 PowerShell 重开；或加 `-Target` 做测试安装 |
| Windows：`restart failed: ... Access is denied` | 非管理员会话里无法重启服务。用管理员执行，或手动 `net stop ZeroTierOneService && net start ZeroTierOneService` |
| Linux：`需要 root 权限` | 用 `sudo` 重跑 |
| Linux：`目录 /var/lib/zerotier-one 不存在` | ZeroTier One 还没装，先装官方客户端 |
| 服务不存在 / `未能自动重启` | 只换了文件没重启，重启后生效；脚本已给出各平台命令 |
| 换完 planet 但节点还是连官方 | 服务没真正重启（或被系统策略立刻拉起了旧进程）。确认 `zerotier-cli info` 里的服务在重启后重新连上 |

> 校验只保证「这是一个 planet 格式的文件」。planet 的签名由 ZeroTier 自己在加载时验证，
> 所以服务端被替换成一个签名无效的 planet，客户端会拒绝使用。真正防篡改请用 HTTPS +
> `--sha256`。

## 自测（不需要真实服务端）

```bash
# 在 Linux/WSL 里
bash clients/test/test-download.sh
```

它会启动 `test/mock-server.py`（本地假 planet，319 字节，首字节 0x01，带 token 校验），
然后真实跑一遍安装脚本，覆盖：无 token 失败、带 token 成功、幂等重跑与备份、
sha256 正确/错误、服务端不可达、200 但内容是文本、macOS 脚本在 Linux 上的同一套逻辑。

Windows 侧等价验证（先生起 mock 服务，再带 `-Target` 跑）：

```powershell
python.exe clients\test\mock-server.py --port 18090 --token s3cr3t-token
.\clients\windows\install-planet.ps1 -ServerUrl http://127.0.0.1:18090 -Token s3cr3t-token -Target $env:TEMP\zt\planet -SkipRestart
```

## 已知限制

- **macOS 未在真机实测**：脚本通过 `bash -n` 语法检查，并在 Linux 上跑通了下载/校验/
  备份/替换这一整条路径，但 `launchctl` 重启分支与 `/Library/Application Support/...`
  路径没有在 macOS 上验证过。
- **Windows 实测**是在**非管理员**会话下用 `-Target` 完成的（下载/校验/备份/替换/幂等/
  失败保护全部验证）；管理员会话下的「默认路径 + 真实重启 `ZeroTierOneService`」
  没有端到端跑过（本机无管理员权限）。非管理员时重启分支只验证到「失败会给出正确提示」。
- **只验证到 PowerShell 5.1**：本机没有安装 PowerShell 7（`pwsh`）。脚本刻意只用 5.1 与 7
  都支持的语法，但没有在 7 上实跑。
- 脚本不做 planet **签名**校验（ZeroTier 运行时会做）；也不校验服务端身份，请用 HTTPS。
- token 以命令行参数传入时会出现在 shell 历史 / 进程列表；Linux/macOS 建议用 `ZT_TOKEN`
  环境变量。
