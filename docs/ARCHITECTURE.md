# 架构说明（zt-stack）

自建 ZeroTier 行星（根）节点 + 控制面板的组件关系、端口、数据流，以及为什么单节点、
和官方 planet 的差异与限制。所有涉及 ZTNet 行为的结论都标了源码位置，可自行复核。

---

## 1. 组件关系

```
                        公网
                          |
        ┌─────────────────┼──────────────────────────────┐
        │  UDP/TCP 9994   │  TCP 3000          TCP 3000  │
        v                 v                    v          │
 ┌──────────────────────────────────────────────────────┐ │
 │ docker compose 项目 zt-stack（一个 bridge 网络）      │ │
 │                                                      │ │
 │  ┌────────────────────────────┐   ┌───────────────┐  │ │
 │  │ zerotier  (planet-node)    │   │ ztnet         │  │ │
 │  │  9993/tcp+udp  控制API      │◄──┤ 3000 Next.js  │  │ │
 │  │  9993/udp      peer 传输    │X- │ 面板 + API    │  │ │
 │  │  3000/tcp      planet 下载  │ZT1│ 面板宿主 3001  │  │ │
 │  │                            │Auth└───────┬───────┘  │ │
 │  │  /var/lib/zerotier-one     │            │ SQL      │ │
 │  │  ├ identity.secret/public  │      ┌─────▼───────┐  │ │
 │  │  ├ authtoken.secret  ◄─────┼──────┤ postgres:15 │  │ │
 │  │  ├ planet  (world, 本节点)  │ 同一卷 └─────────────┘  │ │
 │  │  ├ moons.d/*.moon          │                        │ │
 │  │  └ controller.d/ (网络库)   │                        │ │
 │  └────────────────────────────┘                        │ │
 │                                                        │ │
 │  [profile tls] caddy: 80/443 → / = ztnet:3000          │ │
 │                                 /planet,/moons,/moon/* │ │
 │                                      = zerotier:3000   │ │
 └────────────────────────────────────────────────────────┘
```

三个常驻服务（默认 profile）+ 一个可选服务（tls profile）：

| 服务 | 镜像 | 容器内端口 | 宿主默认端口 | 作用 |
|------|------|------------|--------------|------|
| zerotier | `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2` | 9993/tcp、9993/udp、3000/tcp | 9994/tcp、9994/udp、3000/tcp | 行星根节点 + 内建 controller + planet 下载服务 |
| ztnet | `sinamics/ztnet:latest`（默认走 1panel 镜像源） | 3000/tcp | 3001/tcp | Web 面板、成员/网络管理、REST API |
| postgres | `postgres:15-alpine` | 5432/tcp | 不发布 | ZTNet 数据库 |
| caddy（可选） | `caddy:2-alpine` | 80、443 | 80、443 | 域名 + 自动 HTTPS，同域反代面板与下载 |

命名卷：`planet-data`（ZeroTier 身份/planet/controller 数据）、`postgres-data`、
`caddy-data`/`caddy-config`。

---

## 2. 端口与数据流

### 2.1 客户端加入网络

1. 客户端读取自己数据目录里的 `planet`，把根节点地址解析成 `PUBLIC_IPV4:ZT_PORT`。
2. 客户端向根节点 9994/udp 发送 HELLO，根节点回自己的 identity 与下游 peer 列表（中继/寻路）。
3. 客户端带着 network id 直接向 **控制器**（同一个进程，9993/tcp 的 JSON API）请求网络配置，
   但请求由节点自己的加密通道（VL1）承载，不需要任何 HTTP 端口对公网开放。
4. 成员未授权时网络状态是 `ACCESS_DENIED`，管理员在 ZTNet 里授权后变 `OK`。

> 结论：客户端只需要 **UDP（和回退用的 TCP）9994** 可达，不需要访问面板端口（宿主 3001）。

### 2.2 ZTNet 与控制器之间

- ZTNet 通过 HTTP 调 `http://zerotier:9993` 的 JSON API，认证方式是 `X-ZT1-Auth: <authtoken>`。
- 这条链路只发生在 compose 内部网络；9993 对外发布只是为了运维排查，可以不下发到公网。
- 控制器的 `allowManagementFrom` 限制来源网段，compose 子网必须落在
  `ALLOW_MANAGEMENT_FROM`（默认 `172.16.0.0/12`）里，否则 ZTNet 的请求会被拒；
  loopback 永远允许。

