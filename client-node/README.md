# 客户端容器（zerotier-client）

把一台 Linux 主机接进自建 ZeroTier 网络的最小镜像：容器里跑 `zerotier-one`，启动时自动从行星服务器下载 planet，加入指定网络，之后常驻并周期打印状态。

适合 NAS、软路由、长期在线的服务器 —— 不需要装客户端、不需要手动放 planet 文件，改一个环境变量就能换行星服务器。

## 快速开始

```bash
cd zt-stack/client-node
# 从已发布的镜像直接跑（推荐）
docker compose up -d

# 或者本地构建同一个名字
./build.sh                 # 产出 ccr.ccs.tencentyun.com/vnimy/zerotier-client:1.16.2
./build.sh --push          # 推到私有仓库
```

等价的手工命令：

```bash
docker run -d --name zt-client \
  --cap-add NET_ADMIN --device /dev/net/tun \
  --restart unless-stopped \
  -e PLANET_URL=https://zt.vnimy.com/planet \
  -e NETWORK_ID=e5c9db4519e04fa5 \
  -v zt-client-data:/var/lib/zerotier-one \
  ccr.ccs.tencentyun.com/vnimy/zerotier-client:1.16.2
```

改好 `docker-compose.yml` 里的 `PLANET_URL` / `NETWORK_ID` 后：

```bash
docker compose up -d
docker compose logs -f
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PLANET_URL` | 空 | 行星服务器 planet 的完整下载地址，Android 客户端填什么这里就填什么（`https://<域名>/planet`）。留空则用内置官方 planet |
| `PLANET_TOKEN` | 空 | 下载 token，走 `Authorization: Bearer`；服务端没开 token 就不用填 |
| `PLANET_SHA256` | 空 | 期望的 planet sha256；填了就强校验，不匹配拒绝安装 |
| `PLANET_UPDATE` | `1` | `1` = 每次启动重新下载（服务器换了 IP 也能跟上）；`0` = 只在本地没有 planet 时下载 |
| `NETWORK_ID` | 空 | 要加入的网络，空格或逗号分隔可写多个 |
| `STATUS_INTERVAL` | `60` | 状态日志间隔（秒），状态变化时会立刻打印 |
| `ZT_HOME` | `/var/lib/zerotier-one` | 数据目录，务必挂卷，否则重启换身份 |

## 加入网络后要授权

容器首次启动会在控制器里注册成新成员，处于 `ACCESS_DENIED`，需要授权：

- ZTNet 面板 → 网络 → 成员，勾选授权；或
- 控制器 API：`POST /controller/network/<nwid>/member/<nodeid>` body `{"authorized":true}`

授权后日志会从 `ACCESS_DENIED` 变成 `OK 192.168.200.x/24`，`iproute2` 已内置，可直接 `docker exec zt-client ip -4 addr show` 看接口。

## 日志示例

```
client: downloading planet from https://zt.vnimy.com/planet
client: planet installed from https://zt.vnimy.com/planet: 257 bytes, sha256 5a0b5513...
client: starting zerotier-one (identity in /var/lib/zerotier-one)
client: identity: 200 info a1a9436aea 1.16.2 ONLINE
client: joined e5c9db4519e04fa5
client: network state: e5c9db4519e04fa5=OK 192.168.200.153/24;
```

重启容器不会换身份：日志会是 `already joined …`，成员授权与固定 IP 都保留。

## 说明

- 需要 `--cap-add NET_ADMIN` 与 `/dev/net/tun`，否则起不了 tun 设备
- 镜像基于 `ubuntu:24.04`：ZeroTier 的二进制动态链接 glibc，alpine 跑不了
- 二进制取自 `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2`（构建参数 `ZT_IMAGE` 可换版本），客户端与行星服务器版本保持一致
- planet 下载失败会保留上一份 planet 并继续启动，不会因为服务器临时不可达就掉线
