#!/usr/bin/env bash
#
# test-download.sh - 用 mock-server.py 端到端验证 linux/install-planet.sh
#
# 覆盖: 下载 / 长度+魔数校验 / token 校验(正反) / sha256 校验(正反)
#       备份 / 原子替换 / 重复执行幂等 / 失败时不动现有 planet
#
# 用法: bash clients/test/test-download.sh [端口]
# 依赖: python3, curl (脚本内部只用到系统自带工具)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CLIENTS=$(dirname "$HERE")
INSTALLER="$CLIENTS/linux/install-planet.sh"
PORT="${1:-18089}"
TOKEN="s3cr3t-token"
WORK=$(mktemp -d)
SRV_PID=""
PASS=0
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$*"; }

cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -f "$INSTALLER" ] || { say "installer not found: $INSTALLER"; exit 1; }
command -v python3 >/dev/null 2>&1 || { say "python3 not found"; exit 1; }
command -v curl >/dev/null 2>&1 || { say "curl not found"; exit 1; }

python3 "$HERE/mock-server.py" --host 127.0.0.1 --port "$PORT" --token "$TOKEN" \
  >"$WORK/server.log" 2>&1 &
SRV_PID=$!

ready=0
i=0
while [ "$i" -lt 60 ]; do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  say "mock server did not become healthy; log:"
  cat "$WORK/server.log"
  exit 1
fi
say "mock server ready on 127.0.0.1:$PORT"
say ""

TARGET_DIR="$WORK/zerotier-one"
PLANET="$TARGET_DIR/planet"
mkdir -p "$TARGET_DIR"

