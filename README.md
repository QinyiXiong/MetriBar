# MetriBar 🌡️

<div align="center">

**简体中文** · [English](README.en.md)

</div>

一个 **macOS 菜单栏实时监视工具**：在菜单栏直接看到 **下载 / 上传速率 + CPU 温度 + 手表心率 ♥**，点开面板查看网络、CPU、GPU、风扇、内存与磁盘。

纯 **SwiftUI `MenuBarExtra(.window)`** 实现 —— 不写一行 AppKit `NSStatusItem`，没有 WidgetKit / 桌面小组件，没有 CoreData / CloudKit。

> 菜单栏效果：`↓12.4M ↑980K 72° ♥72`（仅数值与单位，不显示应用名称）

---

## 🖼 界面预览

离屏渲染自检图（`MetriBarDebugSnap`，真实数据）：

菜单栏实际提交给状态栏的位图（固定 **177×18pt @2x**、非模板渲染）：

![菜单栏位图](docs/预览/menubar-badge.png)
![浅色菜单栏](docs/预览/menubar-badge-light.png)

![弹出面板 · 深色](docs/预览/panel-dark.png)

App 图标（`AppIcon.icns`，1024→16px 全尺寸自绘 · 卡通小机器人 mascot：白机身 + 天青面罩 + kawaii 脸，呼应菜单栏 ♥）：

![App 图标](docs/预览/app-icon.png)

---

## 🎯 菜单栏为什么是「自绘位图」

`MenuBarExtra` 的 label 会被 macOS 状态栏按 **template（模板图）** 重绘，实测结果：

| 写法 | 结果 |
| --- | --- |
| `Text` + `foregroundColor` | 颜色全被抹平成单色（选中时反色成白/黑） |
| `Text("\(Image(systemName: …))")` | **SF Symbol 直接不显示**，只剩字面字符：`2.3K│3.5K│54°` |
| `Image(nsImage:)` + `isTemplate = false` + `.renderingMode(.original)` | ✅ 图标与配色原样保留 |

所以「丰富」排版用 **Core Text / `NSAttributedString`** 直接在 `NSBitmapImageRep` 上绘制，位图按主屏真实 `backingScaleFactor` 生成，标记 `isTemplate = false` 后交给 `MenuBarExtra`（`MenuBarBadge.swift`）。**固定图标 / 数值 / 单位槽位**让徽章尺寸恒定（177×18pt），数字变化也不抖动；开启字体平滑保证文字清晰。内容签名缓存，数值没变就不重画。「紧凑」排版仍走纯 `Text` 兜底。

---

## ✨ 特性

