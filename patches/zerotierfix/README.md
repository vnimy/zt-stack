# ZerotierFix：填地址即用（行星服务器）+ 工具链现代化

本目录是 ZerotierFix（`kaaass/ZerotierFix` master）两个阶段的全部产物：
可复现的补丁、构建脚本、客户端端到端验证脚本，以及构建出的 APK。

- **阶段1**：App 里直接填「行星服务器地址」，启动时自动下载 planet（免手动导入 planet 文件）；
  用现代工具链（JDK17 / Gradle 8 / AGP 8 / compileSdk 35）能构建出 APK。core 保持 **1.12.2**。
- **阶段2**：把 core 从 1.12.2 换成 **1.16.2**（与自建 planet 节点同版本）。Java 层零改动，
  只重写 `externals/core/java/CMakeLists.txt` 并换代 core 源码。
- **阶段3**：修 Android 15（targetSdk 35）强制 edge-to-edge 导致的「标题栏盖住页面顶部」，见 §0.1。

> 当前交付 APK 是**阶段3**：`artifacts/ZerotierFix-1.16.2-debug.apk`（core 1.16.2 + edge-to-edge 修复）。
> 阶段1 的 `artifacts/ZerotierFix-1.12.2-debug.apk`（core 1.12.2）保留作回退。

---

## 0. 阶段2 摘要（core 1.16.2）

| 项 | 变化 |
|---|---|
| core 源码 | `externals/core` 从 `kaaass/ZeroTierOne @ d028a247`（1.12.2）换成上游 `ZeroTierOne @ 1.16.2`（`fc5c3ec22`） |
| JNI 适配 | 补丁 `0003-core-1.16.2-jni.patch`：`CMakeLists.txt` 升 C++17、源文件集对齐 `objects.mk`、补 prometheus 头路径 |
| Java SDK | 无改动。1.12.2→1.16.2 官方只改了 `java/jni/com_zerotierone_sdk_Node.cpp`（`ZT_Node_Config`、线程附加 RAII），native 方法签名不变 |
| Rust | 不需要。`ZT_SSO_SUPPORTED=1` 才会链 `librustybits.a`，Android JNI 路径不定义该宏 |
| 产物 | 30,118,932 B，双 ABI，`llvm-nm` 可见 255 个 `ZeroTier::ECC::`/`Bond::` 等 1.16.2 独有符号 |
| 设备验证 | 真机安装并连上自建网络（阶段2 APK 实测连接成功）；edge-to-edge 的视觉修复未拍照确认，见 §8.3 |

core 换代的可复现步骤：

```bash
cd ZerotierFix/externals/core
git remote add local D:/Projects/zerotier/ZeroTierOne   # 或任意 ZeroTierOne 克隆
git fetch --no-tags local tag 1.16.2
git checkout -b zt-stack-core-1.16.2 1.16.2
git am /path/to/zt-stack/patches/zerotierfix/0003-core-1.16.2-jni.patch
# 切 core 版本后必须清掉旧产物，否则 CMake 缓存会把 1.12.2 的对象文件带过来
rm -rf ../../core/.cxx ../../core/build
```

---

## 0.1 阶段3 摘要（Android 15 edge-to-edge）

targetSdk 35 在 Android 15+ 上强制 edge-to-edge：窗口铺满整屏（含状态栏/导航栏区域），
而 AppCompat 1.6.1 不会自动补 inset，于是页面顶部被标题栏盖住、内容压到状态栏下面。

