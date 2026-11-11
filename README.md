# zt-stack：自建 ZeroTier 行星节点 + 控制面板

把自己的一台服务器变成 ZeroTier 的"行星"根节点（planet），并在同一个容器里跑起
controller，配一个 ZTNet Web 面板管理网络与成员。客户端装上你的 planet 之后，
整个 ZeroTier 网络不再经过官方根节点。

- 一条命令部署：```scripts/deploy.sh -i <公网IP>```；不想用脚本就纯 compose（```compose/docker-compose.yml``` + ```.env```）
- 面板：```http://<IP>:3001```（ZTNet）
- planet 下载：```http://<IP>:3000/planet```
- **交接从这里开始**：```docs/HANDOVER.md```（资产坐标、设计决策、运维手册、已知限制、接手清单）
- 只有一个根节点：够个人/小团队用，抗故障能力弱于官方 planet（先读 ```docs/ARCHITECTURE.md``` 第 5、6 节再决定）

> 许可提醒：ZeroTier 1.16.x 是 source-available 许可，**非商业用途免费**；
> 商业用途需要向 ZeroTier 购买许可。

---

## 1. 架构（一屏看懂）

```
                   公网
    ┌───────────────┼─────────────────────────────┐
    │ UDP/TCP 9994  │ TCP 3000（planet 下载）      │ TCP 3001（面板）
    v               v                             v
┌────────────────────────────────────────────────────────┐
│ docker compose 项目 zt-stack（bridge 网络 172.28.0.0/24）│
│                                                        │
│  zerotier ── planet-node:1.16.2 ──┐                    │
│   :9993/tcp+udp  控制 API/controller│  ← 同一个进程     │
│   :3000/tcp      planet/moon 下载  │                    │
│   /var/lib/zerotier-one            │                    │
│    ├ identity.secret / planet       │ 共享卷             │
│    ├ authtoken.secret ─────────────┼──► ztnet :3000    │
│    └ controller.d/（网络数据库）     │     （面板+API）   │
│                                     │        │           │
│                              postgres:15-alpine ◄─SQL    │
│                                                        │
│  [profile tls] caddy :80/:443  /  → ztnet              │
│                               /planet → zerotier       │
└────────────────────────────────────────────────────────┘
```

组件、端口、数据流、为什么单节点、与官方 planet 的差异与限制，见
[```docs/ARCHITECTURE.md```](docs/ARCHITECTURE.md)。

---

## 2. 5 分钟部署

### 两种部署形态（先选一个）

| | 源码构建（本仓库 scripts/） | 镜像优先（release/） |
| --- | --- | --- |
| 服务器上需要什么 | 源码树 + 构建环境（镜像在本机 build） | **只要 Docker + 一个 dist/ 目录**，不装源码、不编译；能连私有仓库即可 |
| 装法 | `./scripts/deploy.sh -i <IP>` | 开发机 `bash release/build-release.sh` 打包，服务器 `docker login` 后 `./install.sh -i <IP>` |
| 镜像从哪来 | `planet-node/build.sh` 本地 `docker build` | 已 push 到私有仓库 `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>`，**服务器直接 `docker pull`**；出不了外网才改 `docker save` 的 tar |
| 适合 | 改镜像、调 entrypoint、一台机器上全搞定 | 交付给别人 / 生产服务器 / 不想在服务器装源码和 Go 工具链 |

两种形态跑起来是**同一个栈**：同一份 `docker-compose.yml`、同一套端口、同一套 `.env` 语义。
区别只在镜像怎么到服务器上：镜像优先形态默认**从私有仓库拉**（`docker login` 后一条命令），
dist 里的 tar 只是服务器出不了外网时的离线备选。
服务器侧不装源码的完整说明见 `release/README-部署.md`，参数速查见 `release/install.sh -h`。

### 2.1 先决条件

- 一台有公网 IPv4 的 Linux 服务器（1 核 1G 起，磁盘 5G 起），或本机 WSL 用于试跑
- Docker Engine + ```docker compose``` v2（```docker compose version``` 有输出即可）
- 当前用户在 ```docker``` 组（```docker ps``` 不需要 sudo）
- 防火墙/安全组放行：```9994/tcp```、```9994/udp```、```3000/tcp```（planet 下载）、```3001/tcp```（面板）、
  用 TLS 时再放行 ```80/443```