# ---------- 1. 无 token: 应失败且不产生 planet ----------
OUT=$(bash "$INSTALLER" --server-url "http://127.0.0.1:$PORT" --target "$PLANET" --no-restart 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then ok "无 token 时脚本失败 (exit $RC)"; else bad "无 token 时脚本居然成功"; fi
if [ ! -f "$PLANET" ]; then ok "无 token 时未产生 planet 文件"; else bad "无 token 时产生了 planet 文件"; fi
printf '%s\n' "$OUT" | tail -3 | sed 's/^/    | /'
say ""

# ---------- 2. 正确 token: 应成功 ----------
OUT=$(bash "$INSTALLER" --server-url "http://127.0.0.1:$PORT" --token "$TOKEN" --target "$PLANET" --no-restart 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then ok "带 token 安装成功 (exit 0)"; else bad "带 token 安装失败 (exit $RC)"; printf '%s\n' "$OUT"; fi
printf '%s\n' "$OUT" | sed 's/^/    | /'
if [ -f "$PLANET" ]; then ok "planet 已写入 $PLANET"; else bad "planet 未写入"; fi
SIZE=$(wc -c < "$PLANET" | tr -d ' ')
if [ "$SIZE" -eq 319 ]; then ok "planet 大小 319 字节 (与 mock 一致)"; else bad "planet 大小 $SIZE, 期望 319"; fi
MAGIC=$(od -An -tu1 -N1 "$PLANET" | tr -d ' \n')
if [ "$MAGIC" = "1" ]; then ok "planet 首字节 0x01"; else bad "planet 首字节 0x$MAGIC"; fi
printf '%s\n' "$OUT" | grep -q '校验通过' && ok "输出含格式校验通过" || bad "输出缺校验通过"
say ""

# ---------- 3. 再跑一次: 幂等 + 生成备份 ----------
OUT=$(bash "$INSTALLER" --server-url "http://127.0.0.1:$PORT" --token "$TOKEN" --target "$PLANET" --no-restart 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then ok "重复执行成功 (幂等, exit 0)"; else bad "重复执行失败 (exit $RC)"; fi
BAKS=$(find "$TARGET_DIR" -maxdepth 1 -name 'planet.bak.*' | wc -l | tr -d ' ')
if [ "$BAKS" -ge 1 ]; then ok "生成备份文件 $BAKS 个"; else bad "未生成备份"; fi
printf '%s\n' "$OUT" | grep -q '已备份' && ok "输出含已备份" || bad "输出缺已备份"
ls -1 "$TARGET_DIR" | sed 's/^/    dir: /'
say ""

# ---------- 4. sha256 正确 ----------
GOOD_SHA=$(sha256sum "$PLANET" | awk '{print $1}')
OUT=$(bash "$INSTALLER" --server-url "http://127.0.0.1:$PORT" --token "$TOKEN" --target "$PLANET" --sha256 "$GOOD_SHA" --no-restart 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then ok "正确 sha256 校验通过"; else bad "正确 sha256 被拒 (exit $RC)"; printf '%s\n' "$OUT"; fi
say ""

# ---------- 5. sha256 错误: 不得改动现有 planet ----------
BEFORE=$(sha256sum "$PLANET" | awk '{print $1}')
OUT=$(bash "$INSTALLER" --server-url "http://127.0.0.1:$PORT" --token "$TOKEN" --target "$PLANET" --sha256 "0000000000000000000000000000000000000000000000000000000000000000" --no-restart 2>&1)
RC=$?
AFTER=$(sha256sum "$PLANET" | awk '{print $1}')
if [ "$RC" -ne 0 ]; then ok "错误 sha256 被拒绝 (exit $RC)"; else bad "错误 sha256 未被拒绝"; fi
if [ "$BEFORE" = "$AFTER" ]; then ok "失败后现有 planet 未变 (sha 相同)"; else bad "失败后 planet 被改动"; fi
printf '%s\n' "$OUT" | tail -2 | sed 's/^/    | /'
say ""

# ---------- 6. 服务端不可达: 不破坏现有 planet ----------
OUT=$(bash "$INSTALLER" --server-url "http://127.0.0.1:1" --target "$PLANET" --no-restart 2>&1)
RC=$?
AFTER2=$(sha256sum "$PLANET" | awk '{print $1}')
if [ "$RC" -ne 0 ]; then ok "服务端不可达时脚本失败 (exit $RC)"; else bad "服务端不可达时脚本居然成功"; fi
if [ "$AFTER" = "$AFTER2" ]; then ok "不可达后现有 planet 未变"; else bad "不可达后 planet 被改动"; fi
printf '%s\n' "$OUT" | tail -2 | sed 's/^/    | /'
LEFT=$(find "$TARGET_DIR" -maxdepth 1 -name '.planet.download.*' | wc -l | tr -d ' ')
if [ "$LEFT" -eq 0 ]; then ok "临时文件已清理"; else bad "残留临时文件 $LEFT 个"; fi
say ""

# ---------- 7. 200 但内容是文本: 必须被魔数校验拦下 ----------
OUT=$(bash "$INSTALLER" --server-url "http://127.0.0.1:$PORT/text" --token "$TOKEN" --target "$PLANET" --no-restart 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then ok "文本响应被拒绝 (exit $RC)"; else bad "文本响应未被拒绝"; fi
printf '%s\n' "$OUT" | grep -q '首字节' && ok "拒绝原因是魔数不符" || bad "拒绝原因不是魔数"
printf '%s\n' "$OUT" | tail -2 | sed 's/^/    | /'
say ""

# ---------- 8. macOS 脚本在 Linux 上跑通同一套逻辑 (launchctl 无法实测) ----------
MACTARGET="$WORK/mac-one/planet"
OUT=$(bash "$CLIENTS/macos/install-planet.command" --server-url "http://127.0.0.1:$PORT" --token "$TOKEN" --target "$MACTARGET" --no-restart 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then ok "macOS 脚本在 Linux 下安装成功 (exit 0)"; else bad "macOS 脚本失败 (exit $RC)"; printf '%s\n' "$OUT"; fi
if [ -f "$MACTARGET" ]; then ok "macOS 脚本写入了 planet"; else bad "macOS 脚本未写入 planet"; fi
printf '%s\n' "$OUT" | grep -q '格式校验通过' && ok "macOS 脚本校验通过" || bad "macOS 脚本缺校验输出"
say ""

say "==================== 结果 ===================="
say "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  say "mock server log (tail):"
  tail -20 "$WORK/server.log"
  exit 1
fi
say "ALL CHECKS PASSED"
exit 0
