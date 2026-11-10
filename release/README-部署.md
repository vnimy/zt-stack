# 部署（服务器侧，不需要源码）

> 服务器只需要 **Linux + Docker Engine + docker compose v2**。这个目录就是全部：
> 不需要 git clone、不需要源码树、不需要 Go/编译器。
> 镜像默认从私有仓库 `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>` 拉（第 1 节）；
> 服务器出不了外网时用目录里的 tar 离线装（第 2 节）。

## 0. 包里有什么

| 文件 | 用途 |
| --- | --- |
| `planet-node-<tag>.tar.gz` | 离线备选：行星节点镜像（`docker save` 出来的），registry 不可用时 `install.sh` 自动 `docker load` |
| `install.sh` | 安装脚本（参数见文末「参数速查」） |
| `docker-compose.yml` | 三个服务：zerotier / postgres / ztnet（+ tls profile 的 caddy） |
| `.env.example` | 配置模板，`install.sh` 复制成 `.env` 并填好随机口令 |
| `Caddyfile` | 用 `--tls-domain` 时的反代规则 |
| `client/` | Android APK + Windows/Linux/macOS 安装脚本 + `README-客户端.md` |
| `SHA256SUMS` | 以上所有文件的 sha256 |

## 1. 主路径：docker login + 三条命令跑完（默认从私有仓库拉）

默认镜像就是私有仓库里的 `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>`（当前 `1.16.2`），
服务器直接 `docker pull`，**不用拷镜像文件**。先登录一次（账号找管理员要）：

```bash
cd /opt/zt-stack
docker login ccr.ccs.tencentyun.com     # 首次安装必做：私有仓库，没登录拉取会被 401 拒绝
sha256sum -c SHA256SUMS                 # 校验发布包完整性，每行都应该是 OK
./install.sh -i <服务器公网IPv4>         # 拉镜像 + 起栈 + 等 healthy
```

`cd` 的路径换成你自己放 `dist/` 的位置。`install.sh` 做的事：

1. 检查 docker / docker compose / compose 文件；
2. 本地没有 `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>` 就 `docker pull`（主路径）；
   registry 不可用时才退回 `docker load` 目录里的 tar（离线备选，见第 2 节）；
3. 生成 `.env`，随机生成 `NEXTAUTH_SECRET`、`POSTGRES_PASSWORD`、`DOWNLOAD_TOKEN`；
4. `docker compose up -d`，然后等三个容器变 healthy（默认最多 300 秒）；
5. 打印面板地址、planet 下载地址、必须放行的端口、客户端怎么填。

幂等：再跑一次不会换口令、不会动数据卷、不会动 identity。

> 私有仓库的鉴权有个已知坑：`docker login` 拿到的 token 偶尔会时序失败，报
> `failed to fetch oauth token ... unexpected EOF` 或 401。重新跑一次
> `docker login ccr.ccs.tencentyun.com` 就好。`install.sh` 遇到 401/鉴权类错误会直接
> 提示这句，而不是把 registry 的原始报错甩出来。

首次安装还会从 registry 拉 `postgres` 和 `ztnet` 两个基础镜像（约 1.5GB），
所以服务器要能上网，或者把 `.env` 里的 `ZTNET_IMAGE` / `POSTGRES_IMAGE` 换成内网镜像源。

## 2. 离线备选：用 dist 里的 tar 装（服务器出不了外网）

`planet-node-<tag>.tar.gz` 是同一个镜像的 `docker save` 结果，约 **42MB**（镜像本身 180MB，
整个 dist 目录 64MB）。这个 tar 只用于离线场景：把 tar 和 dist 里其它文件一起拷到服务器，
然后跑**同一条命令**——`install.sh` 在 `docker pull` 失败后会自己退回 `docker load`：

```bash
cd /opt/zt-stack
./install.sh -i <服务器公网IPv4>
```

日志里会看到 `docker load planet-node-<tag>.tar.gz（...，sha256 ...）` 和
`已载入镜像 ...（离线 tar）`。不需要额外参数，也不需要 `--image`。

优先级一句话记住：**本地已有镜像 > registry 拉取 > tar 载入**；三者都拿不到时脚本会报错，
并直接告诉你下一步（去登录，还是补 tar）。

## 3. 端口与防火墙

| 端口 | 协议 | 用途 | 公网放行 |
| --- | --- | --- | --- |
| 9994 | TCP + UDP | ZeroTier peer 传输与 controller API（planet 里通告的就是它） | **必须** |
| 3000 | TCP | planet/moon 下载（客户端装 planet 用） | **必须** |
| 3001 | TCP | ZTNet 面板（浏览器访问） | 需要人访问就开 |
| 80 / 443 | TCP(+UDP 443) | 只有 `--tls-domain` 时才用（Caddy 申请证书） | 用 TLS 时 |

云服务器要**同时**改安全组和系统防火墙（ufw/firewalld），只改一个等于没开。
UDP 9994 不放行，客户端会一直停在「连不上根节点」。

## 4. 客户端怎么装

服务端装完会打印 planet 下载地址，形如 `http://<IP>:3000/planet`（有 TLS 则是
`https://<域名>/planet`）。细节见 `client/README-客户端.md`，这里是要点：

