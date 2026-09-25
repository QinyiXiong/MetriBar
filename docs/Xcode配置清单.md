# MetriBar — Xcode 配置清单

> 本文是「从零手工复原工程」的核对表。仓库里的 `MetriBar.xcodeproj` 已按此配置写好，
> 接手时只要逐条打勾即可；从空模板新建时照抄。
> 最后一列是**本机（macOS 27 beta / Xcode 27 / M5 Max）实测结果**。

## 1. Target → General

| 项 | 值 | 说明 |
| --- | --- | --- |
| Display Name | `MetriBar` | |
| Identifier | **`com.qyx.MetriBar`** | 与 `SMAppService` 登录项、`defaults write` 域名一致 |
| Version / Build | `1.0` / `1` | |
| Minimum Deployment | **macOS 13.0 Ventura** | `MenuBarExtra`、`SMAppService` 均为 macOS 13+ API |
| Destination | Mac（My Mac） | 不用 Catalyst / iOS |

## 2. Target → Signing & Capabilities

| 项 | 值 |
| --- | --- |
| **App Sandbox** | ❌ **必须删除该 Capability**（`ENABLE_APP_SANDBOX = NO`） |
| Entitlements File | `MetriBar.entitlements`（内容仅 `com.apple.security.app-sandbox = false`） |
| App Groups / Push / Keychain Sharing / Hardware Acceleration | 全部不使用 |
| Provisioning Profile | Automatic（本机可用 `-` ad-hoc） |
| Release → `ENABLE_HARDENED_RUNTIME` | ✅ YES（公证必需；ad-hoc 调试可暂时关） |

> **为什么必须关沙箱**：CPU 温度与风扇转速来自 `AppleSMC` 的 IOKit 用户客户端，
> 沙箱内 `IOServiceOpen` 直接失败 → 面板温度区永远是 `--`。
> 代价：不能上架 Mac App Store，只能 dmg / Developer ID 外部分发。

## 3. Target → Info（`INFOPLIST_KEY_*`）

| Key | 值 |
| --- | --- |
| `Application is agent (UIElement)` / `INFOPLIST_KEY_LSUIElement` | **YES**（不占 Dock、无主窗口） |
| `GENERATE_INFOPLIST_FILE` | YES |
| `CFBundleShortVersionString` / `CFBundleVersion` | `1.0` / `1` |

## 4. Target → Build Settings（关键项）

```
SWIFT_VERSION                      = 5.0
SWIFT_DEFAULT_ACTOR_ISOLATION    = nonisolated      ← 采集器要在自有队列跑
SWIFT_APPROACHABLE_CONCURRENCY   = NO               ← 与上一条配套
MACOSX_DEPLOYMENT_TARGET         = 13.0
ENABLE_APP_SANDBOX               = NO
CODE_SIGN_ENTITLEMENTS           = MetriBar.entitlements
ENABLE_HARDENED_RUNTIME          = YES (Release)
MTL_FAST_MATH / ENABLE_PREVIEWS  = 默认
```

- UI 层（`MetriBarApp`、`MetricsStore`、`AppSettings`、所有 View）显式标注 `@MainActor`；
- 采集层（`NetworkCollector` / `MemoryCollector` / `DiskCollector` / `CPULoadCollector` /
  `MetricsEngine`）保持 nonisolated，`SMCSensorReader` 是 `actor`。
- 若沿用模板默认的 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
  `MetricsEngine.queue.async { … }` 里的采集体会被判成 MainActor 隔离，直接编译不过。

## 5. Swift Package Manager

| 项 | 值 |
| --- | --- |
| 仓库 | `https://github.com/srimanachanta/SMCKit.git` |
| 规则 | **Exact Version `1.1.0`** |
| 产品 | `SMCKit`（已加入 target `MetriBar` 的 Frameworks） |
| 许可 | MIT |

命令行核对：

```bash
xcodebuild -resolvePackageDependencies -project MetriBar.xcodeproj -scheme MetriBar
```

- 原始仓库 `beltex/SMCKit` **没有 `Package.swift`**，SwiftPM 无法解析，故使用补齐清单的 fork。
- 离线/内网：把该仓库 clone 到 `Packages/SMCKit`，在 Xcode 里 **Add Package… → Add Local…**，
  源码零改动（`import SMCKit` 不变）。
