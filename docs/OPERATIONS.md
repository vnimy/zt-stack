# 运维手册（zt-stack）

面向已经把栈跑起来的运维人员：日常命令、备份恢复、升级、改 IP、日志、重置。
所有命令都在 **栈目录** （`zt-stack/`）下执行；`S=${...}` 这类写法不是必需的，
它们是给 shell 复用的变量。

栈目录结构：

```
zt-stack/
├── compose/            docker-compose.yml / .env / .env.example / Caddyfile
├── scripts/            deploy.sh / stack-status.sh / e2e-verify.sh / lib.sh
├── docs/               OPERATIONS.md（本文）/ ARCHITECTURE.md
├── planet-node/        行星节点镜像（构建方，W1 维护）
└── clients/ patches/   客户端安装脚本与 Android 补丁
```

---

## 0. 日常命令

```bash
cd zt-stack/compose

docker compose ps                         # 服务状态
docker compose logs -f --tail=100 zerotier # 根节点日志（planet 生成、controller、peer）
docker compose logs -f --tail=100 ztnet    # 面板日志（controller 请求失败会打在这里）
docker compose restart ztnet               # 改了控制器地址/口令后必须重启 ztnet
docker compose down                        # 停栈（保留卷与数据）
docker compose --profile tls up -d         # 带 Caddy 起来
../scripts/stack-status.sh                 # 只读体检
```

一条命令重新对齐配置（幂等，保留口令与数据）：

```bash
../scripts/deploy.sh -i <公网IP>
```

---

## 1. 备份

**要备份两样东西**：`planet-data` 卷（identity + planet + controller 数据库）和
`postgres-data` 卷（ZTNet 的网络/成员/用户元数据）。两者都丢了就等于重装。

### 1.1 备份 planet-data（最关键）

```bash
mkdir -p ~/zt-backup
docker run --rm -v zt-stack_planet-data:/data:ro -v ~/zt-backup:/backup alpine   tar czf /backup/planet-data-$(date +%F-%H%M).tar.gz -C /data .
```

卷名以 `docker volume ls` 为准（compose 项目名是 `zt-stack`，所以是
`zt-stack_planet-data`）。镜像可以用任意带 `tar` 的镜像；实在没有再 `docker run --rm -it` 进
`planet-node` 镜像手动打包。

> **先确认挂载方式**：`docker inspect zt-stack-zerotier --format '{{json .Mounts}}'`。
> 若 `Type` 是 `bind`（现场确有用宿主机目录直接挂的部署，例如
> `/root/docker/zerotier/planet-data`），要备份的是那个宿主机目录，命令改成
> `tar czf ~/zt-backup/planet-data-$(date +%F-%H%M).tar.gz -C /root/docker/zerotier/planet-data .`。
> 命名卷与 bind mount 是两套互不相干的数据，名字像不代表是同一份；备份错了等于没备份。

更有用的是把它拆开看：

```bash
docker run --rm -v zt-stack_planet-data:/data:ro alpine ls -la /data
# identity.secret / identity.public / authtoken.secret / planet / local.conf
# moons.d/*.moon / controller.d/（network/<nwid>.json 与 member/<addr>.json 明文 JSON，所有网络与成员都在这里）
```

### 1.2 备份 PostgreSQL

```bash
docker exec zt-stack-postgres pg_dump -U postgres -d ztnet -Fc > ~/zt-backup/ztnet-$(date +%F).dump
```

> `planet-data` 里已经有网络定义，`postgres` 里是 ZTNet 的用户、组织、网络元数据与 API token。
> 只恢复 planet-data 也能让网络继续工作，但 ZTNet 面板会“忘记”这些网络 —— 两边要一起恢复。

---

## 2. 恢复

### 2.1 恢复 planet-data 到同一台机器

```bash
cd zt-stack/compose && docker compose down
docker volume rm zt-stack_planet-data
docker volume create zt-stack_planet-data
docker run --rm -v zt-stack_planet-data:/data -v ~/zt-backup:/backup alpine   tar xzf /backup/planet-data-YYYY-MM-DD-HHMM.tar.gz -C /data
docker compose up -d
```

启动后确认 world id 与备份前一致：

```bash
docker exec zt-stack-zerotier mkworld verify /var/lib/zerotier-one/planet | head -3
# world_id=...  timestamp=...  signature_valid=true
```

### 2.2 恢复 PostgreSQL