| 项 | 变化 |
|---|---|
| 布局 | `res/layout/activity_fragment.xml` 由裸 `FrameLayout` 改为 `LinearLayout(root)` + `Toolbar(id=toolbar)` + `FrameLayout(id=fragmentContainer, weight=1)` |
| 代码 | `SingleFragmentActivity` 里 `WindowCompat.setDecorFitsSystemWindows(false)`；`setSupportActionBar(toolbar)`；`setOnApplyWindowInsetsListener` 把 `systemBars().top` 补成 Toolbar 的 paddingTop、`max(navigationBar, ime)` 补成内容底部 padding、左右补成内容左右 padding；状态栏图标颜色按 `uiMode` 深浅切换 |
| 主题 | `AndroidManifest.xml` 的 application theme 改为 `Theme.ZerotierFix.NoActionBar`（不再要系统 ActionBar）；`android:statusBarColor` 由 `?attr/colorPrimaryVariant` 改为透明（状态栏区域由标题栏背景铺满） |
| 补丁 | `0004-fix-edge-to-edge-insets.patch`（父提交 `33e2b74`，可单独 `git am`） |
| 产物 | 同名覆盖 `artifacts/ZerotierFix-1.16.2-debug.apk`，30,118,932 B，sha256 `cef1749d056ead9c671efd6d32472eb22e61ef30fad2498e27bd7e8a6cea3cc4` |

改动前 APK 已备份到 `.build/apk-before-edgefix.apk`（sha256 `30bc5959…`，未跟踪）。

---

## 1. 目录内容

```
patches/zerotierfix/
├── 0001-feat-planet-planet.patch      功能补丁（设置项 + 下载 + 落盘 + 回退）
├── 0002-build-JDK17-Gradle-8.7-AGP-8.6.1-compileSdk-targetSd.patch
│                                       构建现代化补丁（AGP/Gradle/SDK/NDK）
├── 0003-core-1.16.2-jni.patch         阶段2：JNI 适配 core 1.16.2（C++17 + 源文件集 + prometheus）
├── 0004-fix-edge-to-edge-insets.patch 阶段3：Android 15 edge-to-edge（标题栏不再遮挡内容）
├── build.sh                            可复现构建脚本（生成 local.properties + 构建 + 收产物）
├── README.md                           本文件
└── test/
    ├── PlanetSyncHarness.java          端到端验证程序（真实 HTTP 服务 + 生产代码）
    ├── run-planet-sync-test.sh         一键运行（JDK 直接跑，不需要 Android 设备）
    ├── real-planet-official.bin        官方内置 planet（570 字节，取自 core 1.12.2 Topology.cpp）
    ├── planet-from-mkworld.bin       1.16.2 vendored mkworld 真实产物（276 字节）
    └── last-run.log                    最近一次验证输出（PASS=28 FAIL=0）
artifacts/
├── ZerotierFix-1.16.2-debug.apk       当前交付：core 1.16.2（arm64-v8a + armeabi-v7a）
└── ZerotierFix-1.12.2-debug.apk       阶段1 回退版：core 1.12.2
```

---

## 2. 打补丁

前置条件：`externals/core` 已换代到 **ZeroTierOne 1.16.2**（`fc5c3ec22`）并应用 `0003-core-1.16.2-jni.patch`
（步骤见 §0）。若只要阶段1（core 1.12.2），则子模块必须是 `d028a24795e4348615783f8f8b95207035595f56`
（= kaaass/ZeroTierOne 1.12.2 分支上的 core 版本），且不打 0003。

```bash
cd ZerotierFix
git checkout -b zt-stack master

# 方式一：保留提交信息
git am /path/to/zt-stack/patches/zerotierfix/*.patch

# 方式二：只要改动
git apply /path/to/zt-stack/patches/zerotierfix/0001-*.patch
git apply /path/to/zt-stack/patches/zerotierfix/0002-*.patch

# core 源码（github.com 不可达时用可用的代理克隆后 checkout 到该 commit）
git submodule update --init externals/core
```

补丁已在干净 master 上验证可用（`git am` 全绿），共改动 **15 个文件**（11 改 / 3 增 / 1 删）。

### 补丁改了什么

**0001（功能）**

