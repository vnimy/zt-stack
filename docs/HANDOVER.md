# zt-stack 交接文档

> 最后更新：本次会话结束时。所有"已核实"条目都由交接人亲自复算过（不是子代理自报），复算方式见 §7。

## 0. 一句话说明

自建 ZeroTier 行星（planet / 根）服务器：**ZeroTier 1.16.2 源码 + ZT_NONFREE=1 内建 controller**，同一实例既是根节点又是控制器；配 **ZTNet 面板 + PostgreSQL**；planet 由 **vendored mkworld** 生成并通过 HTTP 提供下载；客户端用改造过的 **ZerotierFix**（填服务器地址即可，不需要分发 planet 文件）。

默认镜像：`ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2`

## 1. 资产坐标（拿到就能核对）

| 资产 | 位置 / 标识 | 校验值 |
|---|---|---|
| 行星节点镜像 | `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2` | `sha256:d4f91480ae9e973c9d5f8b349e34eb77d0e6fc7bd74772223f4e0584c2b0d336`，180 MB |
| 本地同名 tag | `zt-stack/planet-node:1.16.2` | 同一 image id `d4f91480ae9e`（历史兼容名） |
| Android 客户端 | `zt-stack/artifacts/ZerotierFix-stage1-debug.apk` | 22,736,354 B，`sha256:e0622299f9c137520d76e4a3bde2e874aeafcc63de35c7cf3da947587674cd91` |
| 离线发布包 | `zt-stack/release/dist/`（13 个文件，7 个顶层条目，64 MB） | tar `planet-node-1.16.2.tar.gz` 44,009,044 B，`sha256:6da744fc6f665943b557229cafe2fcf807ae35603574ad262000581a164664c4` |
| 镜像源码 | `zt-stack/planet-node/`（Dockerfile + entrypoint + vendored mkworld） | 构建基准 = ZeroTierOne tag `1.16.2` = commit `a5807560` |
| 文档 | `zt-stack/README.md`（总入口）、`docs/ARCHITECTURE.md`、`docs/OPERATIONS.md`、`docs/NGINX-反代.md`、`release/README-部署.md`、`release/client/README-客户端.md` | — |

镜像/客户端/发布包三者版本必须一致：镜像 tag 与 ZT 版本绑定（`PLANET_NODE_TAG`），APK 里内嵌 core 仍是 **1.12.2**（见 §8）。

## 2. 目录结构（谁负责什么）

```
zt-stack/
├── planet-node/          行星节点镜像构建方
│   ├── Dockerfile        三段：ZT 源码编译（ZT_NONFREE=1, ZT_SSO_SUPPORTED=0）→ mkworld 编译 → ubuntu 运行时
│   ├── build.sh          从本地 ZeroTierOne 克隆 git archive 指定 tag 后 docker build
│   ├── entrypoint.sh     状态机：首次生成 identity/moon/planet；REGENERATE_WORLD / FORCE_REGENERATE 两档重建
│   ├── planet-files.py   /planet /moons /moon/<n> /healthz / 下载页；token 走 ?token= 或 Bearer
│   ├── mkworld/          vendored 行星生成器（源码来自 actions 分支 d2c745c 的 mkworld.cpp + mainline 5e8e93518 的依赖闭包）
│   └── verify.sh         43 条单容器验收（含"换 IP 保 identity"与"缺 identity 必须拒绝"）
├── compose/              单机编排：zerotier + postgres + ztnet（+ profile tls 的 caddy）
├── scripts/              deploy.sh / stack-status.sh / e2e-verify.sh / lib.sh（源码形态）
├── release/              镜像优先形态（服务器不装源码）：build-release.sh、install.sh、dist/、client/
├── clients/              三平台"填地址装 planet"脚本 + mock 自测
├── patches/zerotierfix/  Android 两枚补丁 + 构建脚本 + JVM 端到端测试（28 条断言）
├── artifacts/            APK 交付物
├── docs/                 ARCHITECTURE / OPERATIONS / NGINX-反代 / 本文
└── .build/               构建缓存与验证脚本（950 MB，可安全删除，gitignored）
```

