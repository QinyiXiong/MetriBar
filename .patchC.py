import io, re

# ════ 1. transcribe.py：翻译/合并纳入进度流 + 每线程进度上报 ════
p = "Vendor/pipeline/transcribe.py"
t = io.open(p, encoding="utf-8").read()

a = "    translate_srt(srt_path, sys.argv[1], log)\n    merge_bilingual_srt(srt_path, sys.argv[1], log)"
assert t.count(a) == 1, "T-main"
b = '''    translate_srt(srt_path, sys.argv[1], log, progress=_progress_cb, should_stop=should_stop)
    merge_bilingual_srt(srt_path, sys.argv[1], log, progress=_progress_cb)'''
t = t.replace(a, b, 1)

# translate_srt 内部：每条成功后按完成数平滑上报 76→95
a = "        log.info(\n            f\"[{video_name}] 开始处理中文字幕 \"\n            f\"({total} 条, 翻译 {len(pending)} 条, 并发 {TRANSLATE_CONCURRENCY})\"\n        )"
assert t.count(a) == 1, "T-start"
b = '''    done_count = [0]
    log.info(
        f"[{video_name}] 开始处理中文字幕 "
        f"({total} 条, 翻译 {len(pending)} 条, 并发 {TRANSLATE_CONCURRENCY})"
    )'''
t = t.replace(a, b, 1)

# fut 完成回调上报（在 as_completed 处）
pat = re.search(r"( *)for future in as_completed\(fut_map\):\n", t)
assert pat, "T-ascompleted"
ind = pat.group(1)
add = (ind + "    _done_cb = lambda fut, _i=None: None\n")
t = t.replace(pat.group(0), pat.group(0), 1)

# 在循环体内第一行加进度上报
m = re.search(r"for future in as_completed\(fut_map\):\n( *)", t)
body_ind = m.group(1)
inject = (ind + "for future in as_completed(fut_map):\n"
          + body_ind + "done_count[0] += 1\n"
          + body_ind + "_progress(progress, \"translate\", 76 + 19.0 * done_count[0] / max(total, 1),\n"
          + body_ind + "               f\"已翻译 {done_count[0]}/{len(pending)} 条\")\n")
t = t[:m.start()] + inject + t[m.end():]

io.open(p, "w", encoding="utf-8").write(t)
import ast; ast.parse(io.open(p, encoding="utf-8").read())
print("transcribe progress wired")

# ════ 2. Swift：队列闸门只等服务；模型路径与 baseURL 恒定注入 ════
q = "MetriBar/Views/TranslateTab.swift"
s = io.open(q, encoding="utf-8").read()

a = '''    func startQueue() { autoRunning = true; runNext() }'''
assert s.count(a) == 1, "Q-start"
b = '''    func startQueue() {
        // 点开始先确保翻译服务在线（一次性），再放行队列
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if FileManager.default.isExecutableFile(atPath: ToolPaths.envPython) {
                self.ensureServer(TranslateSettings.shared)
            }
            DispatchQueue.main.async { self.autoRunning = true; self.runNext() }
        }
    }'''
s = s.replace(a, b, 1)

# execute 不再等服务
a = '''        patch(task.id) { $0.status = "准备中"; $0.message = "自动拉起翻译服务…" }
        ensureServer(settings)
        patch(task.id) { $0.status = "转写中"; $0.message = "启动子进程（模型加载…跑完自动卸载）" }'''
assert s.count(a) == 1, "Q-exec"
s = s.replace(a, '''        patch(task.id) { $0.status = "转写中"; $0.message = "语音识别中…" }''', 1)

# baseURL：只要服务在跑就用随机端口；否则留空串由 python 走其默认
a = '''                let baseURL = serverRunning && runtimePort > 0 ? "http://127.0.0.1:\\(runtimePort)/v1" : settings.translateBaseURL'''
assert s.count(a) == 1, "Q-baseurl"
b = '''        if serverRunning && runtimePort > 0 {
            env["METRIBAR_TRANSLATE_BASE_URL"] = "http://127.0.0.1:\\(runtimePort)/v1"
        }'''
s = s.replace(a, b, 1)

io.open(q, "w", encoding="utf-8").write(s)
print("swift gating fixed")