| 文件 | 作用 |
| --- | --- |
| `util/PlanetSyncer.java`（新） | 纯 Java：下载 → 校验 → 备份 → 原子落盘。不依赖任何 Android API，因此可以在桌面 JVM 上直接验证 |
| `service/PlanetSyncManager.java`（新） | Android 侧粘合：读配置、决定是否需要同步、落盘后维护 `planet_use_custom` 开关、失败回退 |
| `service/ZeroTierOneService.java` | `onStartCommand` 里 **创建 Node 之前**插入同步调用 + 失败提示 |
| `ui/PrefsFragment.java` | 「行星服务器」设置项与配置对话框（保存并同步） |
| `res/xml/preferences.xml`、`res/layout/dialog_planet_server.xml`（新）、`values/strings.xml`、`values-zh/strings.xml` | 设置项与界面文案 |
| `util/Constants.java` | 新设置键名、临时/备份文件名 |

**0002（构建）**：根 `build.gradle`（AGP 8.6.1、镜像、SDK 版本、greendao 插件 3.3.1）、
`app/build.gradle`（compileSdk 35、buildTools 35.0.0、lombok 1.18.34、`buildConfig true`）、
`core/build.gradle`（namespace、显式 srcDirs、ndkVersion、ABI 过滤）、
`core/src/main/AndroidManifest.xml`（去掉 `package`）、`gradle/wrapper/gradle-wrapper.properties`（Gradle 8.7）。

---

## 3. 构建

### 3.1 一行构建

```bash
bash zt-stack/patches/zerotierfix/build.sh
# 产物：zt-stack/artifacts/ZerotierFix-stage1-debug.apk
```

脚本做的事：写 `ZerotierFix/local.properties`（`sdk.dir`/`cmake.dir`/`ndk.dir`）→
设置 `JAVA_HOME`/`GRADLE_USER_HOME`/临时目录 → `./gradlew assembleDebug` → 复制 APK 到 `artifacts/`。

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `JAVA_HOME` | `D:/Projects/MM678/build-android/tools/jdk-17.0.20.1+1` | **必须 JDK17**（PATH 上的 java 是 1.8，AGP 8 不支持） |
| `ANDROID_SDK_ROOT` | `D:/Projects/MM678/build-android/android-sdk` | 需含 platform 35 + build-tools 35.0.0 |
| `NDK_DIR` | `$ANDROID_SDK_ROOT/ndk/android-ndk-r28c` | r28c（28.2.13676358） |
| `CMAKE_DIR` | `<zt-stack>/.build/.toolchain/cmake-3.22.1` | core 的 `cmake_minimum_required(3.2)` 在 CMake 4 上会被拒绝，必须 3.22.x |
| `GRADLE_USER_HOME` | `<zt-stack>/.build/.gradle-home` | 本机 Java 进程无法写用户目录，缓存放 zt-stack 内 |
| `ANDROID_USER_HOME` | `<zt-stack>/.build/.android-home` | AGP 用户目录，debug.keystore 在这里 |
| `TMP_ROOT` | `<zt-stack>/.build/.tmp` | 同上，JVM 临时目录 |
| `BUILD_ROOT` | `<zt-stack>/.build` | 以上四个目录的根；`<zt-stack>` 由脚本位置推导，换机器无需改 |

> **所有构建期缓存/临时目录都在 `zt-stack/.build/` 下**（见上表的默认值），构建过程不向工作区根目录
> （`D:/Projects/zerotier/`）写任何东西；`zt-stack/.gitignore` 已忽略 `.build/`。

### 3.2 版本矩阵

| 组件 | 上游 | 本阶段 |
| --- | --- | --- |
| JDK | 未固定 | **17**（17.0.20.1+1） |
| Gradle | 7.5 | **8.7** |
| AGP | 7.4.2 | **8.6.1** |
| compileSdk / targetSdk | 33 / 33 | **35 / 35** |
| minSdk | 19 | **21**（见下） |
| build-tools | 未固定 | **35.0.0** |
| NDK | 未固定 | **28.2.13676358 (r28c)** |
| CMake | 3.22.1 | 3.22.1（外部安装，`cmake.dir`） |
| greendao-gradle-plugin | 3.3.0 | **3.3.1** |
| lombok | 1.18.20 | **1.18.34** |
| ZeroTier core | 1.12.2 | 1.12.2（**未变**） |

