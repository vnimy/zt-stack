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
  手机在 ZeroTier 里点“保存并同步”或开自动更新，桌面端重跑 `clients/` 脚本。
- 旧服务器若还在跑且用的是同一个 identity，**必须先停掉**，否则两台同身份互相冲突。
- 已在册的成员不需要重新 join，授权与固定 IP 原样生效；**新**连上的设备仍要在面板授权。

### 6.5 让 Android 客户端常驻（前台服务 / 开机自启）

客户端连接后现在是**前台服务**：状态栏有一条常驻通知（“已连接 · <网络 id>”），切后台或息屏不会被系统回收；通知右侧的「断开连接」按钮等同于在 app 里断开，走同一套清理流程。

- 通知权限被拒时 `startForeground` 会失败并退回普通通知（行为同旧版本），此时服务仍可能被系统回收 —— 去系统设置里给 ZeroTier 打开通知权限即可。
- **开机自启不由 app 负责**：旧版的 `BOOT_COMPLETED` 接收器是空实现（只打一行日志，manifest 也没有权限），阶段4 已删除。要开机自动连，用系统能力：
  设置 → 网络和互联网 → VPN → ZeroTier 右侧齿轮 → 打开「始终开启的 VPN」（Always-on VPN）；
  需要更严格时再开「阻止未使用 VPN 的连接」。
- 国产 ROM（MIUI / EMUI / ColorOS / OriginOS 等）会额外清理后台：把 app 加入「自启动/后台运行」白名单，电池策略设为「不限制」。

### 6.6 发布 Android 新版本（客户端检查更新）

客户端「设置 → 关于 → 检查更新」会请求**行星服务器同域的** `/version.json`，比较 `versionCode` 后提示下载。整条链路只有两个文件，都放在数据目录里，改完立即生效（服务每次请求重读，不用重启容器）：

```bash
cd /root/docker/zerotier

# 1) 放安装包（名字必须是 zerotier.apk）
cp /path/to/ZeroTier-1.16.2-debug.apk planet-data/zerotier.apk
sha256sum planet-data/zerotier.apk     # 记下来，写进清单

# 2) 写清单（versionCode 必须大于用户已装版本才会提示）
cat > planet-data/version.json <<'EOF'
{"versionCode": 21, "versionName": "2.0.3",
 "url": "https://zt.vnimy.com/app/zerotier.apk",
 "notes": "这次改了什么，客户端弹窗里会原样显示"}
EOF

# 3) 自检
curl -s https://zt.vnimy.com/version.json
curl -sI https://zt.vnimy.com/app/zerotier.apk | head -1
```

要点：

- `versionCode` 是唯一判据，必须**大于**用户当前装的版本；`versionName` 只用于显示。发版前先改 app 里 `app/build.gradle` 的 `versionCode`/`versionName` 再构建。
- 2.0 起安装包文件名为 `zerotier.apk`；`planet-files.py` 同时保留 `/app/zerotierfix.apk` 作为旧路径别名，指向同一个文件。
- 2.0 的包名是 `com.vnimy.zerotier`，与旧版 `net.kaaass.zerotierfix` 不互通；旧版不会覆盖升级，需要卸载旧版后重新安装，并重新添加网络。
- `url` 写公网地址；客户端只负责用系统浏览器打开它，不下载也不静默安装。
- 反代（nginx）需要把 `/version.json` 与 `/app/` 两条转给 3000 端口；仓库里的 `docs/NGINX-反代.md` 已包含。漏配时表现为客户端提示「检查更新失败」。
- 想强制所有客户端都更新时，不要改 `versionCode` 玩花招（App 会一直提示），直接发通知/公告即可。

### 6.7 下载页与二维码

`https://zt.vnimy.com/dl/`（或直连 `http://<IP>:3000/`）是同一个下载页，列出 `/planet`、`/moons` 与 Android 客户端，并显示：

- 当前客户端版本与体积 —— 读 `planet-data/version.json` 与 `planet-data/zerotier.apk`，没有这两个文件就只显示 planet 部分
- planet 的二维码（`/qr.svg`），手机「设置 → 行星服务器 → 扫描二维码导入」直接扫，扫到的就是页面下方印的 `https://<域名>/planet`
- `/qr.svg?path=/app/zerotier.apk` 可换成客户端安装包的二维码
- 页面**默认中文**，右上角 `中文 · English` 切换；选择记在 cookie `lang`（一年），也可直接访问 `?lang=en` / `?lang=zh`，`?lang=` 优先于 cookie，值不认识时回落到 cookie/中文

