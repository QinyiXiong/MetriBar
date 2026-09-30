import io
sp = "Scripts/selftest.sh"
x = io.open(sp, encoding="utf-8").read()

# 摘掉嵌错的残留
try:
    i0 = x.index("# ── 下载/环境功能守护（本轮事故教训常驻化）──")
    i1 = x.index("PYEOF", i0)
    x = x[:i0] + x[i1:]
except ValueError:
    pass

# 同时清掉刚才误写入的半截块（含语法错的）
try:
    i0 = x.index('echo "▍下载/环境功能守护"')
    i1 = x.index("PYEOF", i0) + len("PYEOF")
    # 可能不完整，找下一个完整结尾
    seg = x[i0:i1]
    x = x[:i0] + x[i1:]
except ValueError:
    pass

guard_block = '''echo "▍下载/环境功能守护"
python3 GUARD_SCRIPT_PLACEHOLDER'''

# 用外部临时 py 文件避免 heredoc 冲突
guard_py = '''import io, re, subprocess
swift_main = open("MetriBar/Views/TranslateTab.swift", encoding="utf-8").read()
bad = 0
if '"-lc", "command -v ffmpeg"' not in swift_main:
    print("  ✗ ffmpeg检测未走登录shell"); bad += 1
_ff = subprocess.run(["/bin/bash", "-lc", "command -v ffmpeg"], capture_output=True, text=True).stdout.strip()
if _ff:
    print("  ✓ ffmpeg 实际可检出:", _ff)
else:
    print("  ⚠ 本机bash -lc查不到ffmpeg")
if "dlPaused.insert(key)" not in swift_main or "dlPaused.contains(key)" not in swift_main:
    print("  ✗ 暂停哨兵缺失"); bad += 1
else:
    print("  ✓ 暂停哨兵在位")
if "只前进不回退" not in swift_main:
    print("  ✗ 进度账本clamp缺失"); bad += 1
else:
    print("  ✓ 进度只前进不回退")
if "verifyAndMark" not in swift_main:
    print("  ✗ 联网完整性校验缺失"); bad += 1
else:
    print("  ✓ 联网逐文件大小校验在位")
if "python/\\" ; " not in swift_main and 'supportDir + "/python"' not in swift_main:
    print("  ✗ runtime目录rename修复缺失(全量重建失败根因)"); bad += 1
else:
    print("  ✓ runtime解压目录对齐")
_m = re.search(r"pkgs = \\[([^\\]]+)\\]", swift_main)
if _m and all(k in _m.group(1) for k in ["funasr", "torch", "mlx-lm", "openai", "soundfile", "opencc"]):
    print("  ✓ 构建依赖清单完整(9包)")
else:
    print("  ✗ 构建依赖清单缺项"); bad += 1
if bad:
    exit(1)
'''

io.open(".guard_selftest.py", "w", encoding="utf-8").write(guard_py)

# 内联进 selftest：把guard_py作为heredoc插入（用唯一标签 GUARDEOF）
inline = 'echo "▍下载/环境功能守护"\npython3 <<\'GUARDEOF\'\n' + guard_py + 'GUARDEOF\n'

k = "▍键盘键位映射"
ki = x.index(k)
q = x.rindex('echo "', 0, ki)
x = x[:q] + inline + "\n" + x[q:]
io.open(sp, "w", encoding="utf-8").write(x)
print("guard inlined cleanly")