```bash
docker compose stop ztnet
docker exec -i zt-stack-postgres pg_restore -U postgres -d ztnet --clean --if-exists < ~/zt-backup/ztnet-YYYY-MM-DD.dump
docker compose start ztnet
```

### 2.3 整机迁移（换服务器）

1. 新机器装 docker + compose，把 `zt-stack/` 目录拷过去（**包括 `compose/.env`**）。
2. 按 1.1/1.2 备份 → 按 2.1/2.2 恢复两个卷。
3. 新机器 IP 若变了：`scripts/deploy.sh -i <新公网IP>`。
   注意这是**改 IP**，会重建 planet（见第 4 节），客户端要重装 planet。
4. 若要保持同一 IP，直接把 DNS/云主机弹性 IP 切过去即可，planet 不用重建，
   客户端无感知（除了重建期间的短暂断线）。

---

## 3. 升级

### 3.1 升级 ZTNet / PostgreSQL（不动 ZeroTier 身份）

```bash
cd zt-stack/compose
docker compose pull ztnet postgres
docker compose up -d
# 或一条命令：
../scripts/deploy.sh --upgrade
```

ZTNet 启动时会自动跑 `prisma migrate deploy`（见官方 `init-db.sh`），
数据库结构随镜像升级；卷不动，身份与 planet 不动。

### 3.2 升级行星节点（ZeroTier 版本）

目前镜像 tag 与 ZT 版本绑定（`ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<ZT版本>`）。升级步骤：

```bash
# 1) 用 planet-node/ 下的构建脚本产出新 tag，例如 1.16.3
cd zt-stack/planet-node && ./build.sh 1.16.3
# 2) 改 .env 里的 tag
cd ../compose && sed -i 's/^PLANET_NODE_TAG=.*/PLANET_NODE_TAG=1.16.3/' .env
# 3) 只重建根节点，数据卷保留（identity/planet/controller 不变）
docker compose up -d zerotier
```

**注意事项**

- 数据卷不会因为换镜像而变化：planet world id、identity、controller 数据库都还在。
- `local.conf` 若被旧版本的 entrypoint 写成不兼容的字段，可能起不来；先备份卷再升级。
- 客户端**不需要**跟着升级；1.10+ 的客户端可以连 1.16 的根节点。
- 跨大版本（如 1.16 → 1.18）前先在测试机跑 `scripts/e2e-verify.sh --local`。

---

## 4. 改 IP（换公网地址）

planet 里的 `stableEndpoints` 是**写死的 IP**，所以换 IP 必然要重写 planet —— 
但**换端点不等于换身份**。deploy.sh 检测到 `PUBLIC_IPV4` 变化时走的是
`REGENERATE_WORLD=1`（只重写 planet/moons），identity 原封不动。

| | `REGENERATE_WORLD=1`（换 IP 默认） | `FORCE_REGENERATE=1`（`--force-new-identity`） |
|---|---|---|
| 触发方式 | `./deploy.sh -i <新IP>` 自动走 | `./deploy.sh -i <新IP> --force-new-identity` |
| identity.secret/public | **不变**（`/status` 的 address 不变） | 重新生成（address 变） |
| authtoken.secret | **不变** → ZTNet 不需要重启 | 变 → ZTNet 必须重读；deploy.sh 会自动 `docker compose restart ztnet` |
| controller.d/ 网络与成员授权 | **不变** | 全部失效 |
| network id | **不变** | 全部变（id 前缀就是控制器地址） |
| 成员是否要重新 join | **不需要**（授权还在） | 需要 |
| planet / moons | 重写（新端点 + 新时间戳） | 重写 |
| world id | **不变**（只有 timestamp 与签名变） | 变 |
| 客户端要做什么 | 重新下载 planet 即可 | 重新下载 planet + 每个成员重新 join |

演练结论（本机实测，192.168.2.145 → 192.168.2.146 → 192.168.2.145 两次换 IP）：
控制器的 address `ee3a223b88` 与网络 `ee3a223b888bba8d` 完全不变；
planet 的 sha256 每次换 IP 都变、`root[0].endpoint` 跟随当前 IP、world id 始终 `149604618`；
authtoken 的 sha256 不变，ztnet 容器全程 healthy 且未重启。

换 IP 的标准流程：

```bash
cd zt-stack/scripts
./deploy.sh -i <新公网IP>
```

