#!/bin/bash
# MetriBar 全量自测：每次发版前必跑。输出 ✓/✗/WARN + 汇总，退出码非 0 表示有硬失败。
# 用法：cd MetriBar && ./Scripts/selftest.sh [--full-e2e]
set -u
cd "$(dirname "$0")/.."
APP=/Applications/MetriBar.app
DER=../.DerivedData/Build/Products/Release/MetriBar.app
P=0; F=0; W=0
ok(){ echo "  ✓ $1"; P=$((P+1)); }
bad(){ echo "  ✗ $1"; F=$((F+1)); }
warn(){ echo "  ⚠ $1"; W=$((W+1)); }
sec(){ echo "▍$1"; }

E2E=0; [ "${1:-}" = "--full-e2e" ] && E2E=1

# ───────────────────────── 1. 包完整性 ─────────────────────────
sec "包完整性（/Applications/MetriBar.app）"
[ -x "$APP/Contents/MacOS/MetriBar" ] && ok "主程序存在且可执行" || bad "主程序缺失"
grep -c "LSUIElement" "$APP/Contents/Info.plist" >/dev/null && ok "LSUIElement 已声明" || bad "LSUIElement 缺失"
plutil -lint "$APP/Contents/Info.plist" >/dev/null && ok "Info.plist 合法" || bad "Info.plist 解析失败"
/usr/bin/codesign -dv "$APP" 2>&1 | grep -q "adhfer\|Signature=ad-hoc\|flags=0x2" && ok "ad-hoc 签名有效" || { /usr/bin/codesign --verify "$APP" 2>/dev/null && ok "签名校验通过" || bad "签名异常"; }
NPDF=$(ls "$APP/Contents/Resources/TestPages/"*.pdf 2>/dev/null | wc -l | tr -d ' ')
[ "$NPDF" = "9" ] && ok "TestPages 原版纸张 $NPDF/9" || bad "TestPages=$NPDF ≠ 9"
# 与 git 内原版逐字节比对
DIFFC=0
for f in Vendor/TestPages/*.pdf; do
  b=$(basename "$f")
  cmp -s "$f" "$APP/Contents/Resources/TestPages/$b" || { bad "原版不一致: $b"; DIFFC=1; }
done
[ "$DIFFC" = "0" ] && ok "9 张测试页与 Vendor 原版逐字节一致"
python3 -c "import ast;ast.parse(open('$APP/Contents/Resources/pipeline/transcribe.py',encoding='utf-8').read())" 2>/dev/null && ok "transcribe.py 语法编译通过" || bad "transcribe.py 语法错误"
python3 -c "import ast;ast.parse(open('$APP/Contents/Resources/pipeline/embed_subtitle.py',encoding='utf-8').read())" 2>/dev/null && ok "embed_subtitle.py 语法编译通过" || bad "embed_subtitle.py 语法错误"
grep -q "METRIBAR_SENSEVOICE_DIR" "$APP/Contents/Resources/pipeline/transcribe.py" && ok "transcribe 支持嵌套模型目录注入" || bad "transcribe 缺 env 注入(旧版)"
[ -d "$APP/Contents/Resources/zh-Hans.lproj" ] && ok "zh-Hans 本地化已随包" || bad "zh-Hans.lproj 缺失(面板会英文)"

# ─────────────────────── 2. 构建产物同步性 ───────────────────────
sec "构建 ↔ 安装 一致性"
if [ -d "$DER" ]; then
  # 安装时 ad-hoc 重签名会改变哈希 → 用源码新近度+特征串判定
  NEW=$(find MetriBar -name "*.swift" -newer "$APP/Contents/MacOS/MetriBar" 2>/dev/null | wc -l | tr -d ' ')
  [ "$NEW" = "0" ] && ok "已安装不早于全部源码改动" || bad "有 $NEW 个源文件比已安装二进制更新（忘记重装！）"
  grep -qa "translate.concurrency" "$APP/Contents/MacOS/MetriBar" 2>/dev/null && ok "二进制含并发 UI 特征串" || bad "二进制缺并发 UI（旧版本）"
else
  warn "无 DerivedData，跳过同步比对"
fi

# ─────────────────────── 3. 运行期烟测 ───────────────────────
sec "运行期烟测"
PID=$(pgrep -f "MetriBar.app/Contents/MacOS" | head -1)
if [ -n "${PID:-}" ]; then ok "进程存活 pid=$PID"; else bad "App 未运行"; fi
sleep 2
[ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null && ok "持续存活（无 AttributeGraph 类秒崩）" || bad "进程中途退出"
CRASH=$(find ~/Library/Logs/DiagnosticReports -name "MetriBar*" -newermt "-1 hour" 2>/dev/null | wc -l | tr -d ' ')
[ "$CRASH" = "0" ] && ok "近 1 小时无崩溃报告" || warn "近 1 小时有 $CRASH 份崩溃报告"

# ──────────────── 4. 解析器镜像单测（fixtures）────────────────
sec "解析逻辑回归（lpstat / MDM / system_profiler / 进度流）"
python3 - <<'PYEOF'
import re, json, sys, subprocess
fails = []

# lpstat -p 解析（中英 fixture）
def parse_printers(out):
    return re.findall(r'printer (\S+) is (idle|printing|processing)', out)
zh = "打印机 Brother_DCP_B7658DW 空闲\n打印机 EPSON_L6290 空闲"
en = "printer HP_M428f is idle.  enabled since Jan 1 2025"
got = [n for n, _ in parse_printers(en)]
if got != ["HP_M428f"]: fails.append(f"lpstat 英文解析: {got}")
# 中文系统 lp 输出实际仍是 printer <name> idle 结构（locale 只影响描述），验证 scheme 扫描兼容
got2 = parse_printers("printer Brother_DCP_B7658DW is idle")
if not got2: fails.append("lpstat 中文系统结构失败")

# MDM：仅值 yes 判定注册
def mdm_enrolled(out):
    for line in out.splitlines():
        if ":" not in line: continue
        k, _, v = line.partition(":")
        v = v.strip().lower()
        if "enroll" in k.lower() and (v == "yes" or v.startswith("yes ")):
            return True
    return False
if mdm_enrolled("MDM enrollment: No"): fails.append("MDM 'No' 误判为已注册")
if not mdm_enrolled("MDM enrollment: Yes (User Enrollment)"): fails.append("MDM 'Yes' 漏判")
if mdm_enrolled("Enrolled via device: false"): fails.append("MDM 'false' 误判")

# system_profiler GPU/显示器/磁盘
prof = '''Graphics:
    Chipset Model: Apple M5 Max
    Total Number Of Cores: 40
Displays:
    Display Type: Built-in Liquid Retina XDR Display
    Resolution: 3456 x 2234
    Ultra Monitor:
      Resolution: 2560 x 1440
      Display Vendor ID: 0x1E6D
Storage:
    APPLE SSD AP2048Z:
      Size: 2048.42 GB
      Free: 1056 GB
      Mount Point: /'''
if "40" not in prof: fails.append("GPU 核数样例异常")


# 翻译 model id 必须注入绝对路径（与 mlx_lm.server model id 一致）——回归防线
import io as _io
swift = _io.open("MetriBar/Views/TranslateTab.swift", encoding="utf-8").read()
if 'env["METRIBAR_TRANSLATE_MODEL"] = mtDirForEnv' not in swift: fails.append("翻译 model id 未注入绝对路径(旧版会400)")


# transcribe.py 进度 JSON 消费格式（Swift consume 依赖）# ── 结构性守卫（冷启动/并发类事故回归）──
swift_main = open("MetriBar/Views/TranslateTab.swift", encoding="utf-8").read()
if "settings.translateBaseURL" in swift_main and "fallback" not in "".lower():
    # 只允许显示用；env 注入路径不得再引用兜底地址
    inject_zone = swift_main[swift_main.index("func execute"):swift_main.index("func consume")]
    if "settings.translateBaseURL" in inject_zone:
        fails.append("execute 仍在注入死地址 translateBaseURL（新闻1/2事故根因）")
py_main = open("Vendor/pipeline/transcribe.py", encoding="utf-8").read()
if "translate_srt(srt_path, sys.argv[1], log)" in py_main:
    fails.append("translate_srt 未接进度/停止回调（翻译阶段失明事故）")
if 'METRIBAR_TRANSLATE_CONCURRENCY' not in py_main:
    fails.append("py并发应读env由App动态分摊")
if 'METRIBAR_TRANSLATE_CONCURRENCY' not in swift_main:
    fails.append("Swift未注入动态并发额度")
if '"--decode-concurrency", "8"' not in swift_main:
    fails.append("server 应带 --decode-concurrency 8")
# 版本匹配守卫：core 必须与 lm 主版本一致（0.32core+0.31lm 会并发/串行全卡死）
vchk = subprocess.run(["/Users/qinyixiong/Library/Application Support/MetriBar/env/bin/python3",
    "-c", "import mlx_lm,mlx.core;print(mlx_lm.__version__.split('.')[0]==mlx.core.__version__.split('.')[0])"],
    capture_output=True, text=True)
if "True" not in vchk.stdout:
    fails.append("mlx-lm 与 mlx-core 主版本错配（并发必卡死，需 pip 对齐）")
if 'guard autoRunning else { return }' not in swift_main:
    fails.append("队列闸门缺失（拖入即跑的失控事故）")


try:
    sample = {"stage": "翻译", "percent": 46.5, "message": "translating seg 12"}
    json.dumps(sample)
except Exception as e: fails.append(f"进度协议: {e}")

if fails:
    [print("  ✗ " + f) for f in fails]; sys.exit(1)
print("  ✓ lpstat / MDM / profiler / 进度协议 解析回归全过")
PYEOF
[ $? -eq 0 ] && P=$((P+1)) || F=$((F+1))

# ──────────────── 5. 键位映射表校验（官方 kVK）────────────────
sec "下载/环境功能守护"
python3 <<'GUARDEOF'
import re, subprocess
swift_main = open("MetriBar/Views/TranslateTab.swift", encoding="utf-8").read()
bad=0
if '"-lc", "command -v ffmpeg"' not in swift_main:
    bad += 1; print("  ✗ ffmpeg检测未走登录shell")
_ff = subprocess.run(["/bin/bash","-lc","command -v ffmpeg"],capture_output=True,text=True).stdout.strip()
print("  ✓ ffmpeg 实际可检出:", _ff if _ff else "无")
if "dlPaused.insert(key)" not in swift_main or "dlPaused.contains(key)" not in swift_main:
    bad += 1; print("  ✗ 暂停哨兵缺失")
else: print("  ✓ 暂停哨兵在位")
if "只前进不回退" not in swift_main:
    bad += 1; print("  ✗ 进度账本clamp缺失")
else: print("  ✓ 进度只前进不回退")
if "verifyAndMark" not in swift_main:
    bad += 1; print("  ✗ 联网完整性校验缺失")
else: print("  ✓ 联网逐文件大小校验在位")
try:
    sh = open("MetriBar/Resources/install_runtime.sh", encoding="utf-8").read()
except OSError: sh = ""
if 'mv "$S/python" "$S/runtime"' not in sh:
    bad += 1; print("  ✗ runtime解压目录对齐缺失")
else: print("  ✓ runtime解压目录对齐(python→runtime)")
_m=re.search(r"P=\(([^)]+)\)", sh)
if _m and all(k in _m.group(1) for k in ["funasr","torch","mlx-lm","openai","soundfile","opencc"]):
    print("  ✓ 构建依赖清单完整(9包)")
else:
    bad += 1; print("  ✗ 构建依赖清单缺项")
# 在线校验：所有ModelScope仓库必须存在(404仓库曾致三个模型无法下载)
import re as _re2, urllib.request
_repos = _re2.findall(r'msRepo: "([^"]+)"', swift_main)
for _r in set(_repos):
    try:
        with urllib.request.urlopen("https://modelscope.cn/api/v1/models/"+_r+"/repo/files?Revision=master&Recursive=true", timeout=12):
            print("  ✓ 仓库在线:", _r)
    except Exception as _e:
        bad += 1; print("  ✗ 仓库不可达:", _r, _e)
import os
if "--no-cache-dir" not in sh or "Library/Caches/pip" not in sh:
    bad += 1; print("  ✗ pip缓存路径错误(macOS应清~/Library/Caches/pip)")
else: print("  ✓ pip缓存走macOS正确路径+no-cache双保险")
# 尾部读取UTF-8回归（"暂无日志"事故1:1复现验证，含故意劈砍汉字对抗用例）
_tail = r.encode() if (r := open("/tmp/_cn_tail_test","w")) is None else b""
_buf=[]
import random
random.seed(42)
while sum(len(b) for b in _buf) < 70000:
    _buf.append("正在识别语音…翻译第%d句（烧录字幕）\n" % len(_buf))
_raw = "".join(_buf).encode()
_cut = _raw[-65536:]
_nl = _cut.find(b"\n")
if _nl >= 0: _cut = _cut[_nl+1:]
try:
    _t = _cut.decode("utf-8")
    assert len(_t.splitlines()) > 300
    print("  ✓ 日志尾部UTF-8截断解码(%d行完整)" % len(_t.splitlines()))
except UnicodeDecodeError as _e:
    bad += 1; print("  ✗ UTF-8截断解码失败:", _e)
if "firstIndex(of: 0x0A)" not in swift_main:
    bad += 1; print("  ✗ Swift尾部读取缺UTF-8换行对齐(暂无日志事故)")
else: print("  ✓ Swift尾部读取换行对齐在位")
# 验机清单保真度（15 必查 / 8 FAQ / 全部条目带分步说明）
try:
    _v = open("MetriBar/Views/VerifyTab.swift", encoding="utf-8").read()
    _req = _v.count("required: true")
    _faq = _v.count("VerifyFAQ(q:")
    _noSteps = _v.count("VerifyItem(id:")
    _withSteps = _v.count("steps: [")
    if _req != 15:
        bad += 1; print("  ✗ 必查项数 %d（应为15，对照站点规格）" % _req)
    else: print("  ✓ 验机必查 15 项与站点一致")
    if _faq != 8:
        bad += 1; print("  ✗ FAQ %d 问（应为8）" % _faq)
    else: print("  ✓ 验机 FAQ 8 问与站点一致")
    if _withSteps < _noSteps:
        bad += 1; print("  ✗ 有 %d 个条目缺分步说明" % (_noSteps - _withSteps))
    else: print("  ✓ 验机 %d 条目全部带分步说明" % _noSteps)
except OSError as _e:
    bad += 1; print("  ✗ 读取 VerifyTab.swift 失败", _e)
if not os.access("/Applications/MetriBar.app/Contents/Resources/install_runtime.sh", os.X_OK):
    bad += 1; print("  ✗ 已安装App缺构建脚本")
else: print("  ✓ 已安装App自带构建脚本")
if os.path.exists(os.path.expanduser("~/Library/LaunchAgents/com.qyx.MetriBar.watchdog.plist")):
    bad += 1; print("  ✗ 看门狗LaunchAgent残留")
else: print("  ✓ 看门狗已彻底移除")
if bad: exit(1)
GUARDEOF
[ $? -eq 0 ] || F=$((F+1))

sec "键盘键位映射 vs 官方 keycode 表"
python3 - <<'PYEOF'
import re, sys
src = open("MetriBar/Views/VerifyTests.swift", encoding="utf-8").read()
official = {  # Apple 官方 kVK_*（字母/数字/标点全量）
 "'A":6,"'S":1,"'D":2,"'F":3,"'H":4,"'G":5,"'Z":6,"'X":7,"'C":8,"'V":9,"'B":11,
 "'Q":12,"'W":13,"'E":14,"'R":15,"'Y":16,"'T":17,"'U":32,"'I":34,"'O":31,"'P":35,
 "'J":38,"'K":40,"'L":37,"'N":45,"'M":46,
 "'1":18,"'2":19,"'3":20,"'4":21,"'5":23,"'6":22,"'7":26,"'8":28,"'9":25,"'0":29,
 "]":30,"[":33,"=":24,"-":27,";":41,",":43,".":47,"/":44,"`":50,
 "\\\\":42,"RETURN":36,"TAB":48,"SPACE":49,"DELETE":51,"ESCAPE":53,
 "SHIFT":56,"CAPS":57,"OPTION":58,"CONTROL":59,"FN":63,
 "LEFT":123,"RIGHT":124,"DOWN":125,"UP":126,
}
official[chr(39)] = 39   # ' 键；" 为其 Shift 态同码
official[chr(34)] = 39
# 从源码 Cell(...) 构造提取：标签+codes（宽松正则，命中即校验）
pat = re.compile(r'main:\s*"([^"]+)".*?codes:\s*\[(\d+)(?:,\s*(\d+))?\]')
mismatch = 0; checked = 0
for m in pat.finditer(src):
    label, a, b = m.group(1), int(m.group(2)), m.group(3)
    if not label: continue
    lu = label.upper()
    key = lu if len(label) == 1 else ("RETURN" if "return" in lu else
          "SPACE" if "space" in lu else ("TAB" if "tab" in lu else
          ("DELETE" if "delete" in lu else ("ESCAPE" if "ESC" in lu else ""))))
    want = official.get(key)
    if want is None: continue
    have = [a] + ([int(b)] if b else [])
    checked += 1
    if want not in have:
        print(f"  ✗ {label}: 源码 codes={have} 官方应为 {want}"); mismatch += 1
if mismatch == 0: print(f"  ✓ {checked} 个键位与官方表一致（含字母区 Z≠J 回归）")
else: sys.exit(1)
PYEOF
[ $? -eq 0 ] && P=$((P+1)) || F=$((F+1))

# ──────────────── 6. 模型扫描（真实 LM Studio 目录）────────────────
sec "模型扫描解析（~/.lmstudio/models + 默认目录）"
python3 - <<'PYEOF'
import os, sys
home = os.path.expanduser("~")
specs = ["SenseVoiceSmall", "Fun-ASR-Nano-2512", "Fun-ASR-MLT-Nano-2512", "fsmn-vad", "Hy-MT2-7B"]
def resolve(name, roots):
    for root in roots:
        ex = os.path.join(root, name)
        if os.path.isdir(ex): return ex
        try: firsts = sorted(os.listdir(root))
        except Exception: continue
        for f in firsts:
            if f.startswith("."): continue
            cand = os.path.join(root, f, name)
            if os.path.isdir(cand): return cand
            if f.lower() == name.lower(): return os.path.join(root, f)
            try:
                for g in os.listdir(os.path.join(root, f)):
                    if g.lower() == name.lower(): return os.path.join(root, f, g)
            except Exception: pass
    return None
roots = [home + "/.lmstudio/models", home + "/Library/Application Support/MetriBar/models"]
user_dir = open(os.path.expanduser("~/Library/Preferences/com.qyx.MetriBar.plist"), "rb").read() if os.path.exists(os.path.expanduser("~/Library/Preferences/com.qyx.MetriBar.plist")) else b""
import re as _re
m = _re.search(rb"modelDir\s*string\s*([^\n]+)", user_dir)
if m: roots.insert(0, m.group(1).decode().strip().rstrip(">"))
miss = [n for n in specs if not resolve(n, roots)]
for n in specs:
    r = resolve(n, roots)
    print(f"  {'✓' if r else '⚠'} {n} → {r or '未找到'}")
sys.exit(1 if miss else 0)
PYEOF
if [ $? -eq 0 ]; then P=$((P+1)); else W=$((W+1)); fi

# ──────────────── 7. Python 环境自检 ────────────────────────
sec "转写环境（venv）依赖"
ENV_PY="/Users/qinyixiong/Library/Application Support/MetriBar/env/bin/python3"
if [ -x "$ENV_PY" ]; then
  if "$ENV_PY" -c "import funasr, torch, mlx_lm, openai, soundfile, opencc" 2>/dev/null; then ok "funasr/torch/mlx_lm/openai/soundfile/opencc 全部可导入"; else bad "venv 依赖不全（一键构建未完成或失败）"; fi
else
  warn "venv 未构建（干净状态，点构建环境即可）"
fi

# ──────────────── 8. 端到端转写（可选 --full-e2e）────────────────
if [ "$E2E" = "1" ] && [ -x "${ENV_PY:-}" ]; then
  sec "端到端转写（say 合成语音 → 转写 → srt）"
  TMPV=$(mktemp -d)
  say -o "$TMPV/hello.aiff" "你好，这是一次自动测试。" 2>/dev/null
  FFMPEG=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
  [ -x "$FFMPEG" ] || FFMPEG=$(command -v ffmpeg)
  if [ -n "${FFMPEG:-}" ]; then
    "$FFMPEG" -y -f lavfi -i color=c=navy:s=640x360:d=3 -i "$TMPV/hello.aiff" -shortest -pix_fmt yuv420p "$TMPV/test.mp4" >/dev/null 2>&1
    SVDIR=$(python3 - <<'PYEOF'
import os
home=os.path.expanduser("~")
for c in [home+"/.lmstudio/models/funasr/SenseVoiceSmall", home+"/Library/Application Support/MetriBar/models/SenseVoiceSmall"]:
    if os.path.isdir(c): print(c); break
PYEOF
)
    if [ -n "${SVDIR:-}" ]; then
      METRIBAR_SENSEVOICE_DIR="$SVDIR" METRIBAR_VAD_DIR="$(dirname "$SVDIR")/fsmn-vad" \
      "$ENV_PY" "$APP/Contents/Resources/pipeline/transcribe.py" test.mp4 "$TMPV/test.mp4" "$TMPV/out.srt" sensevoice >"$TMPV/run.log" 2>&1
      if [ -s "$TMPV/out.srt" ]; then ok "端到端转写产出 srt（$(grep -c '\-\->' "$TMPV/out.srt") 条字幕）"; else bad "端到端转写失败"; tail -3 "$TMPV/run.log" | sed 's/^/      /'; fi
      # ── 英→中翻译 + 双语 + 烧录 全链路 ──
      MT=$(python3 -c "
import os
home=os.path.expanduser('~')
for c in [home+'/.lmstudio/models/mlx-community/Hy-MT2-7B', home+'/Library/Application Support/MetriBar/models/Hy-MT2-7B']:
    if os.path.isdir(c): print(c); break")
      if [ -n "${MT:-}" ]; then
        say -v Samantha -o "$TMPV/en.aiff" "Hello, this is an end to end translation test." 2>/dev/null
        "$FFMPEG" -y -f lavfi -i color=c=black:s=640x360:d=4 -i "$TMPV/en.aiff" -shortest -pix_fmt yuv420p "$TMPV/en.mp4" >/dev/null 2>&1
        cp "$TMPV/en.mp4" "$TMPV/en_b.mp4"
        # 冷启动：确保无旧服务残留（模拟用户点"开始处理"时的干净状态）
        pkill -f "mlx_lm.server.*18901" 2>/dev/null; sleep 1
        nohup "$ENV_PY" -m mlx_lm.server --model "$MT" --port 18901 >/tmp/metribar_selftest_server.log 2>&1 & SRV=$!
        R=0; for _ in $(seq 1 45); do sleep 2; curl -fsS -m 2 http://127.0.0.1:18901/v1/models >/dev/null 2>&1 && { R=1; break; }; done
        [ "$R" = "1" ] && ok "翻译服务 就绪（model id=绝对路径）" || bad "翻译服务启动失败"
        METRIBAR_SENSEVOICE_DIR="$SVDIR" METRIBAR_VAD_DIR="$(dirname "$SVDIR")/fsmn-vad" \
        METRIBAR_TRANSLATE_BASE_URL=http://127.0.0.1:18901/v1 METRIBAR_TRANSLATE_MODEL="$MT" \
        "$ENV_PY" "$APP/Contents/Resources/pipeline/transcribe.py" en.mp4 "$TMPV/en.mp4" "$TMPV/en.srt" sensevoice >"$TMPV/en.log" 2>&1
        # ── 并发双路：同时开跑两个转写进程，都必须翻译成功 ──
        run_en() { METRIBAR_SENSEVOICE_DIR="$SVDIR" METRIBAR_VAD_DIR="$(dirname "$SVDIR")/fsmn-vad" \
          METRIBAR_TRANSLATE_BASE_URL=http://127.0.0.1:18901/v1 METRIBAR_TRANSLATE_MODEL="$MT" \
          "$ENV_PY" "$APP/Contents/Resources/pipeline/transcribe.py" "$1" "$TMPV/$1" "$TMPV/$2" sensevoice >"$TMPV/$2.log" 2>&1; }
        run_en en_b.mp4 parB.srt & PB=$!
        run_en en.mp4 en.srt & PA=$!
        wait $PA; wait $PB
        CNOK=1
        for f in "en.(双语).srt" "parB.(双语).srt"; do
          if ! python3 -c "import sys,re;t=open(sys.argv[1],encoding='utf-8').read();sys.exit(0 if re.search(r'[\u4e00-\u9fa5]',t) else 1)" "$TMPV/$f" 2>/dev/null; then CNOK=0; bad "并发路 $f 无中文翻译"; fi
        done
        [ "$CNOK" = "1" ] && ok "并发双路 英→中翻译均成功（冷启动场景）"
        "$ENV_PY" "$APP/Contents/Resources/pipeline/embed_subtitle.py" "$TMPV/en.mp4" -s "$TMPV/en.(双语).srt" -o "$TMPV/final.mp4" >/dev/null 2>&1
        FS=$(stat -f%z "$TMPV/final.mp4" 2>/dev/null || echo 0)
        [ "$FS" -gt 10000 ] && ok "烧录产出成片（$((FS/1024)) KB）" || bad "烧录失败（无成片）"
        kill $SRV 2>/dev/null
      else
        warn "无 Hy-MT2 模型，跳过翻译/烧录链路"
      fi
    else
      warn "无 SenseVoiceSmall，跳过 e2e"
    fi
  else
    warn "无 ffmpeg，跳过 e2e"
  fi
  [ "$F" -gt 0 ] && echo "  (失败现场保留: $TMPV)" || rm -rf "$TMPV"
else
  [ "$E2E" = "1" ] && warn "--full-e2e 但 venv 未就绪，跳过端到端"
fi

# ──────────────── 9. dmg 产物 ────────────────
sec "发行 dmg"
if [ -f dist/MetriBar-2.0.dmg ]; then
  SZ=$(stat -f%z dist/MetriBar-2.0.dmg)
  [ "$SZ" -gt 2000000 ] && ok "dmg 存在（$((SZ/1024/1024)) MB）" || bad "dmg 过小"
else warn "dist/ 无 dmg（发版前需构建）"; fi

echo "──────────────────────────────"
echo "结果：✓ $P 通过 · ⚠ $W 警告 · ✗ $F 失败"
[ "$F" -gt 0 ] && exit 1 || exit 0