- **Android**：装 `client/ZerotierFix-stage1-debug.apk` → 设置 → **行星服务器（自动下载）**
  → 地址填 `http(s)://<IP>:3000/planet` → 「下载 token（可选）」填服务端 `.env` 里的
  `DOWNLOAD_TOKEN`（服务端没启用就留空）→ 保存并同步。
- **Windows**（管理员 PowerShell，在 `client/windows`）：
  `.\install-planet.ps1 -ServerUrl http://<IP>:3000 -Token <DOWNLOAD_TOKEN>`
- **Linux**（在 `client/linux`）：
  `sudo ./install-planet.sh --server-url http://<IP>:3000 --token <DOWNLOAD_TOKEN>`
- **macOS**（在 `client/macos`）：
  `sudo ./install-planet.command --server-url http://<IP>:3000 --token <DOWNLOAD_TOKEN>`

装完用 `zerotier-cli info` / `zerotier-cli listnetworks` 确认，然后在面板里建网络、把成员授权。

## 5. 备份与换 IP

两个数据卷就是全部状态（identity、planet、controller 数据、面板数据库）。备份成 tar：

```bash
cd /opt/zt-stack
docker run --rm -v zt-stack_planet-data:/data -v "$PWD":/backup \
  --entrypoint tar ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2 czf /backup/planet-data-$(date +%Y%m%d).tgz -C /data .
docker run --rm -v zt-stack_postgres-data:/data -v "$PWD":/backup \
  --entrypoint tar ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2 czf /backup/postgres-data-$(date +%Y%m%d).tgz -C /data .
```

恢复前先 `docker compose down`，然后用同样的容器把 tar 解回卷里：

```bash
docker run --rm -v zt-stack_planet-data:/data -v "$PWD":/backup \
  --entrypoint tar ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2 xzf /backup/planet-data-<日期>.tgz -C /data
docker compose up -d
```

**换公网 IP**：直接带新 IP 重跑，`install.sh` 会只重建 planet（identity、网络 ID、
成员授权、面板数据库都不动）：

```bash
./install.sh -i <新公网IPv4>
```

planet 里的端点变了，所以**所有成员要重新装一次 planet**（Android 点「保存并同步」，
桌面端重跑安装脚本），网络 ID 不用变。

**换镜像（升级）**：联网时先 `docker login ccr.ccs.tencentyun.com`，再 `./install.sh --upgrade`
（拉新 tag 的镜像、只重建 zerotier 容器，postgres/ztnet 与数据库不动）；
离线时把新的 `planet-node-<tag>.tar.gz` 放进目录后跑同一条 `./install.sh --upgrade`，走 tar 路径。

更细的运维流程（日志、重置、迁移到另一台机器、`REGENERATE_WORLD` 语义）见仓库的
`docs/OPERATIONS.md`。

## 6. 常见报错

| 现象 | 原因 / 处理 |
| --- | --- |
| `拿不到镜像 ...：registry 拉取失败，且本目录没有 planet-node-*.tar.gz` | 服务器出不了外网又没带 tar。先 `docker login ccr.ccs.tencentyun.com` 重跑；离线就把 tar 放进目录重跑 |
| `unauthorized` / `no basic auth credentials` / `failed to fetch oauth token ... unexpected EOF` | 私有仓库没有有效登录，或登录 token 时序失败：重新 `docker login ccr.ccs.tencentyun.com` 后重跑（脚本会主动提示这一条） |
| `manifest unknown` / `denied: requested access to the resource is denied` | 镜像 tag 写错，或账号没有该仓库的拉取权限 |
| `docker compose up` 报 `pull access denied` 拉 ztnet/postgres | 这俩不是发布包里的镜像，要联网从 registry 拉。换 `.env` 的 `ZTNET_IMAGE`/`POSTGRES_IMAGE` 到能访问的镜像源后重跑 |
| 面板能开但登录报 403 | `.env` 的 `NEXTAUTH_URL` 与浏览器地址不一致（IP/端口/协议），改对后重跑 |
| 客户端 `/planet` 返回 401 | 服务端启用了 `DOWNLOAD_TOKEN`，客户端没带或带错 token |
| 客户端能下 planet 但连不上根节点 | 9994/udp 没放行；或 `--ip` 填了内网地址 |
| `有服务没到 healthy` | `docker compose ps`、`docker logs zt-stack-ztnet` 看具体原因；数据库口令改了要同步改 `.env` |

## 7. 参数速查

```text
docker login ccr.ccs.tencentyun.com   首次安装前登录私有仓库（默认镜像来源）
./install.sh -i <公网IPv4>            首次安装：拉镜像 + 起栈 + 等 healthy
./install.sh -i <IP> --ipv6 <IPv6>    同时通告 IPv6
./install.sh -i <IP> --tls-domain zt.example.com   启用 Caddy + HTTPS
./install.sh -i <IP> --image <registry>/<仓库>:<tag>   换 registry 镜像（先 pull 再打本地 tag）
./install.sh --upgrade                只重建 zerotier 容器
./install.sh --wait 600 / --no-wait   健康检查超时 / 不等待
./install.sh -h                       完整帮助
```

改端口：编辑 `.env` 里的 `ZT_PORT` / `FILES_PORT` / `ZTNET_PORT` 后重跑 `./install.sh`（IP 可省，沿用 `.env`）。