### 2.2 三步起栈

```bash
cd zt-stack
./scripts/deploy.sh -i <你的公网IPv4>
```

deploy.sh 做这些事（全部幂等，可以反复跑）：

1. 校验参数（IP/端口格式，缺 IP 直接报错退出，不会猜）
2. 从 ```compose/.env.example``` 生成 ```compose/.env```，自动生成
   ```NEXTAUTH_SECRET```、```POSTGRES_PASSWORD```、```DOWNLOAD_TOKEN```
3. ```docker compose up -d --pull missing```
4. 等 ```postgres``` / ```zerotier``` / ```ztnet``` 变 healthy（默认最多 300 秒）
5. 打印面板地址、planet 下载地址、必须放行的端口

预期输出（结尾几行）：

```
================ zt-stack 部署结果 ================
  公网端点        : 203.0.113.10:9994 (tcp+udp)
  ZTNet 面板      : http://203.0.113.10:3001
  planet 下载     : http://203.0.113.10:3000/planet?token=<32位十六进制>
  健康检查        : http://203.0.113.10:3000/healthz
  ...
[ ok ] 部署完成
```

### 2.3 验证

```bash
./scripts/stack-status.sh          # 服务状态 + planet world id + controller + 下载端点全检
./scripts/e2e-verify.sh            # 起一个客户端容器，装 planet、join、断言能看到 PLANET
```

```stack-status.sh``` 的正常输出片段：

```
================ planet (world) ================
  type            planet
  world id        <数字> (0x<十六进制>)
  timestamp       <毫秒>  (<UTC 时间>)
  sha256          <64位十六进制>
================ controller (9993) ================
  node address    <10位十六进制>
  version         1.16.2
  online          true
```

### 2.4 可选：域名 + HTTPS

```bash
./scripts/deploy.sh -i <公网IP> --tls -d zt.example.com
```

Caddy 自动申请证书。之后：面板在 ```https://zt.example.com/```，
planet 下载在 ```https://zt.example.com/planet?token=...```（同一个域名按路径分流）。

### 2.5 端口冲突时换端口

```bash
./scripts/deploy.sh -i <公网IP> --files-port 3001 --ztnet-port 8080
```

---

## 3. 端口与防火墙

| 端口 | 协议 | 用途 | 是否必须对公网开 |
|------|------|------|------------------|
| ```ZT_PORT```（默认 9994） | TCP + UDP | ZeroTier peer 传输与 API；planet 的 stableEndpoints 写的就是它 | **是**（客户端靠它连根节点） |
| ```FILES_PORT```（默认 3000） | TCP | planet/moon 下载服务 | 是（客户端安装 planet 时） |
| ```ZTNET_PORT```（默认 3001） | TCP | ZTNet 面板 | 面板需要人访问；不需要就给内网/隧道 |
| ```80/443``` | TCP(+UDP 443) | 仅 ```--tls``` profile 的 Caddy | 用 TLS 时是 |

ufw 示例：

```bash
sudo ufw allow 9994/tcp && sudo ufw allow 9994/udp
sudo ufw allow 3000/tcp && sudo ufw allow 3001/tcp
# 用 TLS 时
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw allow 443/udp
```

云厂商安全组同理（入方向）。```9994/udp``` 忘了放行是最常见的"客户端连不上"原因。

### 3.1 重建相关的环境变量

| 变量 | 何时为 1 | 后果 |
|------|----------|------|
| ```REGENERATE_WORLD``` | 换公网 IP / 换通告端口时，deploy.sh 自动置 1，成功后复位 0 | 只重写 planet+moons（新端点+新时间戳）：identity、authtoken、controller 数据、network id、成员授权**全部不变**；成员只需重新下载 planet，ZTNet 不用重启 |
| ```FORCE_REGENERATE``` | 只有 ```./scripts/deploy.sh --force-new-identity``` 会置 1 | 全量重建：identity 换新 → 所有自建网络 ID 失效，成员必须重新 join；authtoken 也变，deploy.sh 会自动重启 ZTNet 让它重读 |