- 解析成功后 `project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 会入库锁定版本。

## 6. 源码目录（同步文件夹）

`MetriBar/MetriBar/` 是 `PBXFileSystemSynchronizedRootGroup`：
**新建的 `.swift` 文件放进目录就自动参与编译**，不需要手工 Add Files。

```
MetriBarApp.swift              # @main：MenuBarExtra(.window) + Settings
Model/       MetricsSnapshot · NetworkCollector · MemoryCollector · DiskCollector
             CPULoadCollector · SMCSensorReader · MetricsEngine
Views/       MenuBarLabelView · PopoverView · SettingsView
Support/     AppSettings · Formatters · UIComponents · Diagnostics
```

## 7. 验收清单（逐条自查）

| # | 检查 | 期望 |
| --- | --- | --- |
| 1 | 启动后不出现 Dock 图标 | ✅ LSUIElement |
| 2 | 菜单栏只显示数值，无 App 名 | `↓1.5M ↑69K 59°`（可在设置里增减字段） |
| 3 | 点开面板：网络 / 温度 / 风扇 / 内存 / 磁盘齐全 | `ultraThinMaterial`，深浅色自适应 |
| 4 | 温度旁显示实际传感器 key | `Tp0C`（Apple Silicon）/ `TC0P`（Intel） |
| 5 | 改刷新间隔立即生效 | 设置页 → 采集，日志出现「采集重建：每 N 秒」 |
| 6 | 开机自启开关有效 | 系统设置 › 通用 › 登录项 出现 MetriBar |
| 7 | 主线程不卡 | 采集全在 `com.qyx.MetriBar.collector` 串行队列 |
| 8 | 无开发者账号也能跑 | `xcodebuild … CODE_SIGN_IDENTITY="-"` + ad-hoc |

## 8. 实测留痕（Debug 用）

```bash
# 打开逐 tick 明细日志
defaults write com.qyx.MetriBar MetriBarVerboseLogging -bool YES
log stream --predicate 'subsystem == "com.qyx.MetriBar"' --level info

# 关掉
defaults delete com.qyx.MetriBar MetriBarVerboseLogging
```

本机实测输出（2 秒间隔、下载 npm 包时）：

```
[lifecycle] 采集启动：每 2.0 秒
[smc] 传感器解析完成：温度键 [Tp0C Tp0R Tp04 Tp08 Tp1E …] 风扇 2 个
[metrics] en0 in 150681600->153684992 Δ3003392 | out 2418020352->2418158592 Δ138240 | elapsed=1.999
[metrics] ↓1.5M ↑69K CPU 13% 温度 60°[Tp0C] 风扇 风扇 1 7247 RPM, 风扇 2 7804 RPM 内存 72% 磁盘剩余 676.96 GB 基线就绪=true
```

## 9. 踩过的坑（务必别改回去）

1. **网卡计数器必须从 `ifa_data` 取，不能从 `ifa_addr` 取。**
   AF_LINK 的 `ifa_addr` 是 `sockaddr_dl`，照着 `if_data` 去读它的偏移，
   会在 `ifi_baudrate` 上读到 **恒定不变的 748800000**，表现就是「下载速率永远 0 / 不动」，
   而上传字段恰好落在会变的数字上，极具迷惑性。
2. **`if_data` 的字节计数器是 `UInt32`（约 4 GiB 回绕一次）**，求差必须做回绕补偿，
   并对异常间隔（≤50 ms、≥30 s）重建基线；睡眠唤醒后同样要重置。
3. **内存不能把 `inactive` 算进 App Memory**：那绝大部分是可回收文件缓存，
   会把占用率顶到 100%。活动监视器口径是 `internal_page_count − purgeable_count`。
4. **`SMCSensorReader.sample()` 要先 `prepareIfNeeded()` 再判断 `isAvailable`**，
   顺序反了硬件区永远显示 `--`。
5. **`SMCKit.shared` 内部是 `try!`**：触碰它之前先用 `IOServiceGetMatchingService("AppleSMC")`
   确认服务存在，否则在无 SMC 的虚拟机里直接崩溃。
6. **`ProcessInfo.thermalPressure` 在新 SDK 已不存在**，不要用它做降级判断。
7. `MetricsEngine` 的 `store` 用 **二阶段 `bind(store:)`** 绑定，
   避免在 `MetricsStore.init` 的表达式里把 `self` 逃逸出去。
8. Timer 用 `DispatchSourceTimer` + `leeway:120ms`，并且**只保留一个 source**，
   改间隔时先 `cancel()` 再重建；`isSampling` 闸门防止 SMC 偶发阻塞导致任务堆积。
