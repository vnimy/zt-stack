#!/usr/bin/env bash
# ZerotierFix 阶段1 可复现构建脚本
#   目标：JDK17 + Gradle 8.7 + AGP 8.6.1 + compileSdk/targetSdk 35 + minSdk 21
#   产出：app/build/outputs/apk/debug/app-debug.apk，并拷贝到 zt-stack/artifacts/
#
# 所有构建期缓存/临时目录都放在 zt-stack/.build/ 下，不向工作区根目录写任何东西。
#
# 依赖的本地工具链（可用环境变量覆盖）：
#   JAVA_HOME         JDK17                默认 D:/Projects/MM678/build-android/tools/jdk-17.0.20.1+1
#   ANDROID_SDK_ROOT  Android SDK (35)     默认 D:/Projects/MM678/build-android/android-sdk
#   NDK_DIR           NDK r28c             默认 $ANDROID_SDK_ROOT/ndk/android-ndk-r28c
#   CMAKE_DIR         CMake 3.22.1         默认 <zt-stack>/.build/.toolchain/cmake-3.22.1
#   GRADLE_USER_HOME  Gradle 缓存根目录    默认 <zt-stack>/.build/.gradle-home
#   ANDROID_USER_HOME AGP 用户目录         默认 <zt-stack>/.build/.android-home（含 debug.keystore）
#   TMP_ROOT          JVM 临时目录         默认 <zt-stack>/.build/.tmp
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STACK_ROOT="$(cd "$HERE/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$STACK_ROOT/.build}"
REPO="${REPO:-D:/Projects/zerotier/ZerotierFix}"
export JAVA_HOME="${JAVA_HOME:-D:/Projects/MM678/build-android/tools/jdk-17.0.20.1+1}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-D:/Projects/MM678/build-android/android-sdk}"
NDK_DIR="${NDK_DIR:-$ANDROID_SDK_ROOT/ndk/android-ndk-r28c}"
CMAKE_DIR="${CMAKE_DIR:-$BUILD_ROOT/.toolchain/cmake-3.22.1}"
CORE_VERSION="$(cd "$REPO/externals/core" 2>/dev/null && git describe --tags --abbrev=0 --match '[0-9]*' 2>/dev/null || echo unknown)"
APK_NAME="${APK_NAME:-ZerotierFix-${CORE_VERSION}-debug.apk}"
# 交给 JVM/AGP 的路径必须是 Windows 形式（本沙箱 bash 里没有 cygpath，手动转换 /d/... -> D:/...）
winpath() {
  case "$1" in
    /?/*) printf '%s:/%s\n' "$(printf '%s' "${1:1:1}" | tr 'a-z' 'A-Z')" "${1:3}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

export GRADLE_USER_HOME="$(winpath "${GRADLE_USER_HOME:-$BUILD_ROOT/.gradle-home}")"
export ANDROID_USER_HOME="$(winpath "${ANDROID_USER_HOME:-$BUILD_ROOT/.android-home}")"
export PATH="$JAVA_HOME/bin:$PATH"

# JVM 临时目录默认落在系统 TEMP，某些受限沙箱下 JVM 对系统 TEMP 无写权限
# （表现为 mergeDebugJavaResource 抛 AccessDeniedException），统一挪到 .build/ 下
TMP_ROOT="$(winpath "${TMP_ROOT:-$BUILD_ROOT/.tmp}")"
mkdir -p "$TMP_ROOT" "$ANDROID_USER_HOME" "$GRADLE_USER_HOME"
export TMPDIR="$TMP_ROOT" TEMP="$TMP_ROOT" TMP="$TMP_ROOT"

for p in "$JAVA_HOME/bin/javac" "$CMAKE_DIR/bin/cmake.exe" "$NDK_DIR/source.properties"; do
  [ -e "$p" ] || { echo "缺少工具链: $p" >&2; exit 2; }
done

# local.properties 不入库，由脚本生成（properties 格式需要转义盘符冒号）
esc() { echo "$1" | sed 's|:|\\:|g'; }
cat > "$REPO/local.properties" <<EOF
sdk.dir=$(esc "$(winpath "$ANDROID_SDK_ROOT")")
cmake.dir=$(esc "$(winpath "$CMAKE_DIR")")
ndk.dir=$(esc "$(winpath "$NDK_DIR")")
EOF
echo "== local.properties =="
cat "$REPO/local.properties"

echo "== 构建环境 =="
echo "BUILD_ROOT=$BUILD_ROOT"
echo "CORE_VERSION=$CORE_VERSION"
echo "APK_NAME=$APK_NAME"
"$JAVA_HOME/bin/java" -version 2>&1 | head -1
"$CMAKE_DIR/bin/cmake.exe" --version | head -1

cd "$REPO"
./gradlew --no-daemon -Djava.io.tmpdir="$TMP_ROOT" assembleDebug

APK="$REPO/app/build/outputs/apk/debug/app-debug.apk"
mkdir -p "$STACK_ROOT/artifacts"
OUT="$STACK_ROOT/artifacts/$APK_NAME"
cp "$APK" "$OUT"
echo "== 产物 =="
ls -l "$OUT"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT"
else
  certutil -hashfile "$(cygpath -w "$OUT" 2>/dev/null || echo "$OUT")" SHA256 | sed -n 2p
fi