二维码由 `planet-node/vendor/qrcodegen.py` 生成（Nayuki, MIT，来源与 sha256 见 `planet-node/vendor/README.md`），容器里以 `./qrcodegen.py:/usr/local/bin/qrcodegen.py:ro` 挂进去。这个文件缺失时页面只是不显示二维码、`/qr.svg` 返回 503，其余端点不受影响。

反代需要额外放行 `location = /qr.svg`、`location = /dl`、`location ^~ /dl/`（见 `docs/NGINX-反代.md`）；二维码里的域名来自请求的 `X-Forwarded-Proto`/`Host`，所以从 https 入口访问时二维码才带 `https://`。

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
| `/qr.svg` 返回 503 | 容器里没有 `qrcodegen.py`（挂载漏了） | 补 `./qrcodegen.py:/usr/local/bin/qrcodegen.py:ro` 后重建 zerotier |
| `/dl/` 404 或打开是面板 | 反代没放行 `/dl`、`/dl/` | 按 `docs/NGINX-反代.md` 补 location 后 `nginx -s reload` |
| 换 IP 后所有客户端失联 | planet 端点变了但客户端还是旧 planet | 重新分发 planet（第 4 节） |
| `docker compose up` 报端口占用 | 3000/9994 被别的服务占了 | 用 `--files-port` / `--zt-port` / `--ztnet-port` 换端口后重跑 deploy.sh |

---

## 8. 资产坐标与线上实例

### 8.1 版本与校验值

| 资产 | 位置 / 标识 | 校验值 |
|---|---|---|
| 行星节点镜像 | `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2` | `sha256:d4f91480ae9e973c9d5f8b349e34eb77d0e6fc7bd74772223f4e0584c2b0d336`，180 MB |
| 本地同名 tag | `zt-stack/planet-node:1.16.2` | 同一 image id `d4f91480ae9e`（历史兼容名） |
| 客户端镜像 | `ccr.ccs.tencentyun.com/vnimy/zerotier-client:1.16.2`（`client-node/`，只从行星镜像取二进制） | `sha256:6a94e872946e464bdb361063cbdfd9bc5b112e0c92c4fc0bf1f38156cd0b7ad4`，38,384,335 B |
| Android 客户端 | 交付 `artifacts/ZeroTier-1.16.2-debug.apk`（core 1.16.2 + edge-to-edge + 前台服务/通知断开 + 路由表/扫码导入 + 网络切换自愈 + 检查更新 + 快捷设置磁贴（长按打开 App）+ 包名迁移 + 扫码添加网络 + 官方橙色主题 + 快捷磁贴即时刷新，versionCode 21 / 2.0.3，包名 `com.vnimy.zerotier`）<br>旧包名回退 `artifacts/ZerotierFix-1.16.2-debug.apk`（1.0.13）<br>阶段1 回退 `artifacts/ZerotierFix-1.12.2-debug.apk`（core 1.12.2） | 2.0.3：23,909,378 B，`sha256:4e754f3f4883edda651bead51f2d98340214908a64a5eaeffd8a1b4e7f1214df`<br>1.0.13：23,906,940 B，`sha256:e03413a83b8593b3dc6d04fa48a07566a725fbcbb31548c5210d9a639dee0796`<br>1.12.2：22,736,354 B，`sha256:e0622299f9c137520d76e4a3bde2e874aeafcc63de35c7cf3da947587674cd91` |
| 离线发布包 | `release/dist/`（由 `release/build-release.sh` 生成，**不入库**） | tar `planet-node-1.16.2.tar.gz` 44,009,044 B，`sha256:6da744fc6f665943b557229cafe2fcf807ae35603574ad262000581a164664c4` |
| 镜像源码 | `planet-node/`（Dockerfile + entrypoint + vendored mkworld） | 构建基准 = ZeroTierOne tag `1.16.2`（commit `a5807560`） |

