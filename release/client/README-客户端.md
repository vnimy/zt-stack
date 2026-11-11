# 客户端配置（Android / Windows / Linux / macOS）

服务端装好后，客户端只需要知道**一个地址**：planet 下载地址。

| 场景 | 地址 |
| --- | --- |
| 没上 TLS（默认） | `http://<服务器IP>:3000/planet` |
| 上了 TLS（`--tls-domain`） | `https://<域名>/planet` |
| 服务端开启了下载 token | 地址不变，token 另填（见下） |

服务端的 token 在 `.env` 的 `DOWNLOAD_TOKEN`，也可以看 `./install.sh` 结尾打印的
「下载凭据」那一行。服务端认两种带法：查询串 `?token=xxx` 或请求头
`Authorization: Bearer xxx`。

## Android（ZeroTier）

安装包：`client/ZeroTier-1.16.2-debug.apk`（debug 包，安装时要允许「未知来源」）。

1. 装 APK，打开 App。
2. 右上角菜单 → **设置** → **行星服务器（自动下载）**。
3. **地址**填 `http(s)://<服务器IP>:3000/planet`。这就是服务端打印的 planet 下载地址，
   要填到 `/planet` 为止的完整路径，不要只填 `http://IP:3000`。
4. **下载 token（可选）**填服务端的 `DOWNLOAD_TOKEN`。Android 客户端是用
   `Authorization: Bearer` 请求头发 token 的，所以 token 填在这个输入框里，不要拼到地址后面。
   服务端没启用 token 就留空。
5. **期望的 sha256（可选）**：要内容校验时填服务端 planet 的 sha256，取法见下面「装完怎么验证」。
6. 打开 **每次启动都重新下载 planet**，客户端才会在服务端换 IP/换 planet 后跟着更新。
7. 点 **保存并同步**，成功会提示「已从服务器更新 planet」。
8. 回主界面断开再连接（或重启 App）让新 planet 生效，然后 + 添加网络、填 network id 加入。

App 里其余开关（通用设置、网络设置）保持默认即可。

## Windows

需要**管理员权限**（写 `C:\ProgramData` 与重启服务）。在 `client\windows` 目录：

```powershell
# 以管理员身份打开 PowerShell
.\install-planet.ps1 -ServerUrl http://<服务器IP>:3000 -Token <DOWNLOAD_TOKEN>
```

服务端没启用 token 就去掉 `-Token`。脚本会下载 `/planet`、校验格式、备份旧 planet、
原子替换，并重启 `ZeroTierOneService`（服务不存在时只提示手动重启，文件已就位）。

```bat
:: 或者用 cmd 包装
install-planet.cmd -ServerUrl http://<服务器IP>:3000 -Token <DOWNLOAD_TOKEN>
```

## Linux

```bash
sudo ./install-planet.sh --server-url http://<服务器IP>:3000 --token <DOWNLOAD_TOKEN>
```

不想让 token 留在 shell 历史里：

```bash
ZT_TOKEN=<DOWNLOAD_TOKEN> sudo -E ./install-planet.sh --server-url http://<服务器IP>:3000
```

脚本优先用 `curl`、没有则用 `wget`，重启走 systemd → `/etc/init.d/zerotier-one` → `service`。

## macOS

```bash
sudo ./install-planet.command --server-url http://<服务器IP>:3000 --token <DOWNLOAD_TOKEN>
```

从 U 盘/NTFS 拷来的脚本可能丢执行位，先 `chmod +x install-planet.command`。
macOS 自带 `curl` 与 `shasum`，不需要额外依赖。

## 装完怎么验证

- 三平台脚本末尾都会打印下载文件的 sha256；服务端的对照值这样取：

```bash
curl -fsSL "http://<服务器IP>:3000/planet?token=<DOWNLOAD_TOKEN>" | sha256sum
```

- `zerotier-cli info` 能看到本节点；`zerotier-cli listnetworks` 里出现你加入的网络。
- 客户端仍连官方根节点（planet 没生效）多半是 ZeroTier 服务没重启：按脚本末尾提示手动重启一次。

## 回滚

每个脚本替换前都会把旧 planet 备份成同目录的 `planet.bak.<时间戳>`，
把它拷回原位再重启服务就回到旧 planet。各平台路径与重启命令见仓库
`clients/README.md` 的「回滚」一节。
