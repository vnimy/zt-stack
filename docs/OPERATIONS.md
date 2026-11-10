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

更有用的是把它拆开看：

```bash
docker run --rm -v zt-stack_planet-data:/data:ro alpine ls -la /data
# identity.secret / identity.public / authtoken.secret / planet / local.conf
# moons.d/*.moon / controller.d/（下 head 为 SQLite，控制器所有网络都在这里）
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
| `/planet` 返回 401 | token 已启用 | 加 `?token=` 或 `Authorization: Bearer` |
| `/planet` 内容与容器内不一致 | 反向代理缓存/压缩 | 走 Caddy 直连，别加 CDN |
| 换 IP 后所有客户端失联 | planet 端点变了但客户端还是旧 planet | 重新分发 planet（第 4 节） |
| `docker compose up` 报端口占用 | 3000/9994 被别的服务占了 | 用 `--files-port` / `--zt-port` / `--ztnet-port` 换端口后重跑 deploy.sh |
