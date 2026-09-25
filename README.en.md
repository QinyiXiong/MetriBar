# MetriBar 🌡️

<div align="center">

[简体中文](README.md) · **English**

</div>

**A macOS menu-bar system monitor.** See **download / upload speed + CPU temperature + heart rate ♥** right in the menu bar; click for a panel with network, CPU, GPU, fans, memory and disk.

Built purely with **SwiftUI `MenuBarExtra(.window)`** — not a single line of AppKit `NSStatusItem`, no WidgetKit / desktop widgets, no CoreData / CloudKit.

> Menu-bar readout: `↓12.4M ↑980K 72° ♥72` (values + units only, no app name)

---

## Preview

Real output captured offscreen via `MetriBarDebugSnap`:

The exact bitmap handed to the status bar — locked at **177×18 pt @2x**, rendered non-template:

![Menu bar badge](docs/预览/menubar-badge.png)
![Light menu bar](docs/预览/menubar-badge-light.png)

![Popover · dark](docs/预览/panel-dark.png)

App icon (`AppIcon.icns`, drawn for 1024→16 px):

![App icon](docs/预览/app-icon.png)

---

## Why a self-drawn bitmap

macOS re-renders the `MenuBarExtra` label as a **template image**. Verified behaviour:

| Approach | Result |
| --- | --- |
| `Text` + `foregroundColor` | All colours flattened to monochrome (inverted white/black when selected) |
| `Text("\(Image(systemName: …))")` | **SF Symbols don't render at all** — only literal glyphs survive: `2.3K│3.5K│54°` |
| `Image(nsImage:)` + `isTemplate = false` + `.renderingMode(.original)` | ✅ Icons and colours preserved exactly |

So the "rich" style draws everything with **Core Text / `NSAttributedString`** into an `NSBitmapImageRep` created at the display's real `backingScaleFactor`, then marks `isTemplate = false` and hands it to `MenuBarExtra` (`MenuBarBadge.swift`). **Fixed icon / value / unit slots** keep the badge a constant size (177×18 pt) so it never jitters as numbers change, and font smoothing keeps text crisp. Content-signature caching skips redraws when nothing changed. The "compact" style falls back to plain `Text`.

---

## Features