**minSdk 19 → 21 的原因（不是 AGP 强制，是 NDK 强制）**：
本机 NDK r28c 的 `meta/platforms.json` 为 `"min": 21`，NDK r26 起已不支持 API < 21 的目标。
要保 19 必须换 NDK r25c 级别（另需 ~1GB 下载）。阶段1 选择上调到 21 并在本文件说明；
Android 5.0 以下设备（API 19/20）将无法安装本 APK。

### 3.3 依赖镜像（网络受限时）

- **Gradle 发行包**：`services.gradle.org` 在本机不可达（8s 超时），wrapper 改走
  `https://mirrors.cloud.tencent.com/gradle/gradle-8.7-bin.zip`（实测 200）。
- **Maven 仓库**：`build.gradle` 里 `maven.aliyun.com/repository/google`、`.../public` 优先，
  其后仍是 `google()` / `mavenCentral()` 兜底；本机 `dl.google.com`、`repo.maven.apache.org` 直连可用，
  所以两条路都通。换机器时若阿里云缺包，Gradle 会自动回落到官方仓库。

### 3.4 构建期已知的坑（环境相关，非代码问题）

1. `local.properties` 的 `ndk.dir` 会打印 `[CXX5106] deprecated` 警告——因为 SDK 里 NDK 目录名是
   `android-ndk-r28c` 而非 `28.2.13676358`，只能靠 `ndk.dir` 指过去；`ndkVersion` 必须同值否则 AGP 报 `CXX1104`。
2. `app:stripDebugDebugSymbols` 用 AGP 默认 NDK（26.1）剥符号失败，`libZeroTierOneJNI.so`
   以未剥离形式打包（APK 偏大，功能无影响）。
3. Gradle 偶尔报 `Could not move temporary workspace ... to immutable location`，
   是文件锁/索引器的瞬时冲突，重跑即可（本次构建遇到 1 次，重跑通过）。

---

## 4. App 内怎么填地址

设置页 → **Planet 设置** → **行星服务器（自动下载）**：

| 字段 | 说明 | 默认 |
| --- | --- | --- |
| Planet 文件地址 | 例如 `http://1.2.3.4:3000/planet`。不带协议头会自动补 `http://` | 空（= 关闭，保持原有行为） |
| 下载 token（可选） | 以 `Authorization: Bearer <token>` 头发送 | 空 |
| 期望 sha256（可选） | 填了就强校验（大小写、冒号分隔都能识别）；不填只校验类型与长度 | 空 |
| 每次启动都重新下载 | 打开后每次连接都拉一次；关闭时只在本地没有可用 planet 时才拉 | **关** |

点「保存并同步」会立刻下载一次，成功后面板提示「已从服务器更新 planet」。

**接口契约（供 planet 服务端对接）**：GET 目标 URL，返回原始 planet 二进制；
需要鉴权时用 `Authorization: Bearer <token>`；也接受 301/302/307/308 重定向（最多 3 跳）。

相关设置键（`SharedPreferences`）：`planet_server_url`、`planet_server_token`、
`planet_server_sha256`、`planet_server_auto_update`、`planet_server_last_sync`。

---

## 5. 启动链路：从地址到 core 读到的 planet

```
ZeroTierOneService.onStartCommand                (app/src/main/java/.../service/ZeroTierOneService.java:358)
  └─ PlanetSyncManager.syncBeforeStart()          (service/PlanetSyncManager.java:74)
       ├─ isEnabled()?  URL 为空 → return null     → 完全走原有路径（不下载、不碰任何文件/开关）
       ├─ needsSync()?  自动更新开 / 本地无合法 planet 时才下载
       ├─ syncNow()                               (service/PlanetSyncManager.java:98)
       │    └─ PlanetSyncer.downloadAndInstall()  (util/PlanetSyncer.java:109)
       │         GET url (4s 连接 / 6s 读取 / 总预算 8s / 最多 2 次) → cache 无关，直接写 filesDir/planet.custom.tmp
       │         校验：size ∈ [178, 65536] 且 首字节 == 0x01（World type = TYPE_PLANET）
       │         可选 sha256 比对
       │         备份：原 planet.custom → planet.custom.bak（先删旧备份）
       │         原子落盘：planet.custom.tmp → planet.custom
       └─ 只有 planet.custom 合法时把 planet_use_custom 置 true，否则置 false
  └─ new Node(...).init(dataStore, ...)           core 启动
```

