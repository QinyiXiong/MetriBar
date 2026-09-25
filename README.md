# MetriBar 🌡️

一个 **macOS 菜单栏实时监视工具**：在菜单栏直接看到 **下载 / 上传速率 + CPU 温度**，点开面板查看网络、CPU、风扇、内存与磁盘。

纯 **SwiftUI `MenuBarExtra(.window)`** 实现 —— 不写一行 AppKit `NSStatusItem`，没有 WidgetKit / 桌面小组件，没有 CoreData / CloudKit。

> 菜单栏效果：`↓12.4M ↑980K 72°`（仅数值与单位，不显示应用名称）

---

## 🖼 界面预览

离屏渲染自检图（`MetriBarDebugSnap`，真实数据）：

菜单栏实际提交给状态栏的位图（`isTemplate = false`，非模板渲染才能保住颜色）：

![菜单栏位图](docs/预览/menubar-badge.png)

离屏渲染的完整视图：

![菜单栏 · 深色](docs/预览/menubar-dark.png)
![菜单栏 · 浅色](docs/预览/menubar-light.png)

![弹出面板 · 深色](docs/预览/panel-dark.png)

---

## 🎯 菜单栏为什么是「自绘位图」

`MenuBarExtra` 的 label 会被 macOS 状态栏按 **template（模板图）** 重绘，实测结果：

| 写法 | 结果 |
| --- | --- |
| `Text` + `foregroundColor` | 颜色全被抹平成单色（选中时反色成白/黑） |
| `Text("\(Image(systemName: …))")` | **SF Symbol 直接不显示**，只剩字面字符：`2.3K│3.5K│54°` |
| `Image(nsImage:)` + `isTemplate = false` + `.renderingMode(.original)` | ✅ 图标与配色原样保留 |

所以「丰富」排版的做法是：用 `NSHostingView` 把 SwiftUI 排版离屏渲染成
一张 ~80×20pt 的位图（`MenuBarBadge.swift`），标记 `isTemplate = false` 后交给
`MenuBarExtra`；带内容签名缓存，数值没变就不重画。「紧凑」排版仍然走纯 `Text`，
作为极端环境下的兜底。

---

## ✨ 特性