### 2.3 planet 下载

```
客户端/安装脚本 ──HTTP GET /planet──► zerotier:3000 (planet-files.py)
                                     ├ 无 token 且 DOWNLOAD_TOKEN 为空 → 直接返回 planet
                                     ├ ?token=xxx        → 校验
                                     └ Authorization: Bearer xxx → 校验
```

`/healthz` 永远不需要凭据（compose 健康检查就用它）。响应头 `X-File-SHA256`
给出文件摘要，便于客户端校验。

---

## 3. ZTNet 如何得知控制器地址（源码证据）

**结论：默认就是 `http://zerotier:9993`（Docker 环境下的硬编码默认值），
可用 `ZT_ADDR` 环境变量覆盖；口令默认读 `/var/lib/zerotier-one/authtoken.secret`。
因此 compose 里容器名/主机名必须叫 `zerotier`。**

证据（ZTNet 仓库 `sinamics/ztnet` main 分支）：

1. `src/server/api/services/controllerOptionsService.ts:50-58` —— 默认地址按“是否在容器里”二选一：

   ```ts
   export const getDefaultLocalControllerUrl = () => {
       defaultLocalControllerUrl ??= isRunningInDocker()
           ? "http://zerotier:9993"
           : "http://127.0.0.1:9993";
       return defaultLocalControllerUrl;
   };
   ```

2. `src/utils/docker.ts` —— `isRunningInDocker()` 判据是 `/.dockerenv` 或
   `/proc/1/cgroup` 含 `docker`；我们的 ztnet 容器必然命中，所以默认值就是
   `http://zerotier:9993`。

3. `src/utils/ztApi.ts:194-201` —— 每次请求时的优先级解析：

   ```ts
   return {
       localControllerUrl: process.env.ZT_ADDR || stored.url || getDefaultLocalControllerUrl(),
       request: { headers: {
           "X-ZT1-Auth": process.env.ZT_SECRET || stored.secret || ZT_SECRET,
   ```

   即 **环境变量 > 面板里管理员保存的值 > 默认值/文件**。compose 里我们显式给了
   `ZT_ADDR=http://zerotier:9993`，把它钉死，避免有人在面板里改成别的地址后“看起来能用”。

4. `src/utils/ztApi.ts:35-58` —— `ZT_FOLDER` 固定为 `/var/lib/zerotier-one`
   （freebsd 除外），口令文件默认 `${ZT_FOLDER}/authtoken.secret`，可用 `ZT_SECRET_FILE` 覆盖；
   **该文件在模块加载时只读一次**，所以 planet 重建导致 authtoken 变化后，必须
   `docker compose restart ztnet` 才能生效。

5. 卷的挂载方式：ZTNet 的 `Dockerfile:103` 里 `# USER nextjs` 是注释掉的 —— 容器以
   **root** 运行；`Dockerfile:84` 还会 `chmod -R 777 /var/lib/zerotier-one`。
   因此共享卷读 `authtoken.secret`（0600 root）没有权限问题，官方 compose 也是直接挂同一个卷。

6. 官方 compose 的旁证：`docker-compose.yml` 里 `hostname: zerotier`、
   `ZT_ALLOW_MANAGEMENT_FROM=172.31.255.0/29` 与其子网 `172.31.255.0/29` 对应；
   我们把子网换成 `172.28.0.0/24`，`ALLOW_MANAGEMENT_FROM` 用镜像默认的
   `172.16.0.0/12`（覆盖 172.28.0.0/24）。

---

## 4. 1.16.2 的 controller API 与 ZTNet 是否兼容

**结论：兼容。ZTNet 建网走的是“legacy 建网路径” `POST /controller/network/<10位节点地址>______`，
这条路径在 ZeroTier 1.16.2 的 `EmbeddedNetworkController` 里仍然注册着。**

证据 A（ZTNet 侧，`src/utils/ztApi.ts:390-405`）：