上游五个仓库（`ZeroTierOne`、`ZerotierFix`、`docker-zerotier-planet`、`zero-ui`、`ztncui`）**只读保留**，本栈未修改它们；ZerotierFix 的改动在它自己的分支 `zt-stack`（两个提交 `ee08598`、`33e2b74`）并同时导出为补丁。

## 3. 已核实的事实（含证据出处）

| 事实 | 证据 |
|---|---|
| 行星节点镜像可用 | `verify.sh` → **43 passed, 0 failed**；`zerotier-cli info` → `… 1.16.2 ONLINE` |
| planet 生成正确 | `mkworld verify` → `type=planet world_id=149604618 signature_valid=true root[0].endpoint[0]=<IP>:<port>` |
| 控制器可用 | 建网返回服务端分配的 16 位 hex（如 `36a2562e224dd581`），可读回 |
| planet 下载受控 | `/planet` 带 token 200（257 B，与容器内 sha256 一致）、无 token 401、`/healthz` 200 |
| 整套栈可跑 | 三服务 healthy；面板 `/auth/login` 200；`compose config` 双 profile 有效 |
| 端到端可用 | `e2e-verify.sh`：客户端 Bearer 下载 planet → join → `peers` 出现 `PLANET … DIRECT <IP>:9994` → `listnetworks … OK` |
| 换 IP 不换身份 | `REGENERATE_WORLD=1` 后 identity/authtoken/network id 不变、planet 时间戳变大、签名仍有效；缺 identity 时 exit 1 拒绝 |
| Android 可构建 | APK 22,736,354 B，双 ABI `libZeroTierOneJNI.so`；JVM 端到端 `PASS=28`；补丁在干净 master 上 `git am` 可应用 |
| 桌面脚本可用 | Linux `PASS=21`、Windows `PASS=25`（mock 服务真实下载/校验/备份/原子替换） |
| 纯 compose 可部署 | 无脚本、仅 `docker compose up -d`：三服务 healthy、`/planet` 401→200、面板 200、planet 端点 = `PUBLIC_IPV4:ZT_PORT` |
| 镜像可分发 | `docker push` 成功（digest 同 §1），`docker login` 后 `docker pull` 成功 |

## 4. 关键设计决策（改之前先读这里）

### 4.1 端点写在签名内容里 → 换 IP 必须重建 world
`World::serialize()` 先写签名、再写各 root 的 `identity` 与 `stableEndpoints`（`node/World.hpp:188-216`，其中 199-206 是签名与端点字段）；`InetAddress` 只存二进制 IP+端口（`InetAddress.hpp:123-125`），没有域名位。客户端发现根的唯一来源是 `Topology::getRootsToContact` 遍历 `stableEndpoints`（`Topology.cpp:254-267`）；为空只是"允许动态路径"（`Topology.cpp:224-226`），不是发现机制。

### 4.2 重建 world ≠ 重建身份 → 换 IP 不必毁掉网络
自建网络的 network id 前 10 位就是控制器地址（实测：控制器 `3417a77156` → 网络 `3417a77156d6fe78`）。客户端替换 world 的条件是「同 id + 新时间戳 + 能用它信任的密钥验签」（`World.hpp:167-177`）。因此设计了两档：

| 开关 | identity | authtoken | controller 数据 / network id | 何时用 |
|---|---|---|---|---|
| `REGENERATE_WORLD=1` | 保留 | 保留（ZTNet 不用重启） | 保留 | 换 IP / 换端口 / 加 IPv6 |
| `FORCE_REGENERATE=1` | 换新 | 变（ZTNet 必须重读） | 全部失效 | 只在确实要新身份时 |

两者同时为 1 时 `FORCE_REGENERATE` 优先（日志会明示）。`REGENERATE_WORLD` 在缺 identity 或签名密钥时**拒绝执行**（避免悄悄换成新身份）。