| 项目 | 说明 |
| --- | --- |
| 菜单栏 | 实时 **下载 ↓ / 上传 ↑ / CPU 温度**，可叠加 CPU、GPU 占用率；**两种排版：丰富（自绘非模板位图，图标 + 配色 + 分级字号）/ 紧凑（纯文本）**；等宽数字不抖动 |
| 弹出面板 | 上下行速率 + 比例条、CPU 温度（含传感器 key）、**CPU 占用 + GPU 占用（渲染/光栅细分）**、风扇转速/区间、内存（App / Wired / Compressed）、磁盘可用空间 |
| 后台采集 | `DispatchSourceTimer` + 独立串行队列，1–10 秒可调（默认 2 秒），**主线程零系统调用** |
| 开机自启 | `SMAppService.mainApp`（macOS 13+），设置页一键开关并显示真实注册状态 |
| 原生观感 | `ultraThinMaterial` 背景、圆角卡片、深浅色自适应、系统控件尺寸与字号 |
| 硬件读取 | [SMCKit](https://github.com/srimanachanta/SMCKit)（MIT）访问 AppleSMC：CPU 温度、风扇转速 |
| GPU 占用 | IOKit `IORegistry` → GPU accelerator（Apple Silicon 为 `AGXAccelerator…`）的 `PerformanceStatistics`，指数平滑防跳变 |
| 体积 | 单个 `.app`，无嵌入框架副本以外的额外依赖，静态链接 SMCKit |

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
git clone https://github.com/qyx/MetriBar.git   # 替换为你的仓库地址
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
- `SWIFT_VERSION = 5.0`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`，UI 层显式 `@MainActor`
  （采集器必须在自有队列执行，不能被默认 MainActor 隔离绑死）

---

## 🗂 代码结构

```
MetriBar/
├── MetriBarApp.swift              # @main：MenuBarExtra(.window) + Settings 场景
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
│   ├── MenuBarLabelView.swift   # 菜单栏文本（仅数值）
│   ├── PopoverView.swift        # 弹出面板
│   └── SettingsView.swift       # 设置：刷新频率 / 自启 / 显示项 / 单位
└── Support/
    ├── AppSettings.swift        # @AppStorage + SMAppService 登录项
    ├── Formatters.swift         # 速率 / 容量 / 温度 / 百分比格式化
    ├── UIComponents.swift       # PanelSection / MetricRow / SlimGauge
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
启动后用 `NSHostingView` 把菜单栏文案（深 / 浅两版）与面板渲染成 PNG 写到临时目录，
日志打印路径，直接打开就能看到真实排版与配色。

```bash
defaults write com.qyx.MetriBar MetriBarDebugSnap -bool YES
open MetriBar.app
log show --last 30s --predicate 'subsystem == "com.qyx.MetriBar" AND eventMessage CONTAINS "自检图"'
defaults delete com.qyx.MetriBar MetriBarDebugSnap        # 用完关掉
```

菜单栏排版在 **设置 › 菜单栏显示 › 排版样式** 里切换，下方有实时预览
（预览用的就是 `MenuBarLabelView.compose(...)`，与顶部状态栏同一套拼装逻辑，所见即所得）：

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
```

GPU 读数走 IOKit，与「活动监视器 › GPU」不同源（后者是聚合私有接口），但趋势一致：

```bash
ioreg -c AGXAccelerator -l | grep -i PerformanceStatistics   # 看设备原始百分比
```

内存口径与「活动监视器」一致（128 GB 机型实测已用 71%–72%）。

---

## 📦 打包 dmg

```bash
./Scripts/build_dmg.sh              # 输出 dist/MetriBar-1.0.dmg
./Scripts/build_dmg.sh --identity "Developer ID Application: 你的名字 (TEAMID)"
```

手动流程：

```bash
# 1. archive
xcodebuild -project MetriBar.xcodeproj -scheme MetriBar \
  -configuration Release -archivePath build/MetriBar.xcarchive archive

# 2. 导出 / 复制 app
cp -R build/MetriBar.xcarchive/Products/Applications/MetriBar.app dist/

# 3. 签名（必须带 hardened runtime；关闭沙箱已在 entitlements 中声明）
codesign --force --deep --options runtime \
  --entitlements MetriBar.entitlements \
  --sign "Developer ID Application: 你的名字 (TEAMID)" dist/MetriBar.app

# 4. 打 dmg
hdiutil create -volname MetriBar -srcfolder dist -ov -format UDZO MetriBar-1.0.dmg

# 5. 签名 + 公证 dmg
codesign --sign "Developer ID Application: 你的名字 (TEAMID)" MetriBar-1.0.dmg
xcrun notarytool submit MetriBar-1.0.dmg --apple-id you@example.com \
  --team-id TEAMID --password <app-password> --wait
xcrun stapler staple MetriBar-1.0.dmg
```

**没有开发者账号？** 本机自用直接 `xcodebuild` + ad-hoc 签名即可运行；
分发给他人时对方需 `xattr -dr com.apple.quarantine /Applications/MetriBar.app` 放行。

---

## 🛠 常见问题

| 现象 | 处理 |
| --- | --- |
| **点齿轮打不开设置** | 已修复：`LSUIElement` Agent 应用里 `showSettingsWindow:` / `openSettings` 只"响应"不建窗。现在设置由 `SettingsWindow.open()` 托管的 `NSWindow + NSHostingController` 承载，齿轮与 ⌘, 同走此路径；日志会打 `设置窗口自检：已打开｜可见窗口 […]` |
| **菜单栏只显示下载速度** | 已修复：`MenuBarExtra` 的 label 用 `HStack` 时状态项宽度可能按首帧固定，变长部分被裁掉。现改为拼接的**单个 `Text`**；启动日志 `菜单栏字段 [↓下载 ↑上传 温度]` 可确认开关状态 |
| GPU 显示 `--` | 虚拟机 / 无 Metal 设备时 `IORegistry` 里没有 accelerator 节点，属正常降级 |
| 温度显示 `--` | 该机型 SMC 无对应 key，或仍处沙箱。核对 `ENABLE_APP_SANDBOX = NO` 并重新构建；可用 `ioreg -l | grep -i SMC` 自查 |
| 风扇区显示「未检测到风扇」 | MacBook Air / Mac mini 等被动散热机型正常 |
| 网速一直为 `0` | 首次采样只建基线，2 秒后才有值；若仍为 0，检查是否只有 VPN 口在传输（`utun*` 被有意排除） |
| 开机自启无效 | 换过 `.app` 路径后需重新开关一次；查看「系统设置 › 通用 › 登录项」是否被拒绝 |
| 菜单栏文字过长挤掉其他图标 | 设置里关掉「上传速率」或「CPU 占用率」 |

---

## 📄 许可

- MetriBar：MIT
- [SMCKit](https://github.com/srimanachanta/SMCKit)：MIT（源自 `beltex/SMCKit`，补齐 SwiftPM 清单）