**落盘路径为什么就是这个文件**（这一点是本阶段的关键复用，未改动内核）：

- core 1.12.2 的 planet 是「状态对象」：`Topology::Topology` 调用
  `stateObjectGet(ZT_STATE_OBJECT_PLANET, ...)`（core 源码 `node/Topology.cpp:37`，对照用源码克隆在
  `zt-stack/.build/.core-src/`，非构建依赖，可删）。
- JNI 把该状态对象映射成文件名 `"planet"`
  （`externals/core/java/jni/com_zerotierone_sdk_Node.cpp:348`）。
- 应用侧 `DataStore.onDataStoreGet("planet")` 在 `planet_use_custom = true` 时把名字重定向到
  `Constants.FILE_CUSTOM_PLANET = "planet.custom"`（`service/DataStore.java:98,135`），
  路径就是 `getFilesDir()/planet.custom`。
- 因此本阶段只是「把 planet.custom 换成自动下载来的」，内核读取路径完全不变。

---

## 6. 失败回退与「不卡死启动」

| 情况 | 行为 |
| --- | --- |
| 没填地址 | 不下载，不读写任何文件与开关，行为与上游完全一致 |
| 下载/校验失败，且已存在合法 `planet.custom` | 保持 `planet_use_custom = true`，继续用**上一份** planet；Toast 提示「当前使用上一份已校验的 planet」 |
| 下载/校验失败，且本地没有可用 planet | 把 `planet_use_custom` 置 false → `onDataStoreGet` 不再重定向，core 读不到自定义 planet，`Topology` 落到**编译进内核的官方 planet**（`Topology.cpp:46-51`：`addWorld(defaultPlanet, false)`）；Toast 提示「当前使用 ZeroTier 内置 planet」 |
| 服务端返回 404/超时/魔数错误/长度不足/sha256 不匹配 | 都是「一次失败」，不覆盖现有 planet（临时文件删除，目标文件不动） |

「不卡死启动」的三道保险：

1. **跳过**：没配地址、或没开自动更新且本地已有合法 planet → 0 次网络调用。
2. **有界重试**：每次尝试 4s 连接 + 6s 读取，最多 2 次，并且总预算 `TOTAL_BUDGET_MS = 8000`；
   预算耗尽立刻停止（`PlanetSyncer.java:33,119-124`）。
3. **失败不阻断**：无论同步结果如何，函数返回后 core 照常初始化（回退到上一份/内置 planet）。

> 说明：同步发生在 `onStartCommand`（主线程），最坏阻塞约 8 秒（仅在首次或开启自动更新时），
> 低于 Android 对 Service 的 20s ANR 阈值。这是阶段1 的取舍，见「已知风险」。

---

## 7. 未配置地址 = 原有行为（代码路径）

```java
// service/PlanetSyncManager.java:74
public static PlanetSyncer.Result syncBeforeStart(Context context) {
    if (!isEnabled(context)) {        // URL 为空（含全空白）
        return null;                  // ← 不下载、不写 prefs、不碰 planet.custom
    }
    ...
}
```

调用点（`ZeroTierOneService.java:358`）：

```java
notifyPlanetSyncResult(PlanetSyncManager.syncBeforeStart(this));  // 返回 null 时 notify 方法直接 return
```

因此未配置地址时：

- 不会发起任何网络请求（`isEnabled` 在最外层判断）；
- 不会修改 `planet_use_custom`、不会新增/删除 `planet.custom`/`planet.custom.bak`；
- 设置页新增的入口只在用户点开后才有写操作，旧的两个设置项（「启动自定义 Planet」「设置 Planet 文件」）行为不变。