### 4.3 controller 必须 `ZT_NONFREE=1`
1.16.0 起 controller 移入 `nonfree/controller/`，只有该开关会编译进二进制并定义 `ZT_NONFREE_CONTROLLER`（`make-linux.mk:21-24`，官方 release 目标同样是 `ZT_OFFICIAL=1 ZT_NONFREE=1`）。许可因此变为商业源码可见——**自用内部部署沿用官方口径；对外提供控制器服务需自行确认许可**。`ENABLE_CONTROLLER=0` 是占位，无效（无运行时开关），入口只打印警告。

### 4.4 mkworld 必须 vendored
`attic/world` 已从 ZeroTierOne dev 分支删除，仅存在于 `actions` 分支（2024-08-15 `d2c745c`）。1.16.2 的 `node/` 已无 `C25519.*`，所以生成器必须用它自己那套源码编译。`planet-node/mkworld/README.md` 里有 blob 哈希级别的来源证明。

### 4.5 ZTNet 与 1.16.2 控制器如何对上
ZTNet 建网走 legacy 路径 `POST /controller/network/<控制器10位地址>______`（`ztnet/src/utils/ztApi.ts:401`），1.16.2 的 `EmbeddedNetworkController.cpp:955/1142` 正好注册了它。所以**不需要给镜像打补丁**。注意：`POST /controller/network/<自选id>` 在 1.16.2 是 404（只用于更新）。
ZTNet 侧三个硬约束：`hostname: zerotier` 不能改（默认 `ZT_ADDR=http://zerotier:9993`）、必须挂同一个 `planet-data` 卷（`ZT_SECRET_FILE=/var/lib/zerotier-one/authtoken.secret`，模块加载只读一次）、`HOSTNAME=0.0.0.0`（否则 Next.js 只绑容器 IP，健康检查必挂）。

### 4.6 单节点拓扑
`planet 根节点 = controller = 同一容器`。好处：一个身份、一套数据、备份简单。代价：根节点挂掉时已直连的 peer 仍可通信，但新 peer 上线与 NAT 打洞失败时的中继不可用；无冗余。

## 5. 日常运维（可直接复制）

前置：私有仓库需 `docker login ccr.ccs.tencentyun.com`。

### 5.1 部署（三种形态，任选）

```bash
# A) 纯 compose（需要 .env，最直观）
cd zt-stack/compose && cp .env.example .env && vi .env   # 至少填 PUBLIC_IPV4、NEXTAUTH_URL、NEXTAUTH_SECRET、POSTGRES_PASSWORD、DOWNLOAD_TOKEN
docker compose up -d
docker compose --profile tls up -d                       # 需要 HTTPS 且用自带 Caddy 时

# B) 脚本（自动生成口令、等健康、打印地址）
bash zt-stack/scripts/deploy.sh -i <公网IP>

# C) 镜像优先（服务器不装源码）
bash zt-stack/release/build-release.sh      # 开发机出包到 release/dist/
# 拷 dist/ 到服务器后：
cd dist && bash install.sh -i <公网IP>      # 有 tar 就 load，没有就 pull
```

端口：`9994/tcp+udp`（必须对公网放行，planet 里的端点）、`3000/tcp`（planet 下载）、`3001/tcp`（面板）。走自带 TLS 再加 `80/443`。

### 5.2 客户端接入
- **Android**：装 `artifacts/ZerotierFix-stage1-debug.apk` → 设置 →「行星服务器（自动下载）」填**完整路径到 `/planet`**：`http(s)://<IP>:3000/planet`，token 填下一栏。App 只补协议头，不补路径。
- **Windows/Linux/macOS**：用 `clients/` 下对应脚本，只给**站点根**：`-ServerUrl http://<IP>:3000` / `--server-url http://<IP>:3000`（+ 可选 token）。脚本自己拼 `/planet`（`BASE="${SERVER_URL%/}"; URL="$BASE/planet"`），再备份旧 planet、原子替换、重启服务。
  - 常见错误：给脚本传 `…/planet` 会变成 `/planet/planet` 而 404；给 Android 只传 `http://IP:3000` 会 404。两者要求相反，注意区分。
- **手工**：`curl -fSL "http://<IP>:3000/planet?token=<TOKEN>" -o planet`，放进 `C:\ProgramData\ZeroTier\One\planet` / `/var/lib/zerotier-one/planet` / `/Library/Application Support/ZeroTier/One/planet`；校验：257~276 B、首字节 `0x01`。
- 兜底：`docker cp zt-stack-zerotier:/var/lib/zerotier-one/planet ./planet`。

