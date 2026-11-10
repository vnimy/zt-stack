#!/usr/bin/env bash
# PlanetSyncer 端到端验证：
#   1. 用 JDK17 编译 App 里真实的生产代码（Constants + PlanetSyncer，二者都不依赖 Android API）
#   2. 起一个真实本地 HTTP 服务，把假 planet 下载到 App 使用的同一个文件名
#   3. 断言下载/校验/备份/回退/重试/token 行为
#
# 用法: bash run-planet-sync-test.sh [ZerotierFix 仓库路径]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-D:/Projects/zerotier/ZerotierFix}"
JAVA_HOME="${JAVA_HOME:-D:/Projects/MM678/build-android/tools/jdk-17.0.20.1+1}"
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"

if [ ! -x "$JAVA" ]; then
  echo "找不到 JDK17: $JAVA (可用 JAVA_HOME 覆盖)" >&2
  exit 2
fi

OUT="$HERE/.out"
rm -rf "$OUT"
mkdir -p "$OUT"

"$JAVAC" -encoding UTF-8 -d "$OUT" \
  "$REPO/app/src/main/java/net/kaaass/zerotierfix/util/Constants.java" \
  "$REPO/app/src/main/java/net/kaaass/zerotierfix/util/PlanetSyncer.java" \
  "$HERE/PlanetSyncHarness.java"

# -Dstdout.encoding 保证在 Windows 控制台/重定向下断言输出都是 UTF-8
set +e
"$JAVA" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 \
  -Dstderr.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8 -cp "$OUT" PlanetSyncHarness \
  "$HERE/.work" "$HERE/real-planet-official.bin" "$HERE/planet-from-mkworld.bin" \
  > "$HERE/last-run.log" 2>&1
STATUS=$?
set -e
cat "$HERE/last-run.log"
exit $STATUS