两个同时为 1 时 ```FORCE_REGENERATE``` 优先。对照表与演练结论见 [```docs/OPERATIONS.md```](docs/OPERATIONS.md) 第 4 节。

---

## 4. 如何下载 planet

三种方式等价，能否下载取决于 ```DOWNLOAD_TOKEN```（deploy.sh 默认生成一个，可用
```--no-download-token``` 关掉鉴权）。

1. 浏览器打开 ```http://<IP>:3000/```（或 ```/?token=<token>```），页面上有 planet 与 moon 的链接。
2. 命令行（两种凭据形式都支持）：

   ```bash
   curl -fsSL "http://<IP>:3000/planet?token=<token>" -o planet
   curl -fsSL -H "Authorization: Bearer <token>" "http://<IP>:3000/planet" -o planet
   ```

3. 校验（服务端会返回 ```X-File-SHA256``` 头，容器内也能直接算）：

   ```bash
   curl -fsS -D - -o planet -H "Authorization: Bearer <token>" "http://<IP>:3000/planet" | grep -i x-file-sha256
   sha256sum planet
   ```

moon（如果要用 moon 而不是 planet）在 ```/moons``` 与 ```/moon/<文件名>``` 下。

---

## 5. 客户端怎么连

**核心就一句话：把下载到的 ```planet``` 放进 ZeroTier 的数据目录，重启 ZeroTier 服务。**
现成脚本在 [```clients/```](clients/README.md)：

| 平台 | 脚本 | 说明 |
|------|------|------|
| Windows | ```clients/windows/install-planet.ps1``` / ```.cmd``` | 写入 ```%LOCALAPPDATA%\ZeroTier\One\planet```，重启服务 |
| macOS | ```clients/macos/install-planet.command``` | 写入 ```/Library/Application Support/ZeroTier/One/planet``` |
| Linux | ```clients/linux/install-planet.sh``` | 写入 ```/var/lib/zerotier-one/planet``` |
| Android | [```patches/zerotierfix/```](patches/zerotierfix/) | ZeroTierFix 补丁版 APK，只用 ```Authorization: Bearer``` 下载 planet |

脚本同时支持 ```?token=``` 与 ```Authorization: Bearer```；Android 只发 Bearer，
所以服务端两种都实现了（见 ```planet-node/planet-files.py```）。

手动安装（以 Linux 为例）：

```bash
sudo systemctl stop zerotier-one
sudo curl -fsSL -H "Authorization: Bearer <token>" "http://<IP>:3000/planet" -o /var/lib/zerotier-one/planet
sudo systemctl start zerotier-one
sudo zerotier-cli peers | grep PLANET     # 确认根节点已经是你的
```

---

## 6. 建第一个网络

1. 浏览器打开面板（```http://<IP>:3001```），注册第一个账号（它就是管理员）。
2. 「Networks」→ 新建网络 → 记下 16 位 network id。
3. 网络设置里确认 IPv4 Auto-Assign 已开启（默认会给一个 10.x 网段）。
4. 客户端 ```zerotier-cli join <network id>```（或 App 里输入网络 id）。
5. 回面板的成员列表，勾选授权该成员（私有网络必须授权）。客户端状态从
   ```ACCESS_DENIED``` 变成 ```OK``` 即成功。

---

## 7. 升级与备份

- 升级：```./scripts/deploy.sh --upgrade```（拉新镜像原地重建，身份/planet/数据库都保留）
- 升级 ZeroTier 版本：见 [```docs/OPERATIONS.md```](docs/OPERATIONS.md) 第 3.2 节
- 备份：**必须备 ```planet-data``` 卷**（identity + planet + controller 数据库）与
  ```postgres```，命令见 [```docs/OPERATIONS.md```](docs/OPERATIONS.md) 第 1 节