它会把 `REGENERATE_WORLD=1` 写进 .env、重建 planet，健康检查通过后再复位为 0。之后：

```bash
curl -fsSL "http://<新IP>:3000/planet?token=<DOWNLOAD_TOKEN>" -o planet
# 然后按 clients/ 里的脚本装到客户端数据目录并重启 ZeroTier 服务
```

只换 IPv6 或只换通告端口（`--zt-port`）也只重建 world，同样不影响网络与成员。

**什么时候才该用 `--force-new-identity`**：怀疑 identity 私钥泄露、要彻底换掉节点身份时。
代价是所有自建网络 ID 失效、每个成员都要重新 join，务必先读上面的表。

> 只想"换监听地址但 planet 不变"是不可能的：planet 里的端点就是客户端的连接目标。

---
## 5. 日志

| 想看什么 | 命令 |
|----------|------|
| 根节点（planet 生成、peer、controller） | `docker compose logs -f zerotier` |
| 面板（含 controller 请求错误） | `docker compose logs -f ztnet` |
| 数据库 | `docker compose logs -f postgres` |
| Caddy（证书申请） | `docker compose --profile tls logs -f caddy` |
| 容器内 zerotier 自身日志 | `docker exec zt-stack-zerotier tail -n 200 /var/log/zerotier-one.log 2>/dev/null || docker compose logs --tail=200 zerotier` |
| controller 状态 | `TOKEN=$(docker exec zt-stack-zerotier cat /var/lib/zerotier-one/authtoken.secret); curl -s -H "X-ZT1-Auth: $TOKEN" http://127.0.0.1:9994/status | head -c 400` |

日志驱动是 json-file，长期运行建议在 `/etc/docker/daemon.json` 里加
`"log-opts": {"max-size": "20m", "max-file": "5"}`。

---

## 6. 重置

### 6.1 只重建 planet（保留 ZTNet 用户与网络记录）

```bash
cd zt-stack/compose
sed -i 's/^FORCE_REGENERATE=.*/FORCE_REGENERATE=1/' .env
docker compose up -d --force-recreate zerotier
sed -i 's/^FORCE_REGENERATE=.*/FORCE_REGENERATE=0/' .env
docker compose restart ztnet      # authtoken 变了，ZTNet 只在启动时读一次
```

### 6.2 全清（连数据一起）

```bash
cd zt-stack/compose
docker compose down -v            # -v 会删掉 planet-data / postgres-data / caddy 卷
../scripts/deploy.sh -i <公网IP>   # 从零重来
```

`down -v` 之前**一定**先按第 1 节备份：controller 的所有网络定义都在
`planet-data/controller.d/` 里，删了就没了。

### 6.3 轮换下载 token

```bash
cd zt-stack/compose
../scripts/deploy.sh --download-token          # 生成新 token（不给值就随机生成）
docker compose up -d zerotier                  # 让文件服务读到新 token
../scripts/stack-status.sh                     # 确认 /planet 仍 200、无凭据仍 401
```

### 6.4 找回被重建的控制器身份（客户端一直“正在请求配置”）

**症状**：客户端长期停在 `REQUESTING_CONFIGURATION` / “正在请求配置”，但客户端侧
`zerotier-cli peers` 里根节点是 `PLANET ... DIRECT`（说明 planet 文件与 UDP 端口都没问题）。
控制器上 `controller.d/network/` 里有网络定义、有已授权成员，就是没有任何客户端能拿到配置。

**原因**：节点身份被重建过，而 controller 数据是从别的服务器拷来的。
network id 的前 10 位就是控制器地址；两者不一致时，客户端把配置请求发给一个不存在的节点，
永远等不到响应。根节点日志里的直接证据：

```
entrypoint: empty or incomplete data volume, initialising (this creates a NEW node identity)
```

**确认**：

```bash
docker exec zt-stack-zerotier zerotier-cli info            # 第 3 列是当前 address
docker exec zt-stack-zerotier ls /var/lib/zerotier-one/controller.d/network/
# 网络文件名前 10 位必须等于上面的 address；不相等 → 这个网络不归当前节点管
```

**修复**（把身份换回网络数据所属的那个；network id、成员授权、固定 IP 都不用动）：