| Area | Details |
| --- | --- |
| Menu bar | Live **download ↓ / upload ↑ / CPU temp**, optional CPU & GPU usage; **two layouts — Rich (self-drawn non-template bitmap: icons + colours + graded font sizes) / Compact (plain text)**; monospaced digits, no jitter |
| Popover panel | Up/down speed + ratio bar, CPU temperature (with sensor key), **CPU + GPU usage (renderer / tiler breakdown)**, fan speed / range, memory (App / Wired / Compressed), free disk space |
| Background sampling | `DispatchSourceTimer` on a private serial queue, 1–10 s adjustable (default 2 s), **zero syscalls on the main thread** |
| Login item | `SMAppService.mainApp` (macOS 13+); one toggle in Settings that also shows the real registration state, with **self-heal** to re-point at `/Applications` |
| Native feel | `ultraThinMaterial` background, rounded cards, light/dark adaptive, system control metrics & font sizes |
| Hardware reads | [SMCKit](https://github.com/srimanachanta/SMCKit) (MIT) for AppleSMC: CPU temperature, fan RPM |
| GPU usage | IOKit `IORegistry` → GPU accelerator (`AGXAccelerator…` on Apple Silicon) `PerformanceStatistics`, EMA-smoothed to stop flicker |
| Heart rate ♥ | CoreBluetooth **BLE** links to a watch that broadcasts heart rate (Garmin fenix 8, etc.), subscribing the standard Heart Rate service `0x180D` / characteristic `0x2A37`, **pushed live to the menu bar + panel**; no SDK, no network, no cloud; macOS has **no ANT+**, uses BLE |
| Footprint | Single self-contained `.app`; SMCKit statically linked, no third-party dylibs |

---

## Heart rate (Bluetooth LE)

MetriBar uses macOS's built-in **CoreBluetooth** to read the heart rate your sports watch broadcasts and show it in the menu bar (`♥72`) and in a panel card — **no vendor SDK, no network, no cloud**.

**How it works**: when the watch turns on "Broadcast Heart Rate" it advertises the standard **Heart Rate Service `0x180D`** as a BLE **peripheral**; MetriBar acts as the **central** — scan → connect → subscribe to characteristic **`0x2A37` (Heart Rate Measurement)**, and the watch pushes a reading roughly every second. It parses `flags` for 8/16-bit heart-rate format and the sensor-contact bit, filtering readings to a sane 20…260 range. It auto-reconnects (remembering the last device UUID).

**On the watch (fenix 8)**: open "Heart Rate Broadcast" from the controls / controls wheel or within an activity (path varies by firmware — typically long-press ⌂ → Sensors / Phone Connect → Broadcast Heart Rate). Broadcast mode is designed to serve external receivers.

**On the Mac**:
1. On first launch macOS prompts "**Allow MetriBar to use Bluetooth**" → Allow (`NSBluetoothAlwaysUsageDescription`).
2. Settings → "Heart rate · Bluetooth" shows live connection state and current BPM, plus a **name filter** (defaults to matching `fenix`; leave blank to accept any device broadcasting the heart-rate service).
3. Swapping watches → tap "Rescan", no restart needed.

> ⚠️ **Notes / troubleshooting**
> - macOS has **no ANT+ radio**, so this is BLE-only. A device that broadcasts ANT+ only is not visible here (that would need a USB ANT+ dongle + drivers, out of scope).
> - The watch must actually be in "**Broadcast Heart Rate**" mode — normal wear doesn't broadcast.
> - Some watches pause external broadcasting while connected to their phone app (broadcast is meant for third-party receivers); disconnect the phone or restart broadcasting if it won't connect.
> - Bluetooth off / not authorized → the state shows "Off / Not authorized"; enable it in System Settings › Privacy & Security › Bluetooth.
> - Reset the grant: `tccutil reset Bluetooth com.qyx.MetriBar` then relaunch.
> - Not using heart rate? Turn off "Show heart rate" in Settings to **stop BLE scanning entirely** and save battery.

---

## Requirements

- **macOS 13.0 Ventura or later** (`MACOSX_DEPLOYMENT_TARGET = 13.0`)
- Xcode 15+ (validated on Xcode 26/27 + Swift 6.x; project uses `SWIFT_VERSION = 5.0`)
- Works on both Apple Silicon and Intel (temperature sensor key lists adapted per platform, see below)

> ⚠️ **App Sandbox must be OFF**: the SMC (`AppleSMC` io_service) cannot be opened inside the sandbox.
> Therefore MetriBar ships via **external signing + dmg only** — it cannot go on the Mac App Store.

---

## Quick start

### 1. Open the project

```bash
git clone https://github.com/QinyiXiong/MetriBar.git
cd MetriBar
open MetriBar.xcodeproj
```

### 2. Add the SMCKit dependency (if Xcode doesn't resolve automatically)

The project already references `XCRemoteSwiftPackageReference` pinned to `1.1.0`. If Xcode asks to resolve on first open:

**Xcode → File → Add Package Dependencies…**

1. Paste `https://github.com/srimanachanta/SMCKit.git`
2. **Dependency Rule** → **Exact Version** → `1.1.0`
3. Add to Target: **MetriBar**, tick the `SMCKit` library

> Why `srimanachanta/SMCKit`? The original `beltex/SMCKit` ships **no `Package.swift`**, so SwiftPM can't resolve it directly. This fork adds the SwiftPM manifest on top of the original code, keeps the **MIT** licence, and exposes an identical API (`SMCKit.shared`, `read<V: SMCCodable>(_:)`, `FourCharCode`, `allKeys()`). Offline / intranet: clone that repo into `Packages/SMCKit` and use **Add Local…** — no code changes needed.

Resolve from the command line (optional):

```bash
xcodebuild -resolvePackageDependencies -project MetriBar.xcodeproj -scheme MetriBar
```

On success, `MetriBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` locks `SMCKit 1.1.0` and is committed with the repo.

### 3. Run

Select the **MetriBar** scheme → Run. The app has **no Dock icon** (`LSUIElement = YES`) and appears in the top-right menu bar immediately.

Command-line build + ad-hoc sign (no developer account):

```bash
xcodebuild -project MetriBar.xcodeproj -scheme MetriBar -configuration Release \
  CODE_SIGN_IDENTITY="-"
open ~/Library/Developer/Xcode/DerivedData/**/Build/Products/Release/MetriBar.app
```

> Stop it from Xcode to quit, or tap ⏻ at the bottom-right of the panel for day-to-day use.

---

## Xcode configuration checklist

> Full item-by-item table + acceptance checks + pitfalls live in **[`docs/Xcode配置清单.md`](docs/Xcode配置清单.md)** (Chinese).

These settings are committed — copy them verbatim if you rebuild from an empty template:

**Target → General**
- Identifier: `com.qyx.MetriBar`
- Minimum Deployment: **13.0**
- No App Groups, no Push, no Widget Extension

**Target → Signing & Capabilities**
- `App Sandbox`: **remove this Capability** (`ENABLE_APP_SANDBOX = NO`)
- Entitlements file: `MetriBar.entitlements`, contents only `com.apple.security.app-sandbox = <false/>`
- Release: `ENABLE_HARDENED_RUNTIME = YES` (required for notarization)

**Target → Info**
- `Application is agent (UIElement)`: **YES** (`INFOPLIST_KEY_LSUIElement = YES`)
- No Dock icon, no main window

**Build Settings**
- `GENERATE_INFOPLIST_FILE = YES`
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
- `SWIFT_VERSION = 5.0`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, UI layer explicitly `@MainActor`
  (collectors must run on their own queue, not be pinned to the default MainActor)

---

## Project layout

```
MetriBar/
├── MetriBarApp.swift              # @main: MenuBarExtra(.window) + Settings entry
├── MetriBar.entitlements        # app-sandbox = false
├── Model/                       # collection layer, fully decoupled from UI, never touches main thread
│   ├── MetricsSnapshot.swift    # immutable model (all Sendable value types)
│   ├── NetworkCollector.swift   # getifaddrs + if_data, NIC whitelist, Δ→bytes/s
│   ├── MemoryCollector.swift    # host_statistics64(HOST_VM_INFO64)
│   ├── CPULoadCollector.swift   # host_statistics(HOST_CPU_LOAD_INFO) tick deltas
│   ├── DiskCollector.swift      # FileManager.mountedVolumeURLs + URLResourceValues
│   ├── SMCSensorReader.swift    # actor: SMCKit wrapper, temp-key resolution + fan enumeration
│   ├── GPUCollector.swift       # IORegistry PerformanceStatistics: GPU / renderer / tiler (EMA)
│   └── MetricsEngine.swift      # DispatchSourceTimer scheduling + @MainActor MetricsStore
├── Views/
│   ├── MenuBarLabelView.swift   # menu-bar label (values only; rich → bitmap, compact → Text)
│   ├── PopoverView.swift        # popover panel
│   └── SettingsView.swift       # settings: interval / autostart / visible items / units
└── Support/
    ├── AppSettings.swift        # @AppStorage + SMAppService login item (+ self-heal)
    ├── MenuBarBadge.swift       # Core Text badge: fixed slots, @2x, font smoothing, pill bg
    ├── Formatters.swift         # speed / volume / temperature / percent formatting
    ├── UIComponents.swift       # PanelSection / MetricRow / SlimGauge / SettingsWindow
    └── Diagnostics.swift        # os_log entry (subsystem com.qyx.MetriBar)
```

### The collection pipeline (why the main thread never blocks)

```
DispatchSourceTimer (serial queue, qos .utility)
   ├─ NetworkCollector.sample()      sync, microseconds: getifaddrs
   ├─ MemoryCollector.sample()       sync: host_statistics64
   ├─ CPULoadCollector.sample()      sync: host_statistics
   ├─ DiskCollector.sample()         sync: URLResourceValues
   └─ Task { await SMCSensorReader } async: SMC IOKit round-trip
          ↓
   MetricsSnapshot (published as one immutable value)
          ↓
   @MainActor MetricsStore.publish()  ← main thread does a single assignment, triggers SwiftUI refresh
```

Three layers of defence:
1. **All syscalls run on the private serial queue**; the main thread only receives an immutable snapshot.
2. `isSampling` gate: if SMC blocks occasionally, **that tick is dropped** — tasks never pile up.
3. `leeway: 120ms` + pinned dependencies balance power use and stability.

---

## SMC sensor notes

`SMCSensorReader` first picks **readable, sensible (5–125 ℃)** sensors among candidate keys and takes the maximum as CPU temperature; if none match it falls back to scanning `Tp*` / `TC*` / `Tc*` prefixes, and enumerates `FNum` → `F{i}Ac / F{i}Mn / F{i}Mx` for fans.

| Platform | Common temperature keys |
| --- | --- |
| Apple Silicon (M1–M5) | `Tp0C` `Tp0R` `Tp04` `Tp08` `Tp1E` `Tc0C` … |
| Intel | `TC0P` `TC0D` `TC0E` `TC0F` `TCAD` `TCFH` `TCPP` … |

Decoded types: `flt ` (32-bit little-endian float), `sp78` (signed 8.8), `fpe6` (unsigned 2.6), `ui8 `, `ui16`. The panel shows which sensor key was used, so you can confirm the source of a reading.

> When temperature can't be read, the menu bar and panel show `--` — no crash, no fake fallback data.
> VMs / some desktop boards have no SMC temperature or fans; that's normal.

### NIC whitelist

Only real physical egress is counted: `en*`, `pdp_ip*`.
Explicitly excluded: `lo0` (loopback — inflates traffic), `utun*`/`ipsec*` (VPN — already counted on the physical interface), `awdl0`/`llw0`/`nan0`/`ap1` (Handoff / hotspot plumbing), `bridge0` (double-counts members), `gif0`/`stf0`, `anpi*`, `vmnet*` (virtualisation).
Counters are `UInt32`; **wraparound compensation** is applied. Baselines are rebuilt on reboot / abnormal intervals (≤50 ms or ≥30 s) and after wake-from-sleep.

> ⚠️ Byte counters must be read from `ifaddrs.ifa_data`, **never** from `ifa_addr`.
> For AF_LINK, `ifa_addr` is a `sockaddr_dl`; reading it at `if_data` offsets
> hits a constant value (observed `748800000`), producing "download speed always 0",
> while the upload field lands on a number that *does* change — extremely misleading.

---

## Verification

The app ships with os_log (subsystem `com.qyx.MetriBar`). By default it logs only start/stop and sensor resolution; enable per-tick detail when troubleshooting:

```bash
defaults write com.qyx.MetriBar MetriBarVerboseLogging -bool YES   # on
log stream --predicate 'subsystem == "com.qyx.MetriBar"' --level info
defaults delete com.qyx.MetriBar MetriBarVerboseLogging             # off
```

### Layout self-snapshot (see the UI without Screen Recording permission)

Without "Screen Recording" permission, `screencapture` can't grab the menu bar. A built-in offscreen self-check renders the badge (dark / light) and panel to PNG in a temp dir and logs the path — open it to see real layout and colours:

```bash
defaults write com.qyx.MetriBar MetriBarDebugSnap -bool YES
open MetriBar.app
log show --last 30s --predicate 'subsystem == "com.qyx.MetriBar" AND eventMessage CONTAINS "badge"'
defaults delete com.qyx.MetriBar MetriBarDebugSnap        # turn off when done
```

Switch the layout under **Settings › Menu bar › Layout**, with a live preview underneath (the preview is the same `MenuBarBadge` bitmap as the real status bar — what you see is what ships):

| Layout | Effect |
| --- | --- |
| Rich (default) | `⬇ 1.6M │ ⬆ 28K │ 🌡 66°`, icons recolour by load/temperature; thermometer swaps low/mid/high |
| Compact | `↓1.6M ↑28K 66°`, no icons, minimum width |

Verified output on **Apple Silicon (M5 Max / macOS 27 beta / Xcode 27)**, sampled while downloading an npm package:

```
[lifecycle] 采集启动：每 2.0 秒
[smc]       传感器解析完成：温度键 [Tp0C Tp0R Tp04 Tp08 Tp1E …] 风扇 2 个
[metrics]   en0 in 150681600->153684992 Δ3003392 | out 2418020352->2418158592 Δ138240 | elapsed=1.999
[metrics]   ↓1.5M ↑69K CPU 13% GPU 47% 温度 60°[Tp0C] 风扇 风扇 1 7247 RPM, 风扇 2 7804 RPM 内存 72% 磁盘剩余 676.96 GB 基线就绪=true
[lifecycle] 状态栏按钮：image 177x18pt isTemplate=false 像素 354x36
[lifecycle] 徽章宽度自检：稳定 177x18pt（样本数 3）
```

GPU reading comes from IOKit and differs in source from Activity Monitor › GPU (a private aggregate interface), but the trend matches:

```bash
ioreg -c AGXAccelerator -l | grep -i PerformanceStatistics   # raw device percentages
```

Memory accounting matches Activity Monitor (a 128 GB model measured at 71%–72% used).

---

## Distribution & installation

One command produces the installer (**universal binary Intel + Apple Silicon, self-contained, ~680 KB**):

```bash
./Scripts/build_dmg.sh                    # ad-hoc sign → dist/MetriBar-1.0.dmg
./Scripts/build_dmg.sh --identity "Developer ID Application: Your Name (TEAMID)" \
                       --notarize you@example.com TEAMID   # formal distribution (paid account)
```

The dmg contains `MetriBar.app` + an `/Applications` shortcut + `README`.

### Case A — sharing without a developer account (free)

An ad-hoc / un-notarized app is blocked by Gatekeeper after download, showing
"it is damaged" or "cannot be opened because it is from an unidentified developer". **The app isn't broken** — Apple simply hasn't notarized it. The recipient runs this once (permanent):

```bash
# Open the dmg, drag MetriBar.app into Applications, then run:
xattr -dr com.apple.quarantine /Applications/MetriBar.app
open /Applications/MetriBar.app
```

After that it opens and auto-starts like any normal app. The only downside: the recipient touches Terminal once.

### Case B — formal distribution (Apple Developer ID, $99/yr)

Signed + notarized opens with a double-click, no Terminal:

```bash
./Scripts/build_dmg.sh --identity "Developer ID Application: Your Name (TEAMID)" \
                       --notarize you@example.com TEAMID
```

The script submits via `notarytool` and staples with `stapler`. First time, store credentials once:
`xcrun notarytool store-credentials MetriBar-Notary --apple-id you@example.com --team-id TEAMID`.
(Because it reads SMC, `com.apple.security.app-sandbox = false` — **external distribution only, not the Mac App Store**.)

### Case C — installing on your own Mac

- **From this repo**: the `xcodebuild` output runs locally and is usually not blocked (local build = locally trusted). Drag it into `/Applications`.
- **From the dmg**: double-click to mount → drag `MetriBar.app` onto the `Applications` shortcut → open.
- **Autostart**: open the app → gear ⚙️ at bottom-right → toggle "Launch at login" (uses `SMAppService`, no plist). The app self-heals the login item to point at `/Applications` on launch.

> Seeing the icon **once** in the menu bar is correct (`LSUIElement`, no Dock tile). If an older instance was running from DerivedData, quit it first — `pkill -f MetriBar` — then open from `/Applications`.

---

## FAQ

| Symptom | Fix |
| --- | --- |
| **Gear doesn't open Settings** | Fixed: in an `LSUIElement` agent app `showSettingsWindow:` / `openSettings` only "respond" without creating a window. Settings is now hosted by `SettingsWindow.open()` (`NSWindow + NSHostingController`); both the gear and ⌘, use this path. |
| **Menu bar shows only download speed** | Fixed: with `HStack` the status item width may lock to the first frame and longer fields get clipped. Now it's a single composed label; the startup log confirms which toggles are on. |
| GPU shows `--` | VM / no Metal device: no accelerator node in `IORegistry` — a normal graceful degradation. |
| Temperature shows `--` | No matching SMC key on this board, or still sandboxed. Verify `ENABLE_APP_SANDBOX = NO` and rebuild; self-check with `ioreg -l \| grep -i SMC`. |
| Fans show "no fans detected" | Normal on passively cooled Macs (MacBook Air / Mac mini). |
| Speed stuck at `0` | First sample only builds a baseline; values appear after 2 s. If still 0, check whether only a VPN interface is carrying traffic (`utun*` is deliberately excluded). |
| Autostart doesn't work | After changing the `.app` path the toggle must be flipped once (the app self-heals this now); check System Settings › General › Login Items isn't blocking it. |
| Menu bar text too long, pushing other icons | Turn off "Upload speed" or "CPU usage" in Settings. |
| Console spam `com.apple.linkd.autoShortcut` / `4097` | Benign system noise from App Intents registration for an un-notarized app; it backs off ("Will NOT re-try"). No impact on monitoring. Fully silenced only by Developer ID + notarization. |

---

## License

- MetriBar: MIT
- [SMCKit](https://github.com/srimanachanta/SMCKit): MIT (from `beltex/SMCKit`, with a SwiftPM manifest added)