```ts
const controllerStatus = (await get_controller_status(ctx, isCentral)) as ZTControllerNodeStatus;
return await postData<ZTControllerCreateNetwork>(
    `${localControllerUrl}/controller/network/${controllerStatus.address}______`,
    request, payload,
);
```

即先 `GET /status` 取 `address`（10 位十六进制节点地址），再 POST 到
`/controller/network/<address>______`。

证据 B（ZeroTier 1.16.2 侧，`nonfree/controller/EmbeddedNetworkController.cpp`）：

```cpp
952: std::string networkListPath            = "/controller/network";
954: std::string networkPath                = "/controller/network/([0-9a-fA-F]{16})";
955: std::string oldAndBustedNetworkCreatePath = "/controller/network/([0-9a-fA-F]{10})______";
956: std::string memberListPath             = "/controller/network/([0-9a-fA-F]{16})/member";
958: std::string memberPath                 = "/controller/network/([0-9a-fA-F]{16})/member/([0-9a-fA-F]{10})";

1142: s.Put(oldAndBustedNetworkCreatePath, createNewNetworkOldAndBusted);
1143: s.Post(oldAndBustedNetworkCreatePath, createNewNetworkOldAndBusted);
```

证据 C（节点 JSON API 路径，`service/OneService.cpp:1748-1752`）：

```cpp
1748: std::string networkListPath = "/network";
1750: std::string peerListPath  = "/peer";
1752: std::string statusPath    = "/status";
```

ZTNet 用到的 `/status`、`/peer`、`/controller/network...` 三条路径在 1.16.2 全都存在
（实测结果见 README 的验收记录与 `scripts/e2e-verify.sh` 的输出）。

> 注意：1.16.2 **不**接受 `POST /controller/network/<自选id>`（`networkPath` 正则只匹配
> 16 位十六进制，且只用于更新），所以任何“先自己生成 id 再 POST”的实现都会 404。
> ZTNet 不走那条路，因此没有影响。

---

## 5. 为什么是单节点

- ZeroTier 的根节点（planet 的 root）本质上只做两件事：为 peer 提供初始寻路信息、在直连失败时中继。
  个人/小团队规模下，一个根节点 + 一个 controller 实例完全够用，而且 planet 里可以只写一个 root。
- controller 与根节点合体（`ZT_NONFREE=1` 的内建 controller）省掉一个容器、一次网络配置，
  以及“controller 不在 planet 里”的额外延迟。
- 代价是单点故障：根节点挂掉期间，**已建立直连的 peer 之间仍然能通信**（它们互相记得路径），
  但新 peer 上线、NAT 打洞失败时的中继会不可用。要做到高可用必须上多 root，
  那需要把 planet 的 roots 数组扩大、并让 controller 的外部数据库共享（超出本栈范围）。

---

## 6. 与官方 planet 的差异与限制

| 维度 | 官方 planet | 本栈 |
|------|-------------|------|
| 根节点数量 | 4 个全球分布 | 1 个（自己那台机器） |
| 根节点地址 | 固定，写死在官方 planet 里 | 你的公网 IP，**换 IP 必须重建 planet 并重新分发给所有客户端**（只重建 world，identity 与 network id 不变，见第 8 节） |
| 覆盖的客户端 | 全世界 | 只有装了你的 planet 的客户端（装之前它们仍在官方网络里） |
| 全球寻路质量 | 优（就近 root） | 取决于你的机器到大江南北的延迟 |
| 抗 DDoS / 冗余 | 有 | 无，自己扛 |
| 受 ZeroTier 官方服务影响 | 是 | 否（除软件许可外） |
| controller | 官方 Central（商业） | 本栈内建（`ZT_NONFREE`）+ ZTNet 面板 |
| 版本兼容 | 自动跟随官方 | 自行决定何时升级；客户端通常可以混版本（1.10+ ↔ 1.16） |
| 许可 | 官方 SaaS 条款 | ZeroTier 源码可用许可：**非商业用途免费**，商业用途需向 ZeroTier 购买许可 |

### 已知限制（务必知情）

1. **planet 是一份“数据库快照”**：客户端只在启动/重连时读取，改 IP 后所有客户端都必须重装 planet。
   注意：重装 planet ≠ 重建身份 —— deploy.sh 换 IP 走 `REGENERATE_WORLD=1`，identity、controller 数据、
   network id、成员授权全部保留，见第 8 节。