- 改公网 IP：```./scripts/deploy.sh -i <新IP>``` —— 只重建 planet（```REGENERATE_WORLD=1```）：
  **identity 与 network id 不变**，成员授权保留，但客户端要重新下载 planet；ZTNet 不用重启。
  对照表见 OPERATIONS 第 4 节

---

## 8. 故障排查（最常撞到的五种）

| 现象 | 先看这里 |
|------|----------|
| deploy.sh 直接退出说缺 IP | 用 ```-i <IPv4>``` 或 ```PUBLIC_IPV4=``` 明确给，不会猜 |
| 服务 ```unhealthy``` | ```docker compose logs <服务名>```，```scripts/stack-status.sh``` |
| 面板打不开 | ```curl -I http://127.0.0.1:<ZTNET_PORT>/auth/login```；看 ```NEXTAUTH_URL``` 是否写成了错误地址 |
| 面板能开但网络列表空/报错 | 控制器链路问题：```ZT_ADDR```、authtoken、```ALLOW_MANAGEMENT_FROM``` 三选一 |
| 客户端连不上 | ```9994/udp``` 没放行，或 planet 里的 IP 不是客户端可达地址 |
| 换 IP 后客户端全掉线 | 换 IP 只重写 world，客户端手上的旧 planet 还指着旧 IP：重新分发 planet 即可，**不要**用 ```--force-new-identity```（那会让所有 network id 失效） |

完整对照表见 [```docs/OPERATIONS.md```](docs/OPERATIONS.md) 第 7 节。

---

## 9. 目录结构

```
zt-stack/
├── README.md                  本文
├── compose/
│   ├── docker-compose.yml     zerotier + postgres + ztnet（+ tls profile 的 caddy）
│   ├── .env.example           所有可配项与注释
│   ├── Caddyfile              tls profile 的反代规则
│   └── .env                   deploy.sh 生成（含口令，权限 600，勿入库）
├── scripts/
│   ├── deploy.sh              一条命令部署/升级/改 IP
│   ├── stack-status.sh        只读体检
│   ├── e2e-verify.sh          端到端验收（controller 建网 + 客户端 join + PLANET 断言）
│   └── lib.sh                 公共函数
├── docs/
│   ├── ARCHITECTURE.md        组件/端口/数据流/兼容性证据/限制
│   └── OPERATIONS.md          备份恢复/升级/改 IP/日志/重置/排障
├── planet-node/               行星节点镜像（Dockerfile、entrypoint、文件服务）
├── clients/                   各平台 planet 安装脚本
├── client-node/               容器化客户端（PLANET_URL + NETWORK_ID 自动接入）
├── release/                   镜像优先交付形态（服务器不装源码、不编译）
│   ├── build-release.sh       开发机打包：镜像 tar.gz（离线备选）+ compose 文件 + 客户端 + SHA256SUMS
│   ├── install.sh             服务器侧安装（默认 docker pull；离线 docker load / --image / --upgrade）
│   ├── README-部署.md         服务器侧唯一要看的文档（三条命令跑完）
│   ├── client/                APK + Windows/Linux/macOS planet 脚本 + 客户端配置说明
│   └── dist/                  build-release.sh 的产物（dist/*.tar.gz 不入库）
└── patches/zerotierfix/       Android 客户端补丁
```

---

## 10. 验收记录（本机实测）

环境：WSL Ubuntu 24.04 / docker 29.1.3 / compose 2.40.3 / 镜像
`ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2`、`sinamics/ztnet`（面板显示 v0.8.7）、`postgres:15-alpine`。
测试用 IP 是内网地址 `192.168.2.145`（deploy.sh 会警告"内网地址"，属预期），
换公网 IP 只是替换参数，流程完全相同。

