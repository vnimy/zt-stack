#!/bin/bash
#
# install-planet.command - 为 macOS 安装自建 ZeroTier planet 文件
#
# 双击运行或在终端里执行(需要 sudo)。流程: 下载到临时文件 -> 校验 -> 备份
# -> 原子替换 /Library/Application Support/ZeroTier/One/planet -> launchctl 重启。
#
# 用法: sudo ./install-planet.command --server-url https://zt.example.com [--token TOKEN]
#
set -eu

VERSION="1.0.0"
DEFAULT_PLANET="/Library/Application Support/ZeroTier/One/planet"
LAUNCHD_LABEL="com.zerotier.one"
LAUNCHD_PLIST="/Library/LaunchDaemons/com.zerotier.one.plist"
MIN_BYTES=128
MAX_BYTES=65536
MAX_ATTEMPTS=3

SERVER_URL="${ZT_SERVER_URL:-}"
TOKEN="${ZT_TOKEN:-}"
TARGET="$DEFAULT_PLANET"
EXPECT_SHA="${ZT_PLANET_SHA256:-}"
DO_RESTART=1
TMP=""

say()  { printf '%s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$TMP" ] && [ -f "$TMP" ]; then
    rm -f "$TMP" || true
  fi
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'ZTEOF'
install-planet.command - 为 macOS 安装自建 ZeroTier planet 文件

用法:
  sudo ./install-planet.command --server-url <URL> [选项]

选项:
  -s, --server-url <URL>   自建 planet 服务地址, 例如 https://zt.example.com
  -t, --token <TOKEN>      下载 token (可选)
      --target <PATH>      覆盖 planet 路径 (测试用)
                           默认 /Library/Application Support/ZeroTier/One/planet
      --sha256 <HEX>       期望的 planet sha256 (可选)
      --no-restart         只替换文件, 不重启服务
  -h, --help               显示本帮助

环境变量: ZT_SERVER_URL / ZT_TOKEN / ZT_PLANET_SHA256
ZTEOF
}

need_val() {
  if [ "$2" -lt 2 ]; then
    die "$1 需要一个参数值"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--server-url) need_val "$1" $#; SERVER_URL="$2"; shift 2 ;;
    -t|--token)      need_val "$1" $#; TOKEN="$2"; shift 2 ;;
    --target)        need_val "$1" $#; TARGET="$2"; shift 2 ;;
    --sha256)        need_val "$1" $#; EXPECT_SHA="$2"; shift 2 ;;
    --no-restart)    DO_RESTART=0; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage >&2; die "未知参数: $1" ;;
  esac
done

urlencode() {
  _s="$1"
  _out=""
  _i=0
  _n=$(printf '%s' "$_s" | wc -c | tr -d ' ')
  while [ "$_i" -lt "$_n" ]; do
    _c=$(printf '%s' "$_s" | cut -c$((_i + 1)))
    case "$_c" in
      [a-zA-Z0-9._~-]) _out="$_out$_c" ;;
      *) _out="$_out$(printf '%%%02X' "'$_c")" ;;
    esac
    _i=$((_i + 1))
  done
  printf '%s' "$_out"
}

sha_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

fetch() {
  _url="$1"
  _out="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$TOKEN" ]; then
      curl -fsSL --connect-timeout 10 --max-time 180 \
        -H "Authorization: Bearer $TOKEN" -o "$_out" "$_url"
    else
      curl -fsSL --connect-timeout 10 --max-time 180 -o "$_out" "$_url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$TOKEN" ]; then
      wget -q -T 30 -O "$_out" --header "Authorization: Bearer $TOKEN" "$_url"
    else
      wget -q -T 30 -O "$_out" "$_url"
    fi
  else
    die "需要 curl 或 wget, 二者均未找到"
  fi
}

restart_service() {
  if command -v launchctl >/dev/null 2>&1; then
    if launchctl kickstart -k "system/$LAUNCHD_LABEL" >/dev/null 2>&1; then
      ok "已重启 $LAUNCHD_LABEL (launchctl kickstart)"
      return 0
    fi
    if [ -f "$LAUNCHD_PLIST" ]; then
      if launchctl unload "$LAUNCHD_PLIST" >/dev/null 2>&1 && \
         launchctl load "$LAUNCHD_PLIST" >/dev/null 2>&1; then
        ok "已重启 $LAUNCHD_LABEL (launchctl unload/load)"
        return 0
      fi
      warn "launchctl unload/load $LAUNCHD_PLIST 失败"
      return 1
    fi
  fi
  return 1
}

say "install-planet.command v$VERSION (macOS)"

if [ -z "$SERVER_URL" ]; then
  usage >&2
  die "缺少 --server-url"
fi
case "$SERVER_URL" in
  http://*|https://*) ;;
  *) die "--server-url 必须以 http:// 或 https:// 开头" ;;