---

## 8. 验证

### 8.1 客户端端到端验证（可复跑，不需要设备）

```bash
bash zt-stack/patches/zerotierfix/test/run-planet-sync-test.sh D:/Projects/zerotier/ZerotierFix
```

它用 JDK17 编译 **App 里真实的生产代码**（`Constants.java` + `PlanetSyncer.java`，两者都不 import Android），
再起一个真实 HTTP 服务把 planet 下发到 App 使用的同一个文件名，28 项断言全绿：

```
PASS=28 FAIL=0
```

覆盖：首次下载与落盘文件名（`planet.custom`）、内容一致、临时文件清理、sha256 一致性、
二次下载覆盖 + 上一份备份（`planet.custom.bak` = 旧内容）、魔数错误被拒且不破坏现有 planet、
长度不足被拒、sha256 不匹配被拒、sha256 大写/冒号匹配、404 重试次数 = 2、Bearer token 下发、
地址补全、真实官方 planet（570 字节）下载与校验、**1.16.2 mkworld 真实产物（276 字节）**下载与校验。
原始输出见 `test/last-run.log`。

### 8.2 构建产物

| 项 | 值 |
| --- | --- |
| APK（当前交付） | `D:\Projects\zerotier\zt-stack\artifacts\ZerotierFix-1.16.2-debug.apk`（core 1.16.2） |
| 大小 | 30,118,932 字节（28.72 MiB） |
| SHA256 | `cef1749d056ead9c671efd6d32472eb22e61ef30fad2498e27bd7e8a6cea3cc4`（阶段3，含 0004；阶段2 为 `30bc5959…`） |
| APK（阶段1 回退） | `artifacts\ZerotierFix-1.12.2-debug.apk`（core 1.12.2） |
| 大小 / SHA256 | 22,736,354 字节 / `e0622299f9c137520d76e4a3bde2e874aeafcc63de35c7cf3da947587674cd91` |
| 内含 | `lib/arm64-v8a/libZeroTierOneJNI.so`（24,197,008 B）、`lib/armeabi-v7a/libZeroTierOneJNI.so`（21,503,892 B）、`classes*.dex` ×12 |
| 构建命令 | `bash build.sh` → `./gradlew assembleDebug`（Gradle 8.7 / AGP 8.6.1 / NDK r28c / CMake 3.22.1）；产物名随 core tag 走：`ZerotierFix-<core 版本>-debug.apk` |
| core 换代证据 | `llvm-nm -C --defined-only lib/arm64-v8a/libZeroTierOneJNI.so` 可见 255 个 `ZeroTier::ECC::`/`ZeroTier::Bond::`/`Capability::` 等 1.16.2 独有符号 |
| hash 说明 | APK 内嵌 zip 条目时间戳，**每次重跑 hash 都不同**；可复现性只到「构建成功 + 大小量级一致」，不要用 hash 做等价判断 |
| 代码确实在包内 | `javap` 可见 `PlanetSyncManager.syncBeforeStart`、`PlanetSyncer.TOTAL_BUDGET_MS=8000`；dex 内能 grep 到 `planet_server_url`、`PlanetSyncManager`、`planet.custom.bak` |

### 8.3 未在本阶段验证的内容（不要当成已验证）

- **真机/模拟器安装运行（含阶段2）**：阶段2 的 1.16.2 APK 已在真机安装并连上自建网络（`Vnimy-Home`，
  `192.168.200.180`），阶段1 未做过。**阶段3 的 edge-to-edge 修复只做了源码级确认（布局/资源确实进包），
  没有真机截图或 UI 走查**；本机 `adb` 仍无法启动 daemon（`cannot open ...\adb.log: Permission denied`）。
- **真实 planet 服务端联调**：W2 的 planet 服务端与 token 实现完成后才能做（本阶段只规定接口契约）。
- **core 1.12.2 在设备上加载 1.16.2 mkworld 产物并联网**：解析器与产物层面已实测（见风险 1），
  设备端加载与互通未验证。阶段2 起客户端与 planet 节点同为 1.16.2，这条只影响仍装 1.12.2 APK 的旧设备。
