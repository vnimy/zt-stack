# ZeroTier：填地址即用（行星服务器）+ 工具链现代化

本文件是 ZeroTier（基于 `kaaass/ZerotierFix` master 的 `vnimy/ZeroTier` 仓库）的历史交付记录：
包含可复现的补丁序列、构建脚本、客户端端到端验证脚本，以及各版本 APK 的交付信息。

> **2026-11-11 起**：补丁序列（0001–0013）已移除，Android 客户端源码以 [vnimy/ZeroTier](https://github.com/vnimy/ZeroTier) 为准；
> 构建脚本见 `tools/build-client.sh`，端到端测试见 `tests/zerotierfix/`。以下内容保留为历史记录。

- **阶段1**：App 里直接填「行星服务器地址」，启动时自动下载 planet（免手动导入 planet 文件）；
  用现代工具链（JDK17 / Gradle 8 / AGP 8 / compileSdk 35）能构建出 APK。core 保持 **1.12.2**。
- **阶段2**：把 core 从 1.12.2 换成 **1.16.2**（与自建 planet 节点同版本）。Java 层零改动，
  只重写 `externals/core/java/CMakeLists.txt` 并换代 core 源码。
- **阶段3**：修 Android 15（targetSdk 35）强制 edge-to-edge 导致的「标题栏盖住页面顶部」，见 §0.1。
- **阶段4**：连接时改为前台服务（切后台不再被系统回收）+ 通知栏「断开连接」按钮；移除从未生效的开机自启接收器，见 §0.2。
- **阶段5**：网络详情展示路由表；设置页支持**扫码导入**行星服务器地址（含 token），见 §0.3。
- **阶段6**：切换 Wi-Fi / 蜂窝网络后自动重新保护套接字、恢复收包线程，并即时执行「是否允许移动网络」策略，见 §0.4。
- **阶段7**：设置页「检查更新」——服务端新增 `/version.json` 与 `/app/zerotier.apk`，客户端比对 `versionCode` 后提示下载，见 §0.5。
- **阶段8**：Android 快捷设置磁贴（Quick Settings Tile）——在系统下拉快捷设置中添加 ZeroTier 后，可一键连接/断开 VPN；磁贴状态与前台服务同步，断开时 App 内开关复位；长按磁贴直接打开 App（不再进入应用信息页）。
- **补丁 0011**：品牌与包名迁移——显示名统一为 ZeroTier，`applicationId` / 包名改为 `com.vnimy.zerotier`，版本 2.0.0 / versionCode 18；旧包名 `net.kaaass.zerotierfix` 不再升级，需要卸载后重新安装。
- **补丁 0012**：加入网络页面支持**扫描二维码**——识别二维码中的 16 位网络 ID（兼容纯 ID、带分隔符、`https://my.zerotier.com/network/<id>`、`zerotier://<id>` 与 JSON），扫描后填入输入框；版本 2.0.1 / versionCode 19。
- **补丁 0013**：主题色对齐官方 ZeroTier——主色改为 `#fac073`，顶部栏、状态栏遮罩、开关与页脚配色统一；版本 2.0.2 / versionCode 20。

> 当前交付 APK 是**补丁 0013（2.0.2）**：`artifacts/ZeroTier-1.16.2-debug.apk`（core 1.16.2 + edge-to-edge + 前台服务 + 路由表/扫码 + 网络切换自愈 + 检查更新 + 快捷设置磁贴（长按打开 App）+ 包名迁移 + 扫码添加网络 + 官方橙色主题，versionCode 20 / 2.0.2，包名 `com.vnimy.zerotier`）。
> 旧包名 1.0.13 的 `artifacts/ZerotierFix-1.16.2-debug.apk` 与阶段1 的 `artifacts/ZerotierFix-1.12.2-debug.apk`（core 1.12.2）保留作回退。

---

## 0. 阶段2 摘要（core 1.16.2）

| 项 | 变化 |
|---|---|
| core 源码 | `externals/core` 指向官方 `zerotier/ZeroTierOne @ fc5c3ec2`（1.16.2）。工作区保持干净，补丁在构建时临时应用 |
| JNI 适配 | Android 仓库 `tools/core-patches/0001-jni-1.16.2.patch`（与 `0003-core-1.16.2-jni.patch` 内容相同）：`CMakeLists.txt` 升 C++17、源文件集对齐 `objects.mk`、补 prometheus 头路径。`build.sh` 构建前 apply、结束时用 `trap` 自动 `git apply --reverse` 还原 |
| Java SDK | 无改动。1.12.2→1.16.2 官方只改了 `java/jni/com_zerotierone_sdk_Node.cpp`（`ZT_Node_Config`、线程附加 RAII），native 方法签名不变 |
| Rust | 不需要。`ZT_SSO_SUPPORTED=1` 才会链 `librustybits.a`，Android JNI 路径不定义该宏 |
| 产物 | 30,118,932 B，双 ABI，`llvm-nm` 可见 255 个 `ZeroTier::ECC::`/`Bond::` 等 1.16.2 独有符号 |
| 设备验证 | 真机安装并连上自建网络（阶段2 APK 实测连接成功）；edge-to-edge 的视觉修复未拍照确认，见 §8.3 |

core 的可复现步骤（不需要手工 `git am`）：

```bash
git submodule update --init externals/core
git -C externals/core rev-parse --short HEAD     # 应为 fc5c3ec（官方 1.16.2）
# build.sh 会在构建前自动 apply tools/core-patches/0001-jni-1.16.2.patch，
# 构建结束后反向还原，所以 externals/core 永远是干净的上游检出版本
# 切 core 版本后必须清掉旧产物，否则 CMake 缓存会把旧对象文件带过来
rm -rf core/.cxx core/build
```

---

## 0.1 阶段3 摘要（Android 15 edge-to-edge）

targetSdk 35 在 Android 15+ 上强制 edge-to-edge：窗口铺满整屏（含状态栏/导航栏区域），
而 AppCompat 1.6.1 不会自动补 inset，于是页面顶部被标题栏盖住、内容压到状态栏下面。

| 项 | 变化 |
|---|---|
| 布局 | `res/layout/activity_fragment.xml` 由裸 `FrameLayout` 改为 `LinearLayout(root)` + `View(id=statusBarScrim)` + `Toolbar(id=toolbar)` + `FrameLayout(id=fragmentContainer, weight=1)`；**根容器不染色**（否则整屏铺满主色） |
| 代码 | `SingleFragmentActivity` 里 `WindowCompat.setDecorFitsSystemWindows(false)`；`setSupportActionBar(toolbar)`；`setOnApplyWindowInsetsListener` 把 `systemBars().top` 设成 `statusBarScrim` 的高度（状态栏那条与标题栏同为**页面底色**，不再有紫色色块；标题栏自身高度仍是 `?attr/actionBarSize`，不会被压扁）、`max(navigationBar, ime)` 补成内容底部 padding、左右补成内容左右 padding；状态栏图标颜色按 `uiMode` 深浅切换 |
| 主题 | `AndroidManifest.xml` 的 application theme 改为 `Theme.ZerotierFix.NoActionBar`（不再要系统 ActionBar）；`android:statusBarColor` 改为透明；标题栏与状态栏遮罩都用 `?android:attr/windowBackground`（与内容区同色），标题文字 `?android:attr/textColorPrimary`；`values-night` 只保留 `PopupOverlay`（`ThemeOverlay.AppCompat.Dark`，修夜间黑底黑字） |
| 补丁 | `0004-fix-edge-to-edge-insets.patch`（父提交 `a24fb8b`，可单独 `git am`） |
| 产物 | 同名覆盖 `artifacts/ZerotierFix-1.16.2-debug.apk`，30,118,932 B，sha256 `348768903d989ee592ab1948c8eeeaf2d61016dbca00f9a418c59a71f05112a4`（阶段3 当时的包；后续阶段会覆盖同名文件，当前值见 §0.2） |

改动前 APK 已备份到 `.build/apk-before-edgefix.apk`（sha256 `30bc5959…`，阶段2 原包）。中间版本（紫色标题栏）备份在 `.build/apk-before-barchange.apk`（sha256 `be7df04b…`）。

---

## 0.2 阶段4 摘要（前台服务 + 通知断开）

| 项 | 变化 |
|---|---|
| 前台服务 | `ZeroTierOneService` 连接成功后调 `startForeground(ZT_NOTIFICATION_TAG, notification)`（API 34+ 用 `ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE`）；`startForeground` 抛异常（如 Android 12+ 后台启动被拒、缺通知权限）时退回 `notificationManager.notify`，行为与旧版一致 |
| 权限 | manifest 新增 `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_SPECIAL_USE`；service 声明 `android:foregroundServiceType="specialUse"` + `<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="vpn" />` |
| 通知权限 | Android 13+ 通知需运行时授权：`NetworkListActivity.onCreate` 首次启动申请 `POST_NOTIFICATIONS`（`SharedPreferences` 记一次，拒绝后不再弹；用户可在系统设置里补开）。没有该权限时前台服务照常运行，但通知与「断开连接」按钮不可见 |
| 通知动作 | 通知新增「断开连接」按钮（`ACTION_DISCONNECT` 显式 Intent → `PendingIntent.getService`），`onStartCommand` 收到后走 `stopZeroTier()` + `stopSelf()`，与系统撤销 VPN 权限同一套清理逻辑；`stopZeroTier()` 末尾 `stopForeground(true)` |
| 开机自启 | 删除 `service/StartupReceiver.java`（原本只打一行日志）、manifest 里的 `<receiver BOOT_COMPLETED>` 与孤立常量 `PREF_GENERAL_START_ZEROTIER_ON_BOOT`。开机自启改用系统「始终开启的 VPN」（设置 → 网络 → VPN → 齿轮 → Always-on VPN），见 `docs/OPERATIONS.md` §6.5 |
| 补丁 | `0005-feat-foreground-service-disconnect.patch` |
| 产物 | 30,118,932 B，sha256 `7068be7da5c422d54eca3a22ac726b9636cccc8351dd1ba941a8655c47f1f647`（阶段4 当时的包；当前值见 §0.3） |

---

## 0.3 阶段5 摘要（路由表 + 扫码导入）

| 项 | 变化 |
|---|---|
| 路由表 | 网络详情页「Managed IPs」下新增「Routes」行：遍历 `VirtualNetworkConfig.getRoutes()`，显示 `目标/前缀`，有下一跳时追加 `→ <via>`，默认路由（前缀 0 且地址为 `0.0.0.0`/`::`）追加「(默认路由)」；无路由显示「无」。表格外包 `ScrollView`，路由多时不会把页面撑破 |
| 路由实现细节 | `VirtualNetworkRoute.getTarget()` 的 port 字段就是前缀长度；**1.16.2 的 JNI 不填充 `flags`**，所以判断默认路由用「前缀为 0 且地址是 any」，不要读 flags；关闭 IPv6 时 `inetSocketAddressToString()` 返回 null，跳过该条 |
| 扫码导入 | 设置页「行星服务器」下新增「扫描二维码导入」：`zxing-android-embedded 4.3.0`，首次点按申请 `CAMERA` 权限；扫到的内容允许省略协议（自动补 `http://`），`?token=xxx` 会被取出来单独写入 token 项，然后把去参数后的地址写进行星服务器地址并立即触发一次 planet 同步 |
| 权限 | zxing 的 manifest 合并进 `android.permission.CAMERA`（安装时会多一项相机权限） |
| 补丁 | `0006-feat-routes-and-qr-import.patch`（父提交 `2cca20c`，可单独 `git am`） |
| 产物 | 30,119,156 B，sha256 `e02afc18bff785629e573b92aba84e6ea6d11f3bb5dd02ea8ce82c314d612637` |

二维码内容格式（与客户端约定）：`https://<域名或IP>:<端口>/?token=<下载口令>` 或 `https://<域名或IP>/planet?token=...` 都行 ——
客户端只取 `host(:port)` 作为行星服务器地址，`token` 参数单独保存，路径部分忽略。

---

## 0.4 阶段6 摘要（网络切换自愈）

手机在 Wi-Fi 与蜂窝网络之间切换时，底层 UDP 套接字与收包线程可能失效，表现是图标还显示「已连接」但网络不通，必须手动断开重连。

| 项 | 变化 |
|---|---|
| 网络监听 | `ZeroTierOneService` 用 `ConnectivityManager.registerNetworkCallback` 订阅 `INTERNET + NOT_VPN` 的物理网络集合（`NOT_VPN` 避免把应用自己的 tun 当成物理链路）；`onAvailable`/`onLost` 维护 `Set<Network>` 后统一处理 |
| 切换处理 | 网络集合变化时：① 只剩蜂窝且设置里未允许移动网络 → 提示并断开（与启动时的策略一致）；② 否则对 `svrSocket` 重新 `protect()`，让它跟随新的默认网络；③ 若收包线程已退出则重新拉起 |
| 收包线程加固 | `UdpCom.run()` 以前遇到 `SocketException` 会直接结束线程，节点从此收不到任何包；现在会判断套接字是否已关闭，未关闭则记日志、退避 200ms 后继续收包 |
| 生命周期 | `onStartCommand` 里幂等注册（重复启动不会重复注册），`onDestroy` 里注销并清空网络集合 |
| 补丁 | `0007-feat-network-change-resilience.patch`（父提交 `983ad79`，可单独 `git am`） |
| 产物 | 30,119,156 B，sha256 `37803830697d365a2d5a2cd31606605ca4490db2b7b3a04af05e0ae80d062740` |

注意：`android.net.Network` 与本项目模型类 `com.vnimy.zerotier.model.Network` 同名，代码里用全限定名 `android.net.Network`，不要加 import。

---

## 0.5 阶段7 摘要（应用内检查更新）

没有应用商店，所以自己搭一条最小更新通道：服务端出一个 JSON 清单，客户端比对 `versionCode`，有新版就弹窗引导下载。

| 项 | 变化 |
|---|---|
| 服务端清单 | `planet-node/planet-files.py` 新增 `GET /version.json`，从数据目录的 `version.json` 读取（每次请求重读，改文件不用重启容器）；字段 `versionCode`（必填、必须是整数）、`versionName`、`url`、`notes`。文件不存在 → 404，JSON 非法或字段类型不对 → 500 |
| 服务端安装包 | 新增 `GET /app/zerotier.apk`，读取数据目录的 `zerotier.apk`（复用 `_serve_file`，带 `X-File-SHA256`）；下载首页加一条「Android client」链接 |
| 客户端入口 | 设置页末尾新增「关于」分类与「检查更新」项 |
| 检查逻辑 | 取行星服务器地址的 `scheme://authority` 拼 `/version.json`（`https://zt.vnimy.com/planet` → `https://zt.vnimy.com/version.json`），连接/读取超时各 6s，只读前 64KB；`versionCode` 不大于当前 → 提示已是最新，否则弹窗显示 `versionName` 与 `notes`，「去下载」用 `ACTION_VIEW` 打开 `url` |
| 版本号 | `versionCode 15` / `versionName 1.0.11` |
| 补丁 | `0008-feat-in-app-update-check.patch`（父提交 `3318dec`，可单独 `git am`） |
| 产物 | 23,900,797 B，sha256 `3a55ad113197d07d9f38cd425803f58ecfc6545a8078f63daf83726ae2309ea0` |

**体积为什么反而变小了**：阶段2~6 的 APK 在 `META-INF/MANIFEST.MF` 之后都带着一段 **6,490,152 字节的未被索引空洞**（历史构建残留的垃圾数据，zip 目录里的条目数 1044 并没有包含它）。阶段7 的构建没有这段空洞，条目数 1047，两个 `.so` 与所有 dex 逐字节不减，所以只是去掉了垃圾。`apksigner verify` 仍是 v1+v2 通过，证书与旧包相同，可覆盖安装。

---

## 1. 目录内容

```
patches/zerotierfix/
├── 0001-feat-planet-planet.patch      功能补丁（设置项 + 下载 + 落盘 + 回退）
├── 0002-build-JDK17-Gradle-8.7-AGP-8.6.1-compileSdk-targetSd.patch
│                                       构建现代化补丁（AGP/Gradle/SDK/NDK）
├── 0003-core-1.16.2-jni.patch         阶段2：JNI 适配 core 1.16.2（C++17 + 源文件集 + prometheus）
├── 0004-fix-edge-to-edge-insets.patch 阶段3：Android 15 edge-to-edge（标题栏不再遮挡内容）
├── 0005-feat-foreground-service-disconnect.patch
│                                       阶段4：前台服务 + 通知栏断开按钮，移除空的开机自启
├── 0006-feat-routes-and-qr-import.patch 阶段5：网络详情路由表 + 扫码导入行星服务器
├── 0007-feat-network-change-resilience.patch 阶段6：网络切换自愈（重新保护套接字 + 恢复收包线程）
├── 0008-feat-in-app-update-check.patch 阶段7：设置页检查更新（服务端 /version.json + /app/ APK）
├── 0009-feat-quick-settings-tile.patch  阶段8：快捷设置磁贴（一键连接/断开 VPN）
├── 0010-fix-tile-long-press.patch       阶段9：磁贴长按改为打开 App + 版本号 1.0.13
├── 0011-refactor-package-com-vnimy-zerotier.patch 包名迁移：com.vnimy.zerotier + 品牌统一 + 2.0.0
├── 0012-feat-qr-add-network.patch       阶段12：加入网络支持扫描二维码识别网络 ID
├── 0013-feat-official-orange-theme.patch 阶段13：主题色对齐官方 ZeroTier（#fac073）
├── build.sh                            可复现构建脚本（生成 local.properties + 构建 + 收产物）
├── README.md                           本文件
└── test/
    ├── PlanetSyncHarness.java          端到端验证程序（真实 HTTP 服务 + 生产代码）
    ├── run-planet-sync-test.sh         一键运行（JDK 直接跑，不需要 Android 设备）
    ├── real-planet-official.bin        官方内置 planet（570 字节，取自 core 1.12.2 Topology.cpp）
    ├── planet-from-mkworld.bin       1.16.2 vendored mkworld 真实产物（276 字节）
    └── last-run.log                    最近一次验证输出（PASS=28 FAIL=0）
artifacts/
├── ZeroTier-1.16.2-debug.apk          当前交付：2.0.2 / versionCode 20，包名 com.vnimy.zerotier
├── ZerotierFix-1.16.2-debug.apk       旧包名回退：1.0.13 / versionCode 17
└── ZerotierFix-1.12.2-debug.apk       阶段1 回退版：core 1.12.2
```

---

## 2. 打补丁

前置条件：`git submodule update --init externals/core`，`externals/core` 应停在官方 **ZeroTierOne 1.16.2**（`fc5c3ec2`）。
JNI 适配不再需要手工 `git am`：`build.sh` 会在构建前应用 `tools/core-patches/0001-jni-1.16.2.patch`，构建结束自动还原。
若只想复现阶段1（core 1.12.2），需要把子模块切到 `d028a24795e4348615783f8f8b95207035595f56`（kaaass/ZeroTierOne 的 1.12.2 分支），此时不要打 core 补丁。

```bash
cd ZeroTier
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
bash zt-stack/tools/build-client.sh
# 产物：zt-stack/artifacts/ZeroTier-stage1-debug.apk
```

脚本做的事：写 `ZeroTier/local.properties`（`sdk.dir`/`cmake.dir`/`ndk.dir`）→
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
bash zt-stack/tests/zerotierfix/run-planet-sync-test.sh D:/Projects/zerotier/ZerotierFix
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
| APK（当前交付） | `D:\Projects\zerotier\zt-stack\artifacts\ZeroTier-1.16.2-debug.apk`（core 1.16.2，包名 `com.vnimy.zerotier`） |
| 大小 | 23,907,046 字节（22.80 MiB） |
| SHA256 | `a4d3e1c41d3843645b991769b241c1ddb6853c9ceabfaebb2172065448a15a8b`（补丁 0013，含 0003~0013 + 快捷设置磁贴 + 长按打开 App + 包名迁移 + 扫码添加网络 + 官方橙色主题，versionCode 20 / 2.0.2；旧包名 1.0.13 为 `e03413a8…`，阶段7 为 `3a55ad11…`，阶段6 为 `37803830…`，阶段5 为 `e02afc18…`，阶段4 为 `7068be7d…`，阶段3 为 `34876890…`，阶段2 为 `30bc5959…`） |
| APK（旧包名回退） | `artifacts\ZerotierFix-1.16.2-debug.apk`（1.0.13 / versionCode 17，包名 `net.kaaass.zerotierfix`） |
| 大小 / SHA256 | 23,906,940 字节 / `e03413a83b8593b3dc6d04fa48a07566a725fbcbb31548c5210d9a639dee0796` |
| APK（阶段1 回退） | `artifacts\ZerotierFix-1.12.2-debug.apk`（core 1.12.2） |
| 大小 / SHA256 | 22,736,354 字节 / `e0622299f9c137520d76e4a3bde2e874aeafcc63de35c7cf3da947587674cd91` |
| 内含 | `lib/arm64-v8a/libZeroTierOneJNI.so`（24,197,008 B）、`lib/armeabi-v7a/libZeroTierOneJNI.so`（21,503,892 B）、`classes*.dex` ×12 |
| 构建命令 | `bash build.sh` → `./gradlew assembleDebug`（Gradle 8.7 / AGP 8.6.1 / NDK r28c / CMake 3.22.1）；产物名随 core tag 走：`ZeroTier-<core 版本>-debug.apk` |
| core 换代证据 | `llvm-nm -C --defined-only lib/arm64-v8a/libZeroTierOneJNI.so` 可见 255 个 `ZeroTier::ECC::`/`ZeroTier::Bond::`/`Capability::` 等 1.16.2 独有符号 |
| hash 说明 | APK 内嵌 zip 条目时间戳，**每次重跑 hash 都不同**；可复现性只到「构建成功 + 大小量级一致」，不要用 hash 做等价判断 |
| 代码确实在包内 | `javap` 可见 `PlanetSyncManager.syncBeforeStart`、`PlanetSyncer.TOTAL_BUDGET_MS=8000`；dex 内能 grep 到 `planet_server_url`、`PlanetSyncManager`、`planet.custom.bak` |

### 8.3 未在本阶段验证的内容（不要当成已验证）

- **2.0.2 新包名真机安装与扫码添加网络**：本次只验证了构建、包名 `com.vnimy.zerotier`、versionCode 20 与签名证书（`944e16…`），
  尚未在设备上安装；旧包 `net.kaaass.zerotierfix` 需先卸载，网络配置需重新添加。扫码添加网络已通过单元测试与构建验证，尚未做真机扫码走查；橙色主题仅完成构建验证，尚未做真机视觉走查。
- **真机/模拟器安装运行（含阶段2）**：阶段2 的 1.16.2 APK 已在真机安装并连上自建网络（`Vnimy-Home`，
  `192.168.200.180`），阶段1 未做过。**阶段3 的 edge-to-edge 修复只做了源码级确认（布局/资源确实进包），
  没有真机截图或 UI 走查**；本机 `adb` 仍无法启动 daemon（`cannot open ...\adb.log: Permission denied`）。
- **真实 planet 服务端联调**：W2 的 planet 服务端与 token 实现完成后才能做（本阶段只规定接口契约）。
- **core 1.12.2 在设备上加载 1.16.2 mkworld 产物并联网**：解析器与产物层面已实测（见风险 1），
  设备端加载与互通未验证。阶段2 起客户端与 planet 节点同为 1.16.2，这条只影响仍装 1.12.2 APK 的旧设备。
- **1.16.2 core 的 Android 运行时行为**：加密握手（`enableEncryptedHello=0` 仍按 1.12.2 口径关闭）、
  Metrics/prometheus 后台线程在移动端的开销，均未实测。
- **检查更新的真机点击**：服务端 `/version.json` 与 `/app/zerotier.apk` 已在本机冒烟并线上 `curl` 通过
  （200、中文 notes 正常、APK 字节一致），客户端 `checkForUpdates()` 只做了编译与代码走查，
  没有在设备上点过「检查更新」；弹窗、跳转下载、以及「已是最新」分支都待真机确认。

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