esac

say "提示: 本脚本只替换 planet 文件; macOS 版 ZeroTier One 需已通过官方 pkg 安装。"

if [ "$(id -u)" -ne 0 ]; then
  if [ "$TARGET" = "$DEFAULT_PLANET" ]; then
    die "需要 root 权限, 请用 sudo 运行: sudo $0 --server-url $SERVER_URL"
  fi
  warn "当前不是 root, 只写入自定义路径 $TARGET (测试/高级用法), 并跳过服务重启"
  DO_RESTART=0
fi

DIR=$(dirname "$TARGET")
if [ ! -d "$DIR" ]; then
  if [ "$TARGET" = "$DEFAULT_PLANET" ]; then
    die "目录 $DIR 不存在: 看起来 ZeroTier One 未安装, 请先从 zerotier.com 安装 macOS 版"
  fi
  mkdir -p "$DIR" || die "无法创建目录 $DIR"
fi

BASE="${SERVER_URL%/}"
URL="$BASE/planet"
if [ -n "$TOKEN" ]; then
  URL="$URL?token=$(urlencode "$TOKEN")"
fi

TMP="$DIR/.planet.download.$$"
attempt=1
while : ; do
  say "下载 $URL (第 $attempt/$MAX_ATTEMPTS 次)"
  rm -f "$TMP"
  if fetch "$URL" "$TMP"; then
    break
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    die "下载失败 (已尝试 $MAX_ATTEMPTS 次); 现有 planet 未被改动"
  fi
  attempt=$((attempt + 1))
  sleep 2
done

SIZE=$(wc -c < "$TMP" | tr -d ' ')
if [ "$SIZE" -lt "$MIN_BYTES" ] || [ "$SIZE" -gt "$MAX_BYTES" ]; then
  die "校验失败: 文件 $SIZE 字节, 不在 $MIN_BYTES..$MAX_BYTES 范围 (可能下载到了错误页面); 现有 planet 未被改动"
fi
MAGIC=$(od -An -tu1 -N1 "$TMP" | tr -d ' \n')
MAGIC_HEX=$(printf '%02X' "$MAGIC")
if [ "$MAGIC" != "1" ]; then
  die "校验失败: 不是 planet 文件 (首字节 0x$MAGIC_HEX, 期望 0x01); 现有 planet 未被改动"
fi
ok "格式校验通过: $SIZE 字节, 首字节 0x01"

ACTUAL_SHA=""
if ACTUAL_SHA=$(sha_of "$TMP"); then
  say "sha256: $ACTUAL_SHA"
else
  ACTUAL_SHA=""
  warn "系统缺少 shasum/sha256sum, 跳过 sha256 计算"
fi
if [ -n "$EXPECT_SHA" ]; then
  if [ -z "$ACTUAL_SHA" ]; then
    die "要求校验 sha256, 但系统缺少 shasum/sha256sum"
  fi
  WANT=$(printf '%s' "$EXPECT_SHA" | tr 'A-F' 'a-f')
  if [ "$ACTUAL_SHA" != "$WANT" ]; then
    die "校验失败: sha256 不匹配 (期望 $WANT); 现有 planet 未被改动"
  fi
  ok "sha256 校验通过"
fi

if [ -f "$TARGET" ]; then
  BAK="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$TARGET" "$BAK" || die "备份现有 planet 失败"
  ok "已备份现有 planet -> $BAK"
else
  say "目标路径暂无 planet, 将直接创建"
fi

mv -f "$TMP" "$TARGET" || die "替换 planet 失败"
TMP=""
chmod 0644 "$TARGET" 2>/dev/null || true
ok "已安装 planet -> $TARGET"

if [ "$DO_RESTART" -eq 1 ]; then
  if restart_service; then
    :
  else
    warn "未能自动重启 $LAUNCHD_LABEL (服务可能未安装)"
    warn "  手动: sudo launchctl kickstart -k system/$LAUNCHD_LABEL"
    warn "  或者: sudo launchctl unload $LAUNCHD_PLIST && sudo launchctl load $LAUNCHD_PLIST"
  fi
else
  say "已跳过服务重启 (--no-restart 或非 root)"
fi

printf '\n'
say "下一步:"
say "  1) 确认服务运行: /usr/local/bin/zerotier-cli info"
say "  2) 加入网络:     /usr/local/bin/zerotier-cli join <网络ID>"
say "  <网络ID> 来自自建控制器/管理员 (ZTNet 后台 Networks 里的 Network ID)。"
say "  回滚: sudo cp -p '$TARGET.bak.<时间戳>' '$TARGET' 然后重启服务。"

case "$0" in
  *.command)
    if [ -t 0 ] && [ -t 1 ]; then
      printf '按回车键关闭窗口...'
      read -r _ || true
    fi
    ;;
esac

exit 0
