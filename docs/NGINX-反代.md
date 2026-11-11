# 用外部 Nginx 反代 zerotier-planet

这套栈对外只暴露三类东西，反代只处理其中两类（HTTP 的），第三类是 ZeroTier 自己的协议，**不能**走 HTTP 反代：

| 宿主端口（默认） | 协议 | 用途 | 能不能经 Nginx 反代 |
|---|---|---|---|
| `FILES_PORT=3000` | HTTP | `/planet`、`/moons`、`/moon/<name>`、`/healthz`、`/version.json`、`/app/zerotier.apk`、`/qr.svg`、`/dl/`、`/` 下载页 | **能** |
| `ZTNET_PORT=3001` | HTTP | ZTNet 面板（Next.js） | **能** |
| `ZT_PORT=9994` | **TCP + UDP** | ZeroTier 的 peer 传输与控制 API | **不能**（不是 HTTP；UDP 反代无意义，改域名也没用） |

关键含义：**planet 里的端点永远是 `<公网IP>:9994`**，客户端拿到 planet 后直连那个 IP:端口，不经过你的域名。所以 Nginx 只负责"面板"和"下载"这两个 HTTP 入口，9994 必须继续对公网放行 tcp+udp。

---

## 1. 先改一个环境变量（必做）

ZTNet 用 `NEXTAUTH_URL` 做 Origin/回调校验，它必须**逐字等于浏览器地址**，否则登录会被拒成 403：

```dotenv
# compose 同目录的 .env
NEXTAUTH_URL=https://zt.example.com
```

改完重建面板容器（只重建 ztnet，不动行星节点与数据）：

```bash
docker compose up -d ztnet
```

> 若还想让面板只允许内网访问，把 compose 里的面板端口改成只绑回环：`- "127.0.0.1:${ZTNET_PORT:-3001}:3000/tcp"`。下载服务同理可只绑回环（`127.0.0.1:3000`），前提是下载也一律经 Nginx。

---

## 2. Nginx 配置（单域名、路径分流）

与镜像自带的 Caddyfile 规则一致：`/` 走面板，`/planet` 等走文件服务。

```nginx
# /etc/nginx/conf.d/zerotier-planet.conf
upstream zt_panel { server 127.0.0.1:3001; keepalive 16; }
upstream zt_files { server 127.0.0.1:3000; keepalive 16; }

server {
    listen 80;
    server_name zt.example.com;
    return 301 https://$host$request_uri;
}

server {
    # 用这一行兼容 nginx 1.24 及更早；1.25.1+ 会提示 "the `listen ... http2` directive is deprecated"，
    # 想用新写法就改成两行：listen 443 ssl;  +  http2 on;
    listen 443 ssl http2;
    server_name zt.example.com;

    ssl_certificate     /etc/letsencrypt/live/zt.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/zt.example.com/privkey.pem;

    # 这些头在 server 级设置会被下面所有 location 继承；
    # Authorization 默认透传，所以客户端用 Bearer 下载 planet 不需要额外配置。
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $host;

    # ---- 文件服务：planet / moons / healthz / 下载页 ----
    location = /healthz { proxy_pass http://zt_files; }
    location = /planet  { proxy_pass http://zt_files; }
    location = /moons   { proxy_pass http://zt_files; }
    location ^~ /moon/  { proxy_pass http://zt_files; }
    # 客户端检查更新：/version.json 清单 + /app/zerotier.apk 安装包
    location = /version.json { proxy_pass http://zt_files; }
    location ^~ /app/        { proxy_pass http://zt_files; }
    # 下载页与二维码（/dl 映射到根，页面里的链接都是绝对路径，仍指向本域）
    location = /qr.svg       { proxy_pass http://zt_files; }
    location = /dl           { proxy_pass http://zt_files/; }
    location ^~ /dl/         { proxy_pass http://zt_files/; }

    # ---- 其余全部交给 ZTNet 面板 ----
    location / {
        proxy_pass http://zt_panel;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
}
```

要点：
- `location ^~ /moon/` 必须带 `^~`，否则可能被后面的正则或 `/` 抢走。
- 不要给 `/planet` 加 `proxy_buffering`、rewrite 或 auth_request，保持原样透传（查询串 `?token=` 与 `Authorization` 都要原样到后端）。
- 面板如果以后开 WebSocket（ZTNet 的实时状态），上面两行 Upgrade 头就是给它准备的。

---

## 3. 如果 Nginx 也在 Docker 里

把它接到同一张网络，upstream 换成服务名，端口用容器内端口（3000）：

```yaml
services:
  nginx:
    image: nginx:alpine
    networks: [ztnet-net]        # 与 zerotier-planet 同一个网络（默认名 zerotier-planet_ztnet-net）
    # ...
```
```nginx
upstream zt_panel { server ztnet:3000; }
upstream zt_files { server zerotier:3000; }
```

---

## 4. 客户端地址随之改变

| 客户端 | 地址 |
|---|---|
| Android（ZeroTier） | `https://zt.example.com/planet`（token 填 `?token=` 或 App 里的 token 字段） |
| Windows / Linux / macOS 脚本 | `-ServerUrl https://zt.example.com/planet`（`-Token` 可选） |
| 手工放置 | 从 `https://zt.example.com/planet` 下载后放进客户端数据目录 |

注意：planet 文件本身仍指向 `<IP>:9994`，所以**放行 9994/tcp+9994/udp 是必须的**，Nginx 无法替代。

---

## 5. 自检

```bash
nginx -t                                  # 语法
curl -sSI https://zt.example.com/healthz  # 200
curl -sS  https://zt.example.com/planet -o /tmp/planet && ls -l /tmp/planet   # 应为 ~257B~276B
head -c1 /tmp/planet | od -An -tu1        # 首字节应为 1（World::TYPE_PLANET）
curl -sSI https://zt.example.com/auth/login   # 面板 200
```

不需要用 `--profile tls`（那是给不放 Nginx 的人准备的 Caddy），两套反代同时开会抢 80/443。