| 项目 | 说明 |
| --- | --- |
| 菜单栏 | 实时 **下载 ↓ / 上传 ↑ / CPU 温度**，可叠加 CPU、GPU 占用率；**两种排版：丰富（自绘非模板位图，图标 + 配色 + 分级字号）/ 紧凑（纯文本）**；等宽数字不抖动 |
| 弹出面板 | 上下行速率 + 比例条、CPU 温度（含传感器 key）、**CPU 占用 + GPU 占用（渲染/光栅细分）**、风扇转速/区间、内存（App / Wired / Compressed）、磁盘可用空间 |
| 后台采集 | `DispatchSourceTimer` + 独立串行队列，1–10 秒可调（默认 2 秒），**主线程零系统调用** |
| 开机自启 | `SMAppService.mainApp`（macOS 13+），设置页一键开关并显示真实注册状态，带**自愈**：迁移到 `/Applications` 后自动重指向正确副本 |
| 原生观感 | `ultraThinMaterial` 背景、圆角卡片、深浅色自适应、系统控件尺寸与字号 |
| 硬件读取 | [SMCKit](https://github.com/srimanachanta/SMCKit)（MIT）访问 AppleSMC：CPU 温度、风扇转速 |
| GPU 占用 | IOKit `IORegistry` → GPU accelerator（Apple Silicon 为 `AGXAccelerator…`）的 `PerformanceStatistics`，指数平滑防跳变 |
| 心率 ♥ | CoreBluetooth **BLE** 连接支持「广播心率」的手表（Garmin fenix 8 等），订阅标准心率服务 `0x180D` / 特征 `0x2A37`，**实时推送到菜单栏 + 面板**；无 SDK、不联网、不上云；macOS **无 ANT+**，走 BLE |
| 体积 | 单个自包含 `.app`；SMCKit 静态链接，无第三方 dylib |

---

## 🫀 手表心率（蓝牙 BLE）

MetriBar 用 macOS 自带的 **CoreBluetooth**，把运动手表实时广播的心率读进来，直接显示在菜单栏 `♥72` 与面板卡片上——**不需要任何厂商 SDK、不联网、不上云**。

**原理**：手表开启「心率广播」后，会作为 BLE **外设（Peripheral）** 广播标准 **Heart Rate Service `0x180D`**；MetriBar 作为 **中心（Central）** 扫描 → 连接 → 订阅特征 **`0x2A37`（Heart Rate Measurement）**，手表每约 1 秒推一次。解析 `flags` 兼容 8/16-bit 心率值与传感器接触位，并校验 20…260 过滤噪声。断线自动重连（记住上次设备 UUID，优先回连）。

**手表端（fenix 8）**：下拉快捷面板 / 活动中找到「**心率广播**」并打开（不同固件路径略有差异，一般为：长按 ⌂ → 手机连接 / 传感器 → 心率广播）。广播模式下手表专为「外部接收器」服务。

**Mac 端**：
1. 首次启动会弹出「**允许 MetriBar 使用蓝牙**」→ 点允许（`NSBluetoothAlwaysUsageDescription`）。
2. 设置 → 「心率 · 蓝牙」里可看到实时连接状态、当前 BPM，并可改**设备名过滤**（默认匹配 `fenix`，留空则接受任何广播心率服务的设备）。
3. 换一块手表 → 点「重新搜索手表」即可，无需重启。

> ⚠️ **注意事项 / 排查**
> - macOS **没有 ANT+ 无线**，只能走 BLE。若你的设备只发 ANT+，本 App 看不到（需 USB ANT+ 棒 + 额外驱动，超出范围）。
> - 手表必须处于「**心率广播**」状态；仅日常佩戴不主动广播时是搜不到的。
> - 部分手表在被**手机 App 连接**时会暂停对外广播（广播本就是给第三方接收器用的）；如连不上，可断开手机或重新开广播。
> - 没授权蓝牙 / 蓝牙未开 → 状态会显示「未授权 / 蓝牙未开启」，去 系统设置 › 隐私与安全 › 蓝牙 允许即可。
> - 需要重置授权：`tccutil reset Bluetooth com.qyx.MetriBar` 后重启 App。
> - 不用心率时，在设置里关掉「菜单栏显示心率」即**完全停止蓝牙扫描**，省电。

---

## 🖥 运行环境

- **macOS 13.0 Ventura 及以上**（`MACOSX_DEPLOYMENT_TARGET = 13.0`）
- Xcode 15+（开发验证环境为 Xcode 26/27 + Swift 6.x，工程使用 `SWIFT_VERSION = 5.0`）
- Apple Silicon 与 Intel 均支持（温度传感器 key 列表各自适配，见下文）

> ⚠️ **必须关闭 App Sandbox**：SMC（`AppleSMC` io_service）在沙箱内无法打开。
> 因此 MetriBar 只能以 **外部签名 + dmg 分发**，不能上架 Mac App Store。

---

## 🚀 快速开始

### 1. 打开工程

```bash
git clone https://github.com/QinyiXiong/MetriBar.git
cd MetriBar
open MetriBar.xcodeproj
```

### 2. 添加 SMCKit 依赖（若工程未自动解析）

工程已经写入 `XCRemoteSwiftPackageReference`（pin 到 `1.1.0`）。首次打开时若提示解析：

**Xcode → File → Add Package Dependencies…**

1. 右上角搜索/粘贴：`https://github.com/srimanachanta/SMCKit.git`
2. **Dependency Rule** 选 **Exact Version** → `1.1.0`
3. Add to Target：**MetriBar**，勾选 `SMCKit` 库

> 为什么用 `srimanachanta/SMCKit`？
> 原始的 `beltex/SMCKit` **没有提供 `Package.swift`**，无法被 SwiftPM 直接解析；
> 该 fork 在原始代码基础上补齐了 SwiftPM 清单并保持 **MIT** 许可，API 完全一致
> （`SMCKit.shared`、`read<V: SMCCodable>(_:)`、`FourCharCode`、`allKeys()`）。
> 离线/内网环境可把该仓库 clone 到 `Packages/SMCKit`，改用 **Add Local…**，代码无需改动。

命令行解析（可选）：

```bash
xcodebuild -resolvePackageDependencies -project MetriBar.xcodeproj -scheme MetriBar
```

解析成功后 `MetriBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
会锁定 `SMCKit 1.1.0`，并随仓库一起提交。

### 3. 直接运行

选择 **MetriBar** scheme → Run。应用 **不占 Dock**（`LSUIElement = YES`），启动后直接出现在菜单栏右上角。

命令行构建 + ad-hoc 签名（无开发者账号时）：

```bash
xcodebuild -project MetriBar.xcodeproj -scheme MetriBar -configuration Release \
  CODE_SIGN_IDENTITY="-"
open ~/Library/Developer/Xcode/DerivedData/**/Build/Products/Release/MetriBar.app
```

> 从 Xcode 停止运行即可退出；日常使用可点面板右下角 ⏻ 退出。

---

## ⚙️ Xcode 配置清单（务必核对）

> 完整逐条核对表 + 验收清单 + 踩坑记录见 **[`docs/Xcode配置清单.md`](docs/Xcode配置清单.md)**。

工程内已落库以下设置，若从空模板重建请照抄：

**Target → General**
- Identifier：`com.qyx.MetriBar`
- Minimum Deployment：**13.0**
- 无 App Groups、无 Push、无 Widget Extension

**Target → Signing & Capabilities**
- `App Sandbox`：**删除该 Capability**（对应 `ENABLE_APP_SANDBOX = NO`）
- `Entitlements` 文件：`MetriBar.entitlements`，内容仅
  `com.apple.security.app-sandbox = <false/>`
- Release：`ENABLE_HARDENED_RUNTIME = YES`（公证必需）

**Target → Info**
- `Application is agent (UIElement)`：**YES**（`INFOPLIST_KEY_LSUIElement = YES`）
- 不显示 Dock 图标，无主窗口

**Build Settings**
- `GENERATE_INFOPLIST_FILE = YES`
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`（图标资源见 `Assets.xcassets/AppIcon.appiconset`）
- `SWIFT_VERSION = 5.0`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`，UI 层显式 `@MainActor`
  （采集器必须在自有队列执行，不能被默认 MainActor 隔离绑死）

---

## 🗂 代码结构

```
MetriBar/
├── MetriBarApp.swift              # @main：MenuBarExtra(.window) + 设置入口
├── MetriBar.entitlements        # app-sandbox = false
├── Model/                       # 采集层：与 UI 完全解耦，均不接触主线程
│   ├── MetricsSnapshot.swift    # 不可变数据模型（全部 Sendable 值类型）
│   ├── NetworkCollector.swift   # getifaddrs + if_data，网卡白名单，Δ→bytes/s
│   ├── MemoryCollector.swift    # host_statistics64(HOST_VM_INFO64)
│   ├── CPULoadCollector.swift   # host_statistics(HOST_CPU_LOAD_INFO) ticks 差值
│   ├── DiskCollector.swift      # FileManager.mountedVolumeURLs + URLResourceValues
│   ├── SMCSensorReader.swift    # actor：SMCKit 封装，温度 key 解析 + 风扇枚举
│   ├── GPUCollector.swift       # IORegistry PerformanceStatistics：GPU / 渲染 / 光栅占用（EMA）
│   └── MetricsEngine.swift      # DispatchSourceTimer 调度 + @MainActor MetricsStore
├── Views/
│   ├── MenuBarLabelView.swift   # 菜单栏文本（仅数值；丰富→位图，紧凑→Text）
│   ├── PopoverView.swift        # 弹出面板
│   └── SettingsView.swift       # 设置：刷新频率 / 自启 / 显示项 / 单位
└── Support/
    ├── AppSettings.swift        # @AppStorage + SMAppService 登录项（含自愈）
    ├── MenuBarBadge.swift       # Core Text 徽章：固定槽位、@2x、字体平滑、胶囊底
    ├── Formatters.swift         # 速率 / 容量 / 温度 / 百分比格式化
    ├── UIComponents.swift       # PanelSection / MetricRow / SlimGauge / SettingsWindow
    └── Diagnostics.swift        # os_log 入口（subsystem com.qyx.MetriBar）
```

### 采集链路（不卡主线程的关键）

```
DispatchSourceTimer (串行队列, qos .utility)
   ├─ NetworkCollector.sample()      同步、微秒级：getifaddrs
   ├─ MemoryCollector.sample()       同步：host_statistics64
   ├─ CPULoadCollector.sample()      同步：host_statistics
   ├─ DiskCollector.sample()         同步：URLResourceValues
   └─ Task { await SMCSensorReader } 异步：SMC IOKit 往返
          ↓
   MetricsSnapshot（一次性整体投递）
          ↓
   @MainActor MetricsStore.publish()  ← 主线程只做一次赋值，触发 SwiftUI 刷新
```

三道防线：
1. **所有系统调用都在自有串行队列**，主线程只接收不可变快照；
2. `isSampling` 闸门：SMC 偶发阻塞时**丢弃本次 tick**，任务不堆积；
3. `leeway: 120ms` + `exactVersion` 依赖，兼顾功耗与稳定。

---

## 🌡 SMC 传感器说明

`SMCSensorReader` 先在候选 key 中挑选**可读且合理（5–125 ℃）**的传感器，取最大值作为 CPU 温度；找不到时扫描 `Tp*` / `TC*` / `Tc*` 前缀兜底，并枚举 `FNum` → `F{i}Ac / F{i}Mn / F{i}Mx` 获取风扇。

| 平台 | 常见温度 key |
| --- | --- |
| Apple Silicon (M1–M5) | `Tp0C` `Tp0R` `Tp04` `Tp08` `Tp1E` `Tc0C` … |
| Intel | `TC0P` `TC0D` `TC0E` `TC0F` `TCAD` `TCFH` `TCPP` … |

解码类型：`flt `（32 位小端 float）、`sp78`（有符号 8.8）、`fpe6`（无符号 2.6）、`ui8 `、`ui16`。
面板里会显示当前采用的传感器 key，便于确认读数来源。

> 读不到温度时菜单栏与面板显示 `--`，不会崩、也不会退化成假数据。
> 虚拟机 / 部分台式主板无 SMC 温度或风扇，属于正常现象。

### 网卡白名单

只统计真实物理出口：`en*`、`pdp_ip*`。
显式排除：`lo0`（回环，会导致流量虚高）、`utun*`/`ipsec*`（VPN，流量在物理口已计一次）、`awdl0`/`llw0`/`nan0`/`ap1`（Handoff/热点底层）、`bridge0`（与成员口重复）、`gif0`/`stf0`、`anpi*`、`vmnet*`（虚拟化）。
计数器为 `UInt32`，采集中做 **回绕补偿**；重启/异常间隔（≤50ms 或 ≥30s）自动重建基线，睡眠唤醒后同样重置。

> ⚠️ 字节计数器必须从 `ifaddrs.ifa_data` 读取，**不能**从 `ifa_addr` 读。
> AF_LINK 的 `ifa_addr` 是 `sockaddr_dl`，按 `if_data` 的偏移去读它，
> 会在 `ifi_baudrate` 上撞到一个恒定值（实测 `748800000`），
> 现象是「下载速率永远 0」，而上传恰好落在会变的数字上，非常具有迷惑性。

---

## 🔬 运行验证

工程内置 os_log（subsystem `com.qyx.MetriBar`）。默认只记录启停与传感器解析；
排查时打开逐 tick 明细：

```bash
defaults write com.qyx.MetriBar MetriBarVerboseLogging -bool YES   # 开启
log stream --predicate 'subsystem == "com.qyx.MetriBar"' --level info
defaults delete com.qyx.MetriBar MetriBarVerboseLogging             # 关闭
```

### 🎨 排版自检图（没有屏幕录制权限也能看到界面）

终端没有「屏幕录制」权限时 `screencapture` 拍不到菜单栏。项目内置离屏渲染自检：
启动后把徽章（深 / 浅）与面板渲染成 PNG 写到临时目录，日志打印路径，直接打开就能看到真实排版与配色。

```bash
defaults write com.qyx.MetriBar MetriBarDebugSnap -bool YES
open MetriBar.app
log show --last 30s --predicate 'subsystem == "com.qyx.MetriBar" AND eventMessage CONTAINS "badge"'
defaults delete com.qyx.MetriBar MetriBarDebugSnap        # 用完关掉
```

排版样式在 **设置 › 菜单栏显示 › 排版样式** 里切换，下方有实时预览
（预览用的就是 `MenuBarBadge` 位图，与顶部状态栏同一套逻辑，所见即所得）：

| 样式 | 效果 |
| --- | --- |
| 丰富（默认） | `⬇ 1.6M │ ⬆ 28K │ 🌡 66°`，图标随负载/温度变色，温度计图标按热度换低/中/高 |
| 紧凑 | `↓1.6M ↑28K 66°`，无图标，宽度最省 |

以下是 **Apple Silicon（M5 Max / macOS 27 beta / Xcode 27）实测输出**，
下载 npm 包时的采样：

```
[lifecycle] 采集启动：每 2.0 秒
[smc]       传感器解析完成：温度键 [Tp0C Tp0R Tp04 Tp08 Tp1E …] 风扇 2 个
[metrics]   en0 in 150681600->153684992 Δ3003392 | out 2418020352->2418158592 Δ138240 | elapsed=1.999
[metrics]   ↓1.5M ↑69K CPU 13% GPU 47% 温度 60°[Tp0C] 风扇 风扇 1 7247 RPM, 风扇 2 7804 RPM 内存 72% 磁盘剩余 676.96 GB 基线就绪=true
[lifecycle] 状态栏按钮：image 177x18pt isTemplate=false 像素 354x36
[lifecycle] 徽章宽度自检：稳定 177x18pt（样本数 3）
```

GPU 读数走 IOKit，与「活动监视器 › GPU」不同源（后者是聚合私有接口），但趋势一致：

```bash
ioreg -c AGXAccelerator -l | grep -i PerformanceStatistics   # 看设备原始百分比
```

内存口径与「活动监视器」一致（128 GB 机型实测已用 71%–72%）。

---

## 📦 分发与安装

一条命令产出安装包（**通用二进制 Intel + Apple Silicon、自包含无第三方 dylib**，约 680 KB）：

```bash
./Scripts/build_dmg.sh                    # ad-hoc 签名 → dist/MetriBar-1.0.dmg
./Scripts/build_dmg.sh --identity "Developer ID Application: 你的名字 (TEAMID)" \
                       --notarize you@example.com TEAMID   # 正式分发（需付费开发者账号）
```

dmg 里已含 `MetriBar.app` + `/Applications` 快捷方式 + `README`。

### 情况 A：发给别人（没有开发者账号，免费）

ad-hoc / 未公证的 App 被下载后会被 Gatekeeper 拦下，提示
「已损坏」或「无法打开，因为它来自身份不明的开发者」——**这不是 App 坏了**，
只是没被 Apple 公证。让对方在终端执行一次放行即可（永久生效）：

```bash
# 打开 dmg，把 MetriBar.app 拖进「应用程序」文件夹后，执行：
xattr -dr com.apple.quarantine /Applications/MetriBar.app
open /Applications/MetriBar.app
```

之后就像普通 App 一样正常打开、开机自启。缺点：对方要动一次终端。

### 情况 B：正式分发（有 Apple Developer ID，$99/年）

签名 + 公证后对方双击即可打开，无需终端：

```bash
./Scripts/build_dmg.sh --identity "Developer ID Application: 你的名字 (TEAMID)" \
                       --notarize you@example.com TEAMID
```

脚本会用 `notarytool` 提交公证并 `stapler staple` 回粘。首次需存一次凭据：
`xcrun notarytool store-credentials MetriBar-Notary --apple-id you@example.com --team-id TEAMID`。
（因为要读 SMC，本项目 `com.apple.security.app-sandbox = false`，**只能外部分发，不能上架 Mac App Store**。）

### 情况 C：装到自己的电脑

- **已有本仓库**：`xcodebuild` 直接构建出的 App 就在本机，通常不会被拦（本机构建 = 本地可信）。拖进 `/Applications` 即可。
- **从 dmg**：双击挂载 → 把 `MetriBar.app` 拖到 `Applications` 快捷方式上 → 打开。
- **开机自启**：打开 App → 点右下角齿轮 ⚙️ 进设置 → 打开「登录时自动启动」（走 `SMAppService`，无需 plist）。App 启动时会自动把登录项重指向 `/Applications`。

> 图标在菜单栏**只出现一次**是正常的（`LSUIElement`，不占 Dock）。若之前是从 DerivedData 跑的旧实例，
> 拖到 /Applications 后记得先退出旧的：`pkill -f MetriBar`，再从 /Applications 打开。

---

## 🛠 常见问题

| 现象 | 处理 |
| --- | --- |
| **点齿轮打不开设置** | 已修复：`LSUIElement` Agent 应用里 `showSettingsWindow:` / `openSettings` 只"响应"不建窗。现在设置由 `SettingsWindow.open()` 托管的 `NSWindow + NSHostingController` 承载，齿轮与 ⌘, 同走此路径 |
| **菜单栏只显示下载速度** | 已修复：`MenuBarExtra` 的 label 用 `HStack` 时状态项宽度可能按首帧固定，变长部分被裁掉。现改为单个拼接 label；启动日志可确认开关状态 |
| GPU 显示 `--` | 虚拟机 / 无 Metal 设备时 `IORegistry` 里没有 accelerator 节点，属正常降级 |
| 温度显示 `--` | 该机型 SMC 无对应 key，或仍处沙箱。核对 `ENABLE_APP_SANDBOX = NO` 并重新构建；可用 `ioreg -l \| grep -i SMC` 自查 |
| 风扇区显示「未检测到风扇」 | MacBook Air / Mac mini 等被动散热机型正常 |
| 网速一直为 `0` | 首次采样只建基线，2 秒后才有值；若仍为 0，检查是否只有 VPN 口在传输（`utun*` 被有意排除） |
| 开机自启无效 | 换过 `.app` 路径后需重新开关一次（现已自愈处理）；查看「系统设置 › 通用 › 登录项」是否被拒绝 |
| 菜单栏文字过长挤掉其他图标 | 设置里关掉「上传速率」或「CPU 占用率」 |
| 控制台刷屏 `com.apple.linkd.autoShortcut` / `4097` | App Intents 为未公证 App 注册时的系统噪音，会自行退避（`Will NOT re-try`），对监控无影响。只有 Developer ID + 公证才能彻底消除 |

---

## 📄 许可

- MetriBar：MIT
- [SMCKit](https://github.com/srimanachanta/SMCKit)：MIT（源自 `beltex/SMCKit`，补齐 SwiftPM 清单）