### 5.3 升级 ZT 版本
```bash
cd zt-stack/planet-node && ./build.sh                     # 默认 tag 1.16.2；换版本：ZT_TAG=1.16.3 ./build.sh
# 或改 compose/.env 的 PLANET_NODE_TAG 后 docker compose up -d
```
镜像 tag 与 ZT 版本绑定。升级只换镜像，数据卷不动（identity、planet、controller 数据库都在卷里）。

### 5.4 换 IP
```bash
# 改 .env：PUBLIC_IPV4=<新IP>，REGENERATE_WORLD=1
docker compose up -d --no-deps --force-recreate zerotier
# 起来后把 REGENERATE_WORLD 改回 0
```
结果：identity / authtoken / network id / 成员授权全部不变；**planet 端点变了，所有客户端必须重新下载 planet**（planet 不会自动推送）。`deploy.sh` 检测到 IP 变化会自动走这条路径。

### 5.5 备份 / 恢复
```bash
docker run --rm -v zt-stack_planet-data:/d -v $(pwd):/b alpine tar czf /b/planet-data.tgz -C /d .
docker run --rm -v zt-stack_postgres-data:/d -v $(pwd):/b alpine tar czf /b/postgres-data.tgz -C /d .
```
`planet-data` 里是 `identity.secret/public`、`authtoken.secret`、`planet`、`moons.d/`、`controller.d/`、`networks.d/` 与 world 签名密钥——**丢了这个卷等于丢了整个控制器**。

### 5.6 健康检查与排障
```bash
bash zt-stack/scripts/stack-status.sh          # 服务状态 + planet world id + 控制器 + 下载端点
curl -s http://127.0.0.1:3000/healthz          # ok
docker logs zt-stack-zerotier --tail 50        # 首次启动看 planet 生成与 moon 写入
```

### 5.7 外部 Nginx 反代
见 `docs/NGINX-反代.md`（配置已用真实 nginx 1.24 跑过 `nginx -t`）。三条铁律：`NEXTAUTH_URL` 必须逐字等于浏览器地址；`/planet`、`/moons`、`/moon/`、`/healthz` 直通 3000；**9994 tcp+udp 不能被反代，必须继续对公网放行**。

## 6. 已知问题与限制

| 类别 | 事项 | 现状 / 规避 |
|---|---|---|
| 环境 | 私有仓库 pull 偶发 `failed to fetch oauth token: … unexpected EOF` | 重新 `docker login` 即恢复；`install.sh` 已识别并给出人话提示 |
| 环境 | WSL `/mnt/d` 是 DrvFs，`chmod 600 .env` 无效（仍 777） | `check_env_perms()` 显式告警；Linux 原生盘上不存在此问题 |
| 设计 | 只改 `.env` 开关而 compose 判定无变化 → 重建被静默吞掉 | 重建路径必须 `up -d --no-deps --force-recreate zerotier`（脚本已内置） |
| 设计 | ZTNet 面板的 Planet / 端口管理功能会与 entrypoint 抢同一卷的 `planet`、`local.conf` | **不要使用**；面板只用网络与成员管理 |
| 设计 | 换 IP 后 planet 不会自动推送 | 必须人工/SD 卡重新分发；后续可做客户端自动更新（§8） |
| 未验证 | 真域名 ACME 签发 | 仅用 `tls internal` 自签实测过反代分流；生产需域名解析 + 80/443 |
| 未验证 | 全新空卷首次 `initdb` | 开发机数据卷已被旧口令初始化，无法原地验证；**请在新服务器首次部署时确认一次** |
| 未验证 | `deploy.sh --upgrade` / `install.sh --upgrade` | 本机 registry 太慢未实跑；代码路径与常规 up 相同 |
| 未验证 | macOS 客户端脚本 | 仅 `bash -n` + 在 Linux 上跑通同逻辑；`launchctl` 与 `/Library/Application Support` 未真机验证（已约定接受文档级支持） |
| 未验证 | Android 真机闭环 | 只做了 JVM 端到端与源码路径核对，无设备实测 |
| 限制 | Android `minSdk` 21（原 19） | NDK r28c 的 platforms.json 强制；要保 19 需换 NDK r25 |
| 限制 | ZT 1.16 起 controller 许可为商业源码可见 | 自用部署沿用官方口径；对外提供服务需自行确认 |
| 限制 | 单节点无冗余 | 根节点故障期间新 peer 无法上线 |
| 限制 | planet 下载服务没有限速/防刷 | 生产建议放在 Nginx 后面加 `limit_req` |