镜像、APK、客户端镜像三者版本必须一致：镜像 tag 与 ZT 版本绑定（`PLANET_NODE_TAG`），APK 内嵌 core 与镜像同为 **1.16.2**（1.12.2 版保留作回退）。

### 8.2 线上实例（zt.vnimy.com）

线上与仓库默认形态有差异，备份/巡检前先看这张表：

| 项 | 线上实际值 |
|---|---|
| 服务器 / 目录 | `81.69.244.33`（`VM-0-17-ubuntu`），`/root/docker/zerotier/`，compose 项目名 `zt-stack` |
| 数据卷 | **bind mount** `./planet-data:/var/lib/zerotier-one`；**不是**命名卷 `zt-stack_planet-data`（早期实验残留，identity `e3414c140d`，与线上无关） |
| 下载服务 | `./planet-files.py` 单独 bind mount 到 `/usr/local/bin/planet-files.py:ro`，改脚本不用重编镜像；`version.json` 与 `zerotier.apk` 直接放 `planet-data/`（见 6.6） |
| 二维码 | `./qrcodegen.py`（vendored，Nayuki MIT）挂到 `/usr/local/bin/qrcodegen.py:ro`；下载页 `https://zt.vnimy.com/dl/`，二维码 `https://zt.vnimy.com/qr.svg`（见 6.7） |
| 外部反代 | 容器 `nginx`（镜像 `nginx-with-auth`），配置在宿主机 `/root/docker/nginx/conf.d/zerotier.conf`，示例见 `docs/NGINX-反代.md` |
| 端口 | `ZT_PORT=9993`（仓库默认 9994）；面板 3001 由外部 nginx 反代到 443 |
| planet 下载 | `https://zt.vnimy.com/planet`（nginx 直通 3000，TLS 为 ZeroSSL 正式证书） |
| 控制器 | identity `e5c9db4519`，唯一网络 `e5c9db4519e04fa5`（`Vnimy-Home`，192.168.200.0/24） |
| 备份 | 卷就是目录：`tar czf planet-data.$(date +%F).tgz -C /root/docker/zerotier planet-data` |

> 2026-11-10 该实例的卷内 identity 丢失，被 entrypoint 重新初始化成 `f8809c479a`，而网络 id 前缀仍是旧的 `e5c9db4519` → 客户端永远停在 `REQUESTING_CONFIGURATION`。恢复流程见 6.4。

---

## 9. 已知问题与限制

| 类别 | 事项 | 现状 / 规避 |
|---|---|---|
| 环境 | 私有仓库 pull 偶发 `failed to fetch oauth token: … unexpected EOF` | 重新 `docker login` 即恢复；`install.sh` 已识别并给出人话提示 |
| 环境 | WSL `/mnt/d` 是 DrvFs，`chmod 600 .env` 无效（仍 777） | `check_env_perms()` 显式告警；Linux 原生盘上不存在此问题 |
| 设计 | 只改 `.env` 开关而 compose 判定无变化 → 重建被静默吞掉 | 重建路径必须 `up -d --no-deps --force-recreate zerotier`（脚本已内置） |
| 设计 | ZTNet 面板的 Planet / 端口管理功能会与 entrypoint 抢同一卷的 `planet`、`local.conf` | **不要使用**；面板只用网络与成员管理 |
| 设计 | 换 IP 后 planet 不会自动推送 | 必须人工重新分发；Android 有「每次启动重下 + sha256」开关可缓一口气 |
| 事故 | 控制器 identity 被重建，客户端一直 `REQUESTING_CONFIGURATION` | 2026-11-10 线上实例发生并已恢复，见 6.4 |
| 未验证 | 真域名 ACME 签发 | 仅用 `tls internal` 自签实测过反代分流；生产需域名解析 + 80/443 |
| 未验证 | 全新空卷首次 `initdb` | 开发机数据卷已被旧口令初始化，无法原地验证；**请在新服务器首次部署时确认一次** |
| 未验证 | `deploy.sh --upgrade` / `install.sh --upgrade` | 本机 registry 太慢未实跑；代码路径与常规 up 相同 |
| 未验证 | macOS 客户端脚本 | 仅 `bash -n` + 在 Linux 上跑通同逻辑；`launchctl` 与 `/Library/Application Support` 未真机验证 |
| 未验证 | Android 各阶段的真机走查 | 1.16.2 APK 已在真机安装并连上 `Vnimy-Home`；edge-to-edge、通知断开、扫码导入、检查更新尚未逐项拍照确认 |
| 限制 | Android `minSdk` 21（原 19） | NDK r28c 的 platforms.json 强制；要保 19 需换 NDK r25 |
| 限制 | ZT 1.16 起 controller 许可为商业源码可见 | 自用部署沿用官方口径；对外提供服务需自行确认 |
| 限制 | 单节点无冗余 | 根节点故障期间新 peer 无法上线（已直连的 peer 不受影响） |
| 限制 | planet 下载服务没有限速/防刷 | 生产建议放在 Nginx 后面加 `limit_req` |