2. **planet 文件不进 DNS**：`stableEndpoints` 里是 IP，不支持域名；动态 IP（家用宽带）需要有 DDNS
   也不能直接写域名，只能改 IP 后重建。
3. **不要用 ZTNet 的 Planet/端口管理功能**：它会写同一个卷里的 `planet`、`local.conf`
   （`src/utils/planet.ts:48`、`src/server/api/routers/adminRoute.ts:1178-1277`），
   与 planet-node 的 entrypoint 抢同一个文件，会导致 world id 漂移、端口被改。planet 的所有权归
   `zerotier` 服务。
4. **控制器数据在 `controller.d/`**（SQLite 文件），与 planet/identity 在同一个卷里；
   卷丢了等于所有网络与成员授权丢失（客户端会看到 network 不存在）。
5. **单节点不做 TCP 中继**：镜像的 `local.conf` 里 `allowTcpFallbackRelay=false`，
   客户端只能 UDP 9994。若你的服务器只放行 TCP，需要自己改（不推荐）。
6. 健康检查只看文件服务 `/healthz`，**不代表** controller 可用；controller 健康用
   `scripts/stack-status.sh` 里的 `/status` 检查。

---

## 7. 编排要点（实测踩到的坑，改 compose 前先看）

1. **`HOSTNAME=0.0.0.0` 必须显式给 ztnet**：compose 的 `hostname: ztnet` 会让 Docker 注入
   `HOSTNAME=ztnet`，Next.js standalone server 把它当监听地址，于是只绑容器 IP，
   `127.0.0.1:3000` 上连不上 —— 健康检查全部失败（实测 `curl: (7) Failed to connect`）。

2. **面板与 planet 下载不能共用宿主 3000**：两个服务都要发布端口，实测第二个容器起不来
   （`Bind for 0.0.0.0:3000 failed: port is already allocated`）。因此
   `FILES_PORT=3000`（planet 下载）、`ZTNET_PORT=3001`（面板）。

3. **`NEXTAUTH_URL` 必须等于浏览器实际访问的 URL**：ZTNet 0.8.7 用 better-auth，
   登录请求 `POST /api/auth/sign-in/email` 会校验 Origin，URL 对不上直接
   **403**（实测：`NEXTAUTH_URL=http://192.168.2.145:3001` 时用
   `http://localhost:3001` 登录 → 403；换成同源 URL 立刻 200）。
   改端口/域名后务必同步改 `NEXTAUTH_URL`（deploy.sh 会自动跟）。

4. **authtoken 只读一次**：ZTNet 在模块加载时读 `/var/lib/zerotier-one/authtoken.secret`，
   planet 重建（identity 变了）之后必须 `docker compose restart ztnet`，否则 controller 请求全部 401。

5. **`allowManagementFrom` 要覆盖 compose 子网**：容器内实测 `listeningOn: 172.28.0.3/9993`，
   子网是 `172.28.0.0/24`，镜像默认 `172.16.0.0/12` 覆盖它，所以 ZTNet 能通；
   换 `STACK_SUBNET` 时要同步改 `ALLOW_MANAGEMENT_FROM`。

6. **实测：ZTNet v0.8.7 → 1.16.2 建网成功**。面板点"创建网络"后控制器返回
   `["3417a77156d6fe78"]`，且 network id 前 10 位正好是控制器地址 `3417a77156` ——
   这正是 legacy 建网路径 `/controller/network/<addr>______` 的语义，与第 4 节的静态分析一致。

---

## 8. 重建 world ≠ 重建身份

planet（world）只是“根节点端点列表 + 时间戳 + 签名”，它和节点身份（`identity.secret`，
即 `/status` 里那 10 位 `address`）是两件独立的东西，不要混为一谈。

- **身份变了会怎样**：controller 分配的 network id 以控制器地址为前缀
  （`POST /controller/network/<addr>______` 产出的 id 就是 `<addr>` + 6 位随机十六进制），
  所以换 identity = 所有 network id 失效 = 成员授权全部作废、每个成员要重新 join。