```bash
cd zt-stack/compose
# 1) 先备份（bind mount 部署：本节所有 -v zt-stack_planet-data:/data 都换成宿主机目录，见 1.1）
docker run --rm -v zt-stack_planet-data:/data:ro -v ~/zt-backup:/backup alpine \
  tar czf /backup/planet-data-before-identity-restore.tar.gz -C /data .

# 2) 停面板与根节点（面板读写同一个卷）
docker compose stop ztnet zerotier

# 3) 把旧身份放回卷里（secret 与 public 必须成对，权限 600/644）
docker run --rm -v zt-stack_planet-data:/data -v /path/to/old-identity:/old:ro alpine sh -c '
  cp /old/identity.secret /old/identity.public /data/ &&
  chmod 600 /data/identity.secret && chmod 644 /data/identity.public'

# 4) 删掉属于上一个身份的 moon 定义（不删 entrypoint 会拒绝启动，见下）
docker run --rm -v zt-stack_planet-data:/data alpine sh -c \
  'rm -f /data/moon.json /data/moons.d/*.moon'

# 5) 用恢复的身份重建 planet
sed -i 's/^REGENERATE_WORLD=.*/REGENERATE_WORLD=1/' .env
docker compose up -d --no-deps --force-recreate zerotier
sed -i 's/^REGENERATE_WORLD=.*/REGENERATE_WORLD=0/' .env
docker compose up -d --no-deps zerotier      # 让容器里的开关也回到 0

# 6) 起面板并核对
docker compose start ztnet
docker exec zt-stack-zerotier zerotier-cli info
docker exec zt-stack-zerotier mkworld verify /var/lib/zerotier-one/planet | head -6
```

预期：`info` 的 address 等于 network id 前 10 位；planet 的 `root[0].identity` 与之一致、
`root[0].endpoint` 是当前 `PUBLIC_IPV4:ZT_PORT`、`signature_valid=true`。
接着用一个干净客户端验证：join 后应是 `ACCESS_DENIED`（控制器已在应答），授权后变 `OK` 并分到 IP。

**必须注意**

- 换身份前**先验证密钥对**：
  `docker run --rm -v /path/to/old-identity:/old:ro --entrypoint zerotier-idtool <镜像> getpublic /old/identity.secret`
  的输出前 10 位，必须同时等于 `identity.public` 与 network id 的前 10 位。
- `moon.json` 里带着 `roots[0].identity`，换身份后必然不匹配：entrypoint 的
  `generate_moon keep` 会以 `moon.json belongs to ..., not to the current identity ...` 退出，
  容器起不来。所以第 4 步不能省。moon id 会随之变成 `000000<address>.moon`；
  没有客户端手工 orbit 过旧 moon 时无需额外处理。
- 不要用 `FORCE_REGENERATE=1` 来“修”它：那只会再造一个新身份，所有 network id 一起失效。
- 客户端必须重新下载 planet（根身份变了，旧 planet 指向的根已经不存在）：
  手机在 ZerotierFix 里点“保存并同步”或开自动更新，桌面端重跑 `clients/` 脚本。
- 旧服务器若还在跑且用的是同一个 identity，**必须先停掉**，否则两台同身份互相冲突。
- 已在册的成员不需要重新 join，授权与固定 IP 原样生效；**新**连上的设备仍要在面板授权。

### 6.5 让 Android 客户端常驻（前台服务 / 开机自启）

客户端连接后现在是**前台服务**：状态栏有一条常驻通知（“已连接 · <网络 id>”），切后台或息屏不会被系统回收；通知右侧的「断开连接」按钮等同于在 app 里断开，走同一套清理流程。

- 通知权限被拒时 `startForeground` 会失败并退回普通通知（行为同旧版本），此时服务仍可能被系统回收 —— 去系统设置里给 Zerotier Fix 打开通知权限即可。
- **开机自启不由 app 负责**：旧版的 `BOOT_COMPLETED` 接收器是空实现（只打一行日志，manifest 也没有权限），阶段4 已删除。要开机自动连，用系统能力：
  设置 → 网络和互联网 → VPN → Zerotier Fix 右侧齿轮 → 打开「始终开启的 VPN」（Always-on VPN）；
  需要更严格时再开「阻止未使用 VPN 的连接」。
- 国产 ROM（MIUI / EMUI / ColorOS / OriginOS 等）会额外清理后台：把 app 加入「自启动/后台运行」白名单，电池策略设为「不限制」。

### 6.6 发布 Android 新版本（客户端检查更新）