### 9.1 还没做的

1. **planet 自动更新通道**（桌面端）：Android 已有「每次启动重下 + sha256」；桌面端可加 systemd timer / 计划任务做 sha 比对替换，并给 `e2e` 加「planet 变更后客户端自动跟上」的断言。
2. 上面五条「未验证」项。
3. 可选：planet 下载限速/防刷；`stack-status.sh` 加告警阈值。

---

## 10. 复算与接手核对

### 10.1 复算命令（别只信文档）

```bash
bash zt-stack/planet-node/verify.sh                 # 43 条：planet 生成、controller、下载、幂等、换 IP 保身份
bash zt-stack/scripts/e2e-verify.sh                 # 端到端：客户端换 planet → peers 出现 PLANET → 网络 OK
bash zt-stack/tests/zerotierfix/run-planet-sync-test.sh D:/Projects/zerotier/ZeroTier-Android   # 28 条
bash zt-stack/clients/test/test-download.sh         # 21 条（Linux/Windows 脚本的下载-校验-替换）
bash zt-stack/release/build-release.sh && (cd zt-stack/release/dist && sha256sum -c SHA256SUMS)
```

注意：`verify.sh` 默认宿主端口 3920/13920，避免与运行中的栈抢 3000/9994。

### 10.2 接手第一小时清单

- [ ] `docker login ccr.ccs.tencentyun.com`，`docker pull ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2`，核对 8.1 的 digest
- [ ] `docker compose up -d`（或 `install.sh -i <IP>`），确认三服务 healthy、`/healthz` 200
- [ ] 浏览器开面板，建一个测试网络；`curl` 下载 planet 并核对首字节 `0x01` 与 `X-File-SHA256`
- [ ] 跑一次 `e2e-verify.sh`，确认 `peers` 里出现 `PLANET`
- [ ] 备份 `planet-data`，记下 identity 前 10 位（网络 id 的前缀就是它）
- [ ] 读 `docs/ARCHITECTURE.md` 第 8、9 节，再动任何与 planet/identity 相关的代码

### 10.3 已核实事实（都是跑过、看过输出的，不是推断）

| 项目 | 结论 |
|---|---|
| `planet-node/verify.sh` | 43 条全过（planet 生成、controller、下载鉴权、幂等、换 IP 保身份） |
| mkworld 产物 | `type=planet`、`signature_valid=true`、root identity 与端点符合预期 |
| 控制器建网 | `POST /controller/network/<控制器10位>______` 返回 16 位 hex 网络 ID |
| 下载鉴权 | `/planet` 无 token 401，带 token 200（257 字节），`X-File-SHA256` 与文件一致 |
| 三服务状态 | zerotier / ztnet / postgres 均 healthy |
| 端到端 | 客户端换 planet 后 peers 出现 `PLANET ... DIRECT <IP>:<端口>`，`listnetworks` 返回 `OK` |
| 换 IP | 保留 identity / authtoken / network id，planet 重新签名后客户端仍接受 |
| Android 构建 | core 1.16.2 双 ABI 可构建，JVM 端 28 条断言通过，真机已连上 Vnimy-Home |
| 桌面脚本 | Linux 21 条、Windows 25 条下载-校验-替换自测通过 |
| 部署形态 | 纯 compose 与 `install.sh` 两条路都能起来；镜像可 push / 按 digest 回拉 |
| 容器客户端 | 指定 `PLANET_URL` 即自动 join，授权后拿到 `192.168.200.x` |