- **world 变了会怎样**：只影响“客户端去哪里找根节点”。换 IP 只需要重写 world，
  identity 与 controller 数据原封不动，network id 与成员授权都不动。

上游的规则（ZeroTier 1.16.2，`node/World.hpp`）：

- `World.hpp:167-177` `shouldBeReplacedBy()`：只有当候选 world 的 **id 相同、type 相同、
  timestamp 更新**，且其签名能被 `_updatesMustBeSignedBy` 验证通过时，客户端才会替换手上的 world。
  所以换 IP 时保留 id 与签名密钥、只改 timestamp 和端点，是最平滑的做法；
  改 id 或换签名密钥等于换了一个 world，客户端不会自动接受，只能人工重发。
- `World.hpp:188-216` `serialize()`（其中 `199-206` 段是签名与 roots 字段）：world 的字节布局是
  `type(1) | id(8) | ts(8) | 更新签名公钥(64) | 签名(96) | roots...`，每个 root 再写
  `identity` + `stableEndpoints`。端点就长在 world 内部 —— 这就是“换 IP 必须重建 world”的根因；
  而 `id` 与公钥是独立字段 —— 这就是“重建 world 不必换 identity”的依据。
  镜像里 `mkworld verify` 打印的 `world_id=` / `timestamp=` / `signing_key=` 正是这几个字段。

因此 planet-node 给了两个正交开关（语义与后果对照见 `docs/OPERATIONS.md` 第 4 节）：

| 开关 | 作用范围 | 典型场景 |
|------|----------|----------|
| `REGENERATE_WORLD=1` | 只重写 planet 与 moons | 换公网 IP / 换通告端口（deploy.sh 自动用） |
| `FORCE_REGENERATE=1` | 连 identity、authtoken、签名密钥一起换 | 私钥泄露、要彻底换身份（`--force-new-identity`） |

两者同时为 1 时 `FORCE_REGENERATE` 优先（entrypoint 会在日志里明示）。

---

## 9. 编译与部署不变量（改镜像前必读）

1. **controller 必须 `ZT_NONFREE=1`**：1.16.0 起 controller 移入 `nonfree/controller/`，只有该开关会把它编译进二进制并定义 `ZT_NONFREE_CONTROLLER`（`make-linux.mk:21-24`；官方 release 目标同样是 `ZT_OFFICIAL=1 ZT_NONFREE=1`）。许可因此变为商业源码可见——自用内部部署沿用官方口径，对外提供控制器服务需自行确认。
   `ENABLE_CONTROLLER=0` 只是占位，没有运行时开关，入口只打印警告。
2. **mkworld 必须 vendored**：`attic/world` 已从 dev 分支删除，仅存在于 `actions` 分支（2024-08-15 `d2c745c`）；1.16.2 的 `node/` 已无 `C25519.*`，生成器必须用它自己那套源码编译。来源与 blob 哈希见 `planet-node/mkworld/README.md`。
3. **ZTNet 的三条硬约束**：`hostname: zerotier` 不能改（默认 `ZT_ADDR=http://zerotier:9993`）；必须挂同一个 `planet-data` 卷（`ZT_SECRET_FILE=/var/lib/zerotier-one/authtoken.secret`，模块加载时只读一次，换过 authtoken 要重启 ztnet）；`HOSTNAME=0.0.0.0`（否则 Next.js 只绑容器 IP，健康检查必挂）。

---

## 10. 术语

| 词 | 含义 |
|---|---|
| planet / world | 根节点清单 + 签名，客户端靠它发现 ZeroTier 网络；本栈生成的 `planet` 文件即 world |
| moon | 可选的额外中继节点定义（`moons.d/*.moon`），本栈同时生成并下载 |
| controller | 网络控制器：建网、发地址、授权成员；本栈内建在每个行星节点里 |
| network id | 16 位 hex，**前 10 位 = 控制器地址** |
| ZTNet | 控制器 Web 面板（Next.js + Postgres），通过 `authtoken.secret` 调 controller API |
| REGENERATE_WORLD | 只重建 planet/moons，保住 identity 与网络 |
| FORCE_REGENERATE | 连 identity 一起换，所有 network id 失效 |