客户端「设置 → 关于 → 检查更新」会请求**行星服务器同域的** `/version.json`，比较 `versionCode` 后提示下载。整条链路只有两个文件，都放在数据目录里，改完立即生效（服务每次请求重读，不用重启容器）：

```bash
cd /root/docker/zerotier

# 1) 放安装包（名字必须是 zerotierfix.apk）
cp /path/to/ZerotierFix-1.16.2-debug.apk planet-data/zerotierfix.apk
sha256sum planet-data/zerotierfix.apk     # 记下来，写进清单

# 2) 写清单（versionCode 必须大于用户已装版本才会提示）
cat > planet-data/version.json <<'EOF'
{"versionCode": 16, "versionName": "1.0.12",
 "url": "https://zt.vnimy.com/app/zerotierfix.apk",
 "notes": "这次改了什么，客户端弹窗里会原样显示"}
EOF

# 3) 自检
curl -s https://zt.vnimy.com/version.json
curl -sI https://zt.vnimy.com/app/zerotierfix.apk | head -1
```

要点：

- `versionCode` 是唯一判据，必须**大于**用户当前装的版本；`versionName` 只用于显示。发版前先改 app 里 `app/build.gradle` 的 `versionCode`/`versionName` 再构建。
- `url` 写公网地址；客户端只负责用系统浏览器打开它，不下载也不静默安装。
- 反代（nginx）需要把 `/version.json` 与 `/app/` 两条转给 3000 端口；仓库里的 `docs/NGINX-反代.md` 已包含。漏配时表现为客户端提示「检查更新失败」。
- 想强制所有客户端都更新时，不要改 `versionCode` 玩花招（App 会一直提示），直接发通知/公告即可。

---

## 7. 排障对照表

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `deploy.sh` 报 `PUBLIC_IPV4 必填` | 没给 `-i` 且 .env 里为空 | `./deploy.sh -i <IP>` |
| zerotier 容器 `unhealthy` | 文件服务没起来 / PUBLIC_IPV4 为空 | `docker compose logs zerotier`，看 entrypoint 的 FATAL 行 |
| ztnet 容器 `unhealthy` 或反复重启 | 数据库没就绪、NEXTAUTH_SECRET/URL 没填 | `docker compose logs ztnet`，看 prisma migrate / env 校验报错 |
| 面板能开但“看不到控制器/网络列表空” | `ZT_ADDR` 错、authtoken 读不到、来源网段被 `allowManagementFrom` 拒 | 用第 5 节的 curl 直接调 `/status`；检查 `ALLOW_MANAGEMENT_FROM` 是否覆盖 compose 子网 |
| 面板报 401/403 调控制器失败 | authtoken 变了但 ztnet 没重启 | `docker compose restart ztnet` |
| 客户端装了 planet 还是连不上 | 9994/udp 没放行、planet 里的 IP 不是客户端可达地址 | `scripts/stack-status.sh` 看 world 端点；用 `nc -u -z <IP> 9994` 之外的方法（UDP 探测）或 `e2e-verify.sh` |
| 客户端 `ACCESS_DENIED` | 成员未授权（私有网络） | ZTNet 面板里授权该成员，或建公开网络 |
| 客户端一直 `REQUESTING_CONFIGURATION`，但 `peers` 里 PLANET 是 DIRECT | 控制器 identity 与 network id 前缀不一致（卷被重建过 / 数据是从别的服务器拷来的） | 见 6.4：换回原身份后只重建 planet |
| 换回 identity 后容器起不来，日志 `moon.json belongs to ...` | `moon.json` 还属于上一个身份 | 删 `moon.json` 与 `moons.d/*.moon` 再起（6.4 第 4 步） |
| 备份出来的 `planet-data` 里 identity 与线上不一致 | 部署用的是 bind mount，备份的却是同名命名卷 | 按 1.1 的说明用 `docker inspect ... .Mounts` 确认实际数据目录 |
| `/planet` 返回 401 | token 已启用 | 加 `?token=` 或 `Authorization: Bearer` |
| `/planet` 内容与容器内不一致 | 反向代理缓存/压缩 | 走 Caddy 直连，别加 CDN |
| 换 IP 后所有客户端失联 | planet 端点变了但客户端还是旧 planet | 重新分发 planet（第 4 节） |
| `docker compose up` 报端口占用 | 3000/9994 被别的服务占了 | 用 `--files-port` / `--zt-port` / `--ztnet-port` 换端口后重跑 deploy.sh |