| # | 验收项 | 命令 | 结果 |
|---|--------|------|------|
| 1 | compose 配置与 profile | `docker compose config --services` | 默认 `postgres zerotier ztnet`；`--profile tls` 多出 `caddy`；`config -q` 退出码 0 |
| 2 | deploy.sh 从零跑通 | `rm compose/.env; docker compose down -v; ./scripts/deploy.sh -i 192.168.2.145` | 退出码 0，三个服务全部 healthy |
| 3 | 面板可达 | `curl -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/auth/login` | 200 |
| 4 | 控制器建网 | `./scripts/e2e-verify.sh` 的建网段 + 面板点"创建网络" | 见下方输出 |
| 5 | 下载端点 | `./scripts/stack-status.sh` | /healthz 200、/planet（Bearer 与 ?token）200、无凭据 401、sha256 一致 |
| 6 | e2e 客户端 | `./scripts/e2e-verify.sh` | peers 出现 PLANET，listnetworks 状态 OK，退出码 0 |

关键输出（原样摘录）：

```
$ ./scripts/deploy.sh -i 192.168.2.145
[ ok ] 已从 .env.example 生成 compose/.env（权限 600）
[ ok ] 生成 NEXTAUTH_SECRET / POSTGRES_PASSWORD / DOWNLOAD_TOKEN
[ ok ] compose 配置有效
[ ok ] 容器已启动
[ ok ] zt-stack-postgres healthy
[ ok ] zt-stack-zerotier healthy
[ ok ] zt-stack-ztnet healthy
  ZTNet 面板      : http://192.168.2.145:3001
  planet 下载     : http://192.168.2.145:3000/planet?token=<token>
[ ok ] 部署完成

$ ./scripts/stack-status.sh
postgres   Up (healthy)    5432/tcp
zerotier   Up (healthy)    0.0.0.0:3000->3000/tcp, 0.0.0.0:9994->9993/tcp, 0.0.0.0:9994->9993/udp
ztnet      Up (healthy)    0.0.0.0:3001->3000/tcp
ZTNet 面板      http://127.0.0.1:3001/auth/login -> HTTP 200
  GET /healthz        -> HTTP 200
  GET /planet (无凭据)-> HTTP 401（token 已启用，期望 401）
  GET /planet (Bearer)-> HTTP 200
  GET /planet (?token)-> HTTP 200
  下载 sha256        064eeeeec8bd0f8672755b233abd93431e0c494eaff4fe60addb50b8525d688b
  容器内 sha256      064eeeeec8bd0f8672755b233abd93431e0c494eaff4fe60addb50b8525d688b
[ ok ] 下载到的 planet 与容器内文件一致
  world id        149604618 (0x08eac90a)
  node address    ee3a223b88   version 1.16.2   online True

$ ./scripts/e2e-verify.sh
[ ok ] 控制器地址 ee3a223b88，版本 1.16.2
[ ok ] 网络已创建: ee3a223b88612348
  name=e2e-verify private=False routes=0
["ee3a223b88612348"]
[ ok ] 客户端 join 成功
  | downloaded 257 bytes sha256=064eeeeec8bd0f8672755b233abd93431e0c494eaff4fe60addb50b8525d688b
  | planet sha256 matches server
  | network status: OK
  | ee3a223b88 1.16.2 PLANET    14 DIRECT   999      999      192.168.2.145/9994
  | 200 listnetworks ee3a223b88612348 e2e-verify 4a:49:92:da:b7:d6 OK PUBLIC zt2wzeggga -
[ ok ] peers 里能看到 PLANET 角色的根节点
DELETE /controller/network/ee3a223b88612348 -> HTTP 200
[ ok ] 端到端验收通过
```

另外用浏览器在面板里点"创建网络"（ZTNet → 本地控制器 → 创建网络）也验证过一遍：

```
$ curl -s -H "X-ZT1-Auth: $(docker exec zt-stack-zerotier cat /var/lib/zerotier-one/authtoken.secret)" \
       http://127.0.0.1:9994/controller/network
["3417a77156d6fe78"]
# 读回：{'id': '3417a77156d6fe78', 'name': 'technical-cephalopod', 'private': True, 'mtu': 2800}
```

network id 前 10 位等于控制器地址，说明 ZTNet 走的就是 legacy 建网路径
`POST /controller/network/<addr>______`（详见 `docs/ARCHITECTURE.md` 第 4 节），
与 1.16.2 的 `oldAndBustedNetworkCreatePath` 完全对上 —— `ZTNet v0.8.7 ↔ ZeroTier 1.16.2` 兼容。