## 7. 复算方式（别只信文档）

```bash
bash zt-stack/planet-node/verify.sh                 # 43 条：planet 生成、controller、下载、幂等、换 IP 保身份
bash zt-stack/scripts/e2e-verify.sh                 # 端到端：客户端换 planet → peers 出现 PLANET → 网络 OK
bash zt-stack/patches/zerotierfix/test/run-planet-sync-test.sh D:/Projects/zerotier/ZerotierFix   # 28 条
bash zt-stack/clients/test/test-download.sh         # 21 条（Linux/Windows 脚本的下载-校验-替换）
bash zt-stack/release/build-release.sh && (cd zt-stack/release/dist && sha256sum -c SHA256SUMS)
```
注意：`verify.sh` 默认宿主端口 3920/13920，避免与运行中的栈抢 3000/9994。

## 8. 尚未完成（接手后的路线）

1. **ZerotierFix core 1.12.2 → 1.16.2**（阶段2）：需要 NDK + Rust 交叉编译（rustybits），JNI 层 `java/CMakeLists.txt` 仍在，但节点源码依赖 Rust 静态库。这是最大的未完成项，风险也最高。
2. **planet 自动更新通道**：Android 已有"每次启动重新下载 + sha256"开关；桌面端可加 systemd timer/计划任务做 sha 比对替换；再给 `e2e` 加"planet 变更后客户端自动跟上"的断言。
3. 真域名 ACME、空卷 initdb、`--upgrade`、macOS 真机、Android 真机 五项验证。
4. **基线已建**：`zt-stack` 已 `git init`（`main` 分支，首个提交 + tag `baseline/handover-2026-11-10`）。`.gitignore` 忽略 `.build/`、`compose/.env`、整个 `release/dist/` 与全部 `*.apk`；APK 与发布包仍留在磁盘上，但换机器需另行拷贝或用 `release/build-release.sh` 重新生成。此后改动请先开分支。
5. 可选：给 `planet` 下载加限速/防刷；给 `stack-status.sh` 加告警阈值。

## 9. 接手第一小时清单

- [ ] `docker login ccr.ccs.tencentyun.com`，`docker pull ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2`，核对 §1 的 digest
- [ ] `docker compose up -d`（或 `install.sh -i <IP>`），确认三服务 healthy、`/healthz` 200
- [ ] 浏览器开面板，建一个测试网络；`curl` 下载 planet 并核对首字节 `0x01` 与 `X-File-SHA256`
- [ ] 跑一次 `e2e-verify.sh`，确认 `peers` 里出现 `PLANET`
- [ ] 备份 `planet-data` 卷，记下 identity 前 10 位（网络 id 的前缀就是它）
- [ ] 读 §4 的三条设计决策，再动任何与 planet/identity 相关的代码

## 10. 术语

| 词 | 含义 |
|---|---|
| planet / world | 根节点清单 + 签名，客户端靠它发现 ZeroTier 网络；本栈生成的 `planet` 文件即 world |
| moon | 可选的额外中继节点定义（`moons.d/*.moon`），本栈同时生成并下载 |
| controller | 网络控制器：建网、发地址、授权成员；本栈内建在每个行星节点里 |
| network id | 16 位 hex，**前 10 位 = 控制器地址** |
| ZTNet | 控制器 Web 面板（Next.js + Postgres），通过 `authtoken.secret` 调 controller API |
| REGENERATE_WORLD | 只重建 planet/moons，保住 identity 与网络 |