- **1.16.2 core 的 Android 运行时行为**：加密握手（`enableEncryptedHello=0` 仍按 1.12.2 口径关闭）、
  Metrics/prometheus 后台线程在移动端的开销，均未实测。

---

## 9. 已知风险

1. **core 1.12.2 对新（1.16.2 mkworld）planet 格式的兼容性 —— 结论：兼容（源码比对 + 解析器/产物双向实测；设备端未验证）。**
   - 格式布局未变：`node/World.hpp` 的 `serialize`/`deserialize` 字段顺序在 1.12.2 与 1.16.2 完全一致，
     差异只有类型名（`ZT_C25519_*` → `ZT_ECC_*`）与代码格式；两版公钥长度都是 64、签名长度都是 96，
     即 **字节级同构**。1.12.2 能解析 1.16.2 mkworld 生成的文件。
   - 能否生效：`Topology` 先装磁盘上的 planet，再 `addWorld(defaultPlanet, false)`；
     `World::shouldBeReplacedBy` 只有在 **id 相同 且 时间戳更新 且 签名验证通过** 时才会被默认 planet 覆盖。
     因此：id 不同 → 自定义 planet 必定生效；id 相同 → 只要 planet 的 ts 比内置 planet 新（mkworld 用当前时间）也生效。
   - **解析器实测（1.16.2 → 1.12.2 时代文件）**：用 W2 目录下 vendored 的 1.16.2 mkworld 执行
     `mkworld verify real-planet-official.bin`（1.12.2 时代的官方 planet，570 字节），输出
     `type=planet / world_id=149604618 / roots=4 / signature_valid=true`，退出码 0 —— 两个版本的解析器互相认得对方的文件。
   - **产物实测（客户端校验）**：用 1.16.2 mkworld 现场生成 `planet-from-mkworld.bin`（276 字节，
     world_id 与官方一致、ts 为当前时间），客户端校验与落盘用例全绿（见 8.1）。
   - **仍需真机闭环**：1.12.2 core 在设备上实际用它联网并互通，本阶段无设备未做，留给 W4 集成测试。
2. **minSdk 21**：Android 5.0 以下（API 19/20）无法安装。要恢复必须把 NDK 换回 r25 级别。
3. **启动期主线程最多阻塞 ~8s**（仅首次或开启「每次启动都重新下载」时）。若服务端不可达且启用了自动更新，
   每次连接都会付出这段延迟（但仍会成功启动并回退）。想避免就把自动更新关掉。
4. **planet 未做签名校验**：客户端只校验类型/长度（可选 sha256）。planet 的可信度依赖 HTTPS 或
   用户在「期望 sha256」里钉死摘要。用明文 HTTP 且不填 sha256 时，链路上谁都能换掉你的 planet（阶段1 接受该取舍）。
5. **token 契约只有一种**：`Authorization: Bearer <token>`。若服务端只认 `?token=` 查询参数，
   需要在阶段2 加一个开关（当前未实现，避免把 token 写进 URL 日志）。
6. **配置地址会覆盖手动开关**：填了地址且同步成功后，`planet_use_custom` 会被强制置 true（否则地址不生效）。
   这是有意设计，界面上「启动自定义 Planet」开关会被同步刷新。
7. **上游软链接被替换**：上游用软链接把 `core/src/main/java` 指向 `externals/core/java/src`，
   Windows 检出会把它落成普通文本文件（构建必然失败），补丁改为显式 `java.srcDirs`。
   上游若重构该布局，需要同步调整。
8. **构建环境敏感**：JVM 需要可写的 `java.io.tmpdir`/`user.home`（本机只能用 zt-stack 内的路径），
   NDK 依赖 `ndk.dir`（已废弃 API），core 的 CMake 最低版本 3.2 与 CMake 4 不兼容。
   换机器时按 3.1 的变量表覆盖即可。
