#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""视频 → SRT 字幕 (FunASR)"""

import json
import logging
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import soundfile as sf
import numpy as np
from openai import OpenAI
from opencc import OpenCC

LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
MODEL_DIR = os.environ.get("METRIBAR_MODEL_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")

# MetriBar: 每个模型目录可用 env 覆盖（支持 LM Studio 等「发布者/模型」两级嵌套布局）
MODEL_PATH_OVERRIDES = {
    "sensevoice": os.environ.get("METRIBAR_SENSEVOICE_DIR", ""),
    "nano": os.environ.get("METRIBAR_NANO_DIR", ""),
    "mlt-nano": os.environ.get("METRIBAR_MLT_NANO_DIR", ""),
    "vad": os.environ.get("METRIBAR_VAD_DIR", ""),
}


def _fmt_duration(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    if h:
        return f"{h}h{m:02d}m{int(s):02d}s"
    if m:
        return f"{m}m{int(s):02d}s"
    return f"{s:.1f}s"


def create_logger(name, log_dir=LOG_DIR):
    log = logging.getLogger(name)
    log.setLevel(logging.INFO)
    if log.handlers:
        return log

    os.makedirs(log_dir, exist_ok=True)

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S"
    )

    fh = logging.FileHandler(
        os.path.join(log_dir, f"{name}.log"), mode="w", encoding="utf-8"
    )
    fh.setFormatter(fmt)

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)

    log.addHandler(fh)
    log.addHandler(sh)
    return log


FUNASR_MODELS = {
    "sensevoice": {
        "name": "SenseVoiceSmall",
        "model": os.path.join(MODEL_DIR, "SenseVoiceSmall"),
        "languages": "中 / 粤 / 英 / 日 / 韩",
        "timestamps": "token",
        "vad_max_segment_ms": 30000,
        "max_length": 512,
        "batch_size_threshold_s": 60,
    },
    "nano": {
        "name": "Fun-ASR-Nano",
        "model": os.path.join(MODEL_DIR, "Fun-ASR-Nano-2512"),
        "languages": "中 / 英 / 日 / 中文方言",
        "timestamps": "sentence",
        "vad_max_segment_ms": 30000,
        "max_length": 512,
        "batch_size_threshold_s": 60,
    },
    "mlt-nano": {
        "name": "Fun-ASR-MLT-Nano",
        "model": os.path.join(MODEL_DIR, "Fun-ASR-MLT-Nano-2512"),
        "languages": "31 种语言",
        "timestamps": "sentence",
        "vad_max_segment_ms": 8000,
        "max_length": 64,
        "batch_size_threshold_s": 0,
    },
}
FUNASR_VAD_MODEL = os.path.join(MODEL_DIR, "fsmn-vad")
# MetriBar: env 覆盖生效（LM Studio 等两级嵌套布局下由 App 注入真实路径）
for _k, _p in MODEL_PATH_OVERRIDES.items():
    if _p and os.path.isdir(_p):
        if _k == "vad":
            FUNASR_VAD_MODEL = _p
        elif _k in FUNASR_MODELS:
            FUNASR_MODELS[_k]["model"] = _p
DEFAULT_ASR_MODEL = "sensevoice"
_FUNASR_MODEL_INSTANCES = {}
_FUNASR_WARMED_MODELS = set()
_FUNASR_MODEL_LOCK = None

TRANSLATE_CONCURRENCY = 8  # 匹配版本(core0.31.2/lm0.31.3)下并发4路1.8s完成，真并发
_API_CONFIG = {"base_url": os.environ.get("METRIBAR_TRANSLATE_BASE_URL", "http://127.0.0.1:18888/v1"),
              "api_key": os.environ.get("METRIBAR_TRANSLATE_API_KEY", "pehwqyx6")}
TRANSLATE_MODEL = os.environ.get("METRIBAR_TRANSLATE_MODEL", "hy-mt2-7b")
PAUSE_SPLIT_SECONDS = 0.6
MAX_SUBTITLE_SECONDS = 10
MIN_SUBTITLE_SECONDS = 2.5
_TO_SIMPLIFIED = OpenCC("t2s")


def _translate_one(idx_str, ts, text):
    if not text:
        return (idx_str, ts, "")
    client = OpenAI(**_API_CONFIG)
    resp = client.chat.completions.create(
        model=TRANSLATE_MODEL,
        messages=[
            {
                "role": "user",
                "content": (
                    "将以下字幕翻译为简体中文。已有简体中文保持原样，"
                    "繁体中文转换为简体中文，只翻译其中的外语内容。"
                    "保留人名、数字和语气，只输出处理后的字幕，不要解释：\n\n"
                    f"{text}"
                ),
            }
        ],
        max_tokens=4096,
        temperature=0.7,
        top_p=0.6,
        extra_body={
            "top_k": 20,
            "repetition_penalty": 1.05
        },
    )
    translated = resp.choices[0].message.content.strip()
    return (idx_str, ts, translated)


def _get_funasr_model(model_key):
    global _FUNASR_MODEL_LOCK
    if model_key not in FUNASR_MODELS:
        raise ValueError(f"不支持的 FunASR 模型: {model_key}")
    if _FUNASR_MODEL_LOCK is None:
        import threading

        _FUNASR_MODEL_LOCK = threading.Lock()
    with _FUNASR_MODEL_LOCK:
        if model_key not in _FUNASR_MODEL_INSTANCES:
            from funasr import AutoModel

            _FUNASR_MODEL_INSTANCES[model_key] = AutoModel(
                model=FUNASR_MODELS[model_key]["model"],
                vad_model=FUNASR_VAD_MODEL,
                vad_kwargs={
                    "max_single_segment_time": FUNASR_MODELS[model_key][
                        "vad_max_segment_ms"
                    ]
                },
                device="mps",
                hub="ms",
                disable_update=True,
                disable_pbar=True,
            )
    return _FUNASR_MODEL_INSTANCES[model_key]


def preload_funasr_models(log=None, model_keys=(DEFAULT_ASR_MODEL,)):
    warmup_audio = np.zeros(16000, dtype=np.float32)
    for model_key in model_keys:
        if model_key in _FUNASR_WARMED_MODELS:
            continue
        config = FUNASR_MODELS[model_key]
        model_path = config["model"]
        if not os.path.isfile(os.path.join(model_path, "model.pt")):
            raise FileNotFoundError(f"模型不完整: {model_path}")

        started = time.monotonic()
        if log:
            log.info(f"正在加载并预热 {config['name']}")
        _get_funasr_model(model_key).generate(
            input=warmup_audio,
            language="auto",
            use_itn=True,
            output_timestamp=True,
            sentence_timestamp=True,
            return_time_stamps=True,
            batch_size_s=60,
            batch_size_threshold_s=config["batch_size_threshold_s"],
            max_length=config["max_length"],
        )
        if log:
            log.info(
                f"{config['name']} 预热完成 "
                f"(耗时 {_fmt_duration(time.monotonic() - started)})"
            )
        _FUNASR_WARMED_MODELS.add(model_key)


def _clean_sensevoice_text(text):
    return re.sub(r"<\|[^|]+\|>", "", text).strip()


def _sensevoice_languages(text, words):
    chunks = re.findall(
        r"<\|(zh|en|ja|ko|yue)\|>(?:<\|[^|]+\|>)*(.*?)(?=<\|(?:zh|en|ja|ko|yue)\|>|$)",
        text,
        re.DOTALL,
    )
    languages = []
    word_index = 0
    for language, chunk_text in chunks:
        target = re.sub(r"\s+", "", _clean_sensevoice_text(chunk_text)).lower()
        consumed = ""
        start = word_index
        while word_index < len(words):
            consumed += re.sub(r"\s+", "", words[word_index]).lower()
            word_index += 1
            if consumed == target or not target.startswith(consumed):
                break
        languages.extend([language] * (word_index - start))
    fallback = languages[-1] if languages else "unknown"
    languages.extend([fallback] * (len(words) - len(languages)))
    return languages


def _sensevoice_entries(result):
    words = result.get("words") or []
    timestamps = result.get("timestamp") or []
    languages = _sensevoice_languages(result.get("text", ""), words)
    entries = []
    current = []
    current_language = None

    def flush():
        nonlocal current
        if current:
            entries.extend(_subtitle_entries([{"words": current}], current_language))
            current = []

    for word, timestamp, language in zip(words, timestamps, languages):
        if not word or len(timestamp) < 2:
            continue
        punctuation = bool(re.fullmatch(r"[\s。！？.!?，,；;：:、]+", word))
        if punctuation and current:
            language = current_language
        display_word = word
        if (
            current
            and not punctuation
            and re.search(r"[A-Za-z]$", current[-1]["word"])
            and re.match(r"[A-Za-z]", word)
        ):
            display_word = " " + word
        item = {
            "word": display_word,
            "start": timestamp[0] / 1000,
            "end": timestamp[1] / 1000,
        }
        if current and (
            language != current_language
            or (
                not punctuation
                and item["start"] - current[-1]["end"] >= PAUSE_SPLIT_SECONDS
            )
        ):
            flush()
        current_language = language
        current.append(item)
        if re.search(r"[。！？.!?][\"'”’）)]?$", word.strip()):
            flush()
    flush()
    return [
        entry
        for entry in entries
        if not re.fullmatch(r"[\s。！？.!?，,；;：:、]+", entry["text"])
    ]


def _result_language(text):
    match = re.search(r"<\|(zh|en|ja|ko|yue)\|>", text or "")
    return match.group(1) if match else "unknown"


def _funasr_entries(result, audio_path):
    sentence_info = result.get("sentence_info") or []
    if sentence_info:
        entries = []
        for sentence in sentence_info:
            text = _clean_sensevoice_text(
                sentence.get("sentence") or sentence.get("text", "")
            )
            start = sentence.get("start", 0) / 1000
            end = sentence.get("end", 0) / 1000
            if text and end > start:
                entries.append({
                    "start": start,
                    "end": end,
                    "text": text,
                    "language": _result_language(
                        sentence.get("sentence") or sentence.get("text", "")
                    ),
                })
        if entries:
            return entries

    token_timestamps = result.get("timestamps") or []
    if token_timestamps:
        words = [
            {
                "word": item["token"],
                "start": item["start_time"],
                "end": item["end_time"],
            }
            for item in token_timestamps
            if item.get("token") and item.get("end_time", 0) > item.get("start_time", 0)
        ]
        if words:
            language = "zh" if re.search(r"[\u3400-\u9fff]", result.get("text", "")) else "unknown"
            return _subtitle_entries([{"words": words}], language)

    if result.get("words") and result.get("timestamp"):
        return _sensevoice_entries(result)

    text = _clean_sensevoice_text(result.get("text", ""))
    if not text:
        return []
    duration = sf.info(audio_path).duration
    return [{
        "start": 0,
        "end": duration,
        "text": text,
        "language": _result_language(result.get("text", "")),
    }]


def _run_funasr(audio_path, model_key, log, progress):
    config = FUNASR_MODELS[model_key]
    model_name = config["name"]
    _progress(progress, "vad", 12, f"正在加载 {model_name} 和 FSMN-VAD")
    preload_funasr_models(log, (model_key,))
    model = _get_funasr_model(model_key)
    _progress(progress, "transcribe", 20, f"{model_name} 正在识别完整音频")
    started = time.monotonic()

    def report(current, total):
        _progress(
            progress,
            "transcribe",
            20 + 55 * current / max(total, 1),
            f"{model_name} 正在识别 {current}/{total}",
        )

    result = model.generate(
        input=audio_path,
        language="auto",
        use_itn=True,
        output_timestamp=True,
        sentence_timestamp=True,
        return_time_stamps=True,
        batch_size_s=60,
        batch_size_threshold_s=config["batch_size_threshold_s"],
        max_length=config["max_length"],
        progress_callback=report,
    )[0]
    entries = _funasr_entries(result, audio_path)
    log.info(
        f"[{model_name}] 转录完成 ({len(entries)} 条, "
        f"耗时 {_fmt_duration(time.monotonic() - started)})"
    )
    return entries


def _subtitle_entries(segments, language):
    entries = []
    max_chars = 32 if language in {"zh", "ja", "ko"} else 56

    def add(words):
        text = "".join(word["word"] for word in words).strip()
        if text:
            entries.append({
                "start": words[0]["start"],
                "end": words[-1]["end"],
                "text": text,
                "language": language,
            })

    def best_split(words):
        for pattern in (r"[。！？.!?][\"'”’）)]?$", r"[，,；;：:、]$"):
            for i in range(len(words) - 2, -1, -1):
                if re.search(pattern, words[i]["word"].strip()):
                    return i + 1
        pauses = [
            words[i + 1]["start"] - words[i]["end"]
            for i in range(len(words) - 1)
        ]
        if pauses and max(pauses) >= 0.2:
            return pauses.index(max(pauses)) + 1
        return max(1, len(words) - 1)

    current = []

    def flush(force=False):
        nonlocal current
        while current:
            text_length = len("".join(item["word"] for item in current).strip())
            duration = current[-1]["end"] - current[0]["start"]
            if not force and text_length <= max_chars and duration <= MAX_SUBTITLE_SECONDS:
                return
            if force and text_length <= max_chars and duration <= MAX_SUBTITLE_SECONDS:
                add(current)
                current = []
                return
            split = best_split(current)
            add(current[:split])
            current = current[split:]

    for segment in segments:
        words = segment.get("words") or []
        if not words:
            flush(True)
            text = segment.get("text", "").strip()
            if text:
                entries.append({
                    "start": segment["start"],
                    "end": segment["end"],
                    "text": text,
                    "language": language,
                })
            continue

        if current and words[0]["start"] - current[-1]["end"] >= PAUSE_SPLIT_SECONDS:
            flush(True)
        for word in words:
            current.append(word)
            if re.search(r"[。！？.!?][\"'”’）)]?$", word["word"].strip()):
                flush(True)
            else:
                flush()
    flush(True)
    return entries


def _format_srt_time(seconds):
    millis = round(seconds * 1000)
    hours, millis = divmod(millis, 3_600_000)
    minutes, millis = divmod(millis, 60_000)
    secs, millis = divmod(millis, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"


def _write_srt(entries, path):
    for index, entry in enumerate(entries):
        next_start = entries[index + 1]["start"] if index + 1 < len(entries) else None
        extended_end = entry["start"] + MIN_SUBTITLE_SECONDS
        if next_start is not None:
            extended_end = min(extended_end, next_start)
        entry["end"] = max(entry["end"], extended_end)

    with open(path, "w", encoding="utf-8") as f:
        for idx, entry in enumerate(entries, 1):
            start = _format_srt_time(entry["start"])
            end = _format_srt_time(entry["end"])
            f.write(f"{idx}\n{start} --> {end}\n{entry['text']}\n\n")

    with open(path + ".meta.json", "w", encoding="utf-8") as f:
        json.dump(
            [{"index": idx, **entry} for idx, entry in enumerate(entries, 1)],
            f,
            ensure_ascii=False,
            indent=2,
        )


def _looks_chinese(text):
    has_han = re.search(r"[\u3400-\u9fff]", text)
    has_other_script = re.search(
        r"[A-Za-z\u3040-\u30ff\uac00-\ud7af\u0400-\u04ff]", text
    )
    return bool(has_han and not has_other_script)


def _load_languages(srt_path):
    meta_path = srt_path + ".meta.json"
    if not os.path.exists(meta_path):
        return {}
    with open(meta_path, encoding="utf-8") as f:
        return {str(item["index"]): item.get("language") for item in json.load(f)}


def _progress(callback, stage, percent, message):
    if callback:
        callback(stage, percent, message)


def run(
    video_name,
    video_path,
    srt_path,
    audio_path,
    asr_lock,
    log,
    progress=None,
    model_key=DEFAULT_ASR_MODEL,
    should_stop=None,
):
    t_start = time.monotonic()

    if os.path.exists(srt_path):
        log.info(f"[{video_name}] 字幕已存在，跳过")
        _progress(progress, "transcribe", 75, "原始字幕已存在")
        return

    if should_stop and should_stop():
        raise InterruptedError("任务已停止")

    if not os.path.exists(audio_path):
        log.info(f"[{video_name}] 开始提取音频")
        _progress(progress, "audio", 5, "正在提取音频")
        os.makedirs(os.path.dirname(audio_path), exist_ok=True)
        t_audio = time.monotonic()
        process = subprocess.Popen(
            [
                "ffmpeg", "-y",
                "-i", video_path,
                "-vn",
                "-acodec", "pcm_s16le",
                "-ar", "16000",
                "-ac", "1",
                audio_path,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        while process.poll() is None:
            if should_stop and should_stop():
                process.terminate()
                process.wait()
                if os.path.exists(audio_path):
                    os.remove(audio_path)
                raise InterruptedError("任务已停止")
            time.sleep(0.5)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, process.args)
        dt = time.monotonic() - t_audio
        log.info(f"[{video_name}] 音频提取完成 (耗时 {_fmt_duration(dt)})")
    else:
        log.info(f"[{video_name}] 音频已存在，跳过提取")

    if should_stop and should_stop():
        raise InterruptedError("任务已停止")

    if model_key not in FUNASR_MODELS:
        raise ValueError(f"不支持的 FunASR 模型: {model_key}")
    model_name = FUNASR_MODELS[model_key]["name"]
    log.info(f"[{video_name}] 使用 {model_name} + FSMN-VAD")
    with asr_lock:
        all_entries = _run_funasr(audio_path, model_key, log, progress)
    _write_srt(all_entries, srt_path)
    _progress(progress, "transcribe", 75, f"转录完成，共 {len(all_entries)} 条字幕")
    log.info(
        f"[{video_name}] 转录完成 ({len(all_entries)} 条字幕, "
        f"总计 {_fmt_duration(time.monotonic() - t_start)})"
    )


def translate_srt(srt_path, video_name, log, progress=None, should_stop=None):
    t_start = time.monotonic()
    cn_path = srt_path.replace(".srt", ".(中文).srt")
    if os.path.exists(cn_path):
        log.info(f"[{video_name}] 翻译字幕已存在，跳过")
        _progress(progress, "translate", 95, "中文字幕已存在")
        return

    with open(srt_path, encoding="utf-8") as f:
        raw = f.read()

    if should_stop and should_stop():
        raise InterruptedError("任务已停止")

    entries = _parse_srt(raw)
    total = len(entries)
    languages = _load_languages(srt_path)

    translated = [None] * total
    pending = {}
    failed = 0

    for i, (idx_str, ts, text) in enumerate(entries):
        language = languages.get(idx_str)
        if (language == "zh" and _looks_chinese(text)) or (
            language is None and _looks_chinese(text)
        ):
            translated[i] = f"{idx_str}\n{ts}\n{_TO_SIMPLIFIED.convert(text)}"
        else:
            pending[i] = (idx_str, ts, text)

    done_count = [0]
    log.info(
        f"[{video_name}] 开始处理中文字幕 "
        f"({total} 条, 翻译 {len(pending)} 条, 并发 {TRANSLATE_CONCURRENCY})"
    )
    _progress(progress, "translate", 76, f"需要翻译 {len(pending)}/{total} 条字幕")

    pool = ThreadPoolExecutor(max_workers=TRANSLATE_CONCURRENCY)
    try:
        fut_map = {
            pool.submit(_translate_one, *entry): i
            for i, entry in pending.items()
        }
        for done, fut in enumerate(as_completed(fut_map), 1):
            done_count[0] += 1
            _progress(progress, "translate", 76 + 19.0 * done_count[0] / max(total, 1),
                           f"已翻译 {done_count[0]}/{len(pending)} 条")
            if should_stop and should_stop():
                for pending_future in fut_map:
                    pending_future.cancel()
                raise InterruptedError("任务已停止")
            i = fut_map[fut]
            try:
                idx_str, ts, text = fut.result()
                translated[i] = f"{idx_str}\n{ts}\n{_TO_SIMPLIFIED.convert(text)}"
            except Exception as e:
                failed += 1
                log.error(f"[{video_name}] 翻译失败 (第 {i+1} 条): {e}")
                idx_str, ts, text = entries[i]
                translated[i] = f"{idx_str}\n{ts}\n{text}"

            if done % 50 == 0 or done == len(pending):
                log.info(
                    f"[{video_name}] 翻译进度: {done}/{len(pending)} (失败 {failed})"
                )
            _progress(
                progress,
                "translate",
                76 + 19 * done / max(len(pending), 1),
                f"正在翻译 {done}/{len(pending)} · 失败 {failed}",
            )
    except InterruptedError:
        pool.shutdown(wait=False, cancel_futures=True)
        raise
    else:
        pool.shutdown()

    with open(cn_path, "w", encoding="utf-8") as f:
        f.write("\n\n".join(translated) + "\n")

    dt = time.monotonic() - t_start
    log.info(
        f"[{video_name}] 中文字幕完成 → {os.path.basename(cn_path)} "
        f"({total} 条, 翻译 {len(pending)} 条, 失败 {failed}, "
        f"耗时 {_fmt_duration(dt)})"
    )
    _progress(progress, "translate", 95, "中文字幕处理完成")


def merge_bilingual_srt(srt_path, video_name, log, progress=None):
    t_start = time.monotonic()
    cn_path = srt_path.replace(".srt", ".(中文).srt")
    bilingual_path = srt_path.replace(".srt", ".(双语).srt")

    if not os.path.exists(cn_path):
        log.info(f"[{video_name}] 原始字幕已是中文，跳过双语合并")
        _progress(progress, "merge", 99, "无需生成双语字幕")
        return
    if os.path.exists(bilingual_path):
        log.info(f"[{video_name}] 双语字幕已存在，跳过")
        _progress(progress, "merge", 99, "双语字幕已存在")
        return

    log.info(f"[{video_name}] 开始合并双语字幕")
    _progress(progress, "merge", 96, "正在合并双语字幕")

    with open(srt_path, encoding="utf-8") as f:
        orig_lines = _parse_srt(f.read())
    with open(cn_path, encoding="utf-8") as f:
        cn_lines = _parse_srt(f.read())

    if len(orig_lines) != len(cn_lines):
        log.warning(
            f"[{video_name}] 条目数不匹配: 原始 {len(orig_lines)} vs 中文 {len(cn_lines)}，"
            "按序号配对"
        )

    cn_map = {idx: text for idx, _, text in cn_lines}

    merged = []
    for idx, ts, text in orig_lines:
        cn_text = cn_map.get(idx, "")
        merged.append(f"{idx}\n{ts}\n{text}")
        if cn_text and cn_text != text:
            merged[-1] += f"\n{cn_text}"

    with open(bilingual_path, "w", encoding="utf-8") as f:
        f.write("\n\n".join(merged) + "\n")

    dt = time.monotonic() - t_start
    log.info(
        f"[{video_name}] 双语合并完成 → {os.path.basename(bilingual_path)}"
        f" ({len(merged)} 条, 耗时 {_fmt_duration(dt)})"
    )
    _progress(progress, "merge", 99, "双语字幕合并完成")


def _parse_srt(content):
    content = content.replace("\r\n", "\n").replace("\r", "\n")
    blocks = re.split(r"\n(?=\d+\n\d{2}:\d{2})", content.strip())
    entries = []
    for block in blocks:
        lines = block.split("\n", 2)
        idx_str = lines[0]
        ts = lines[1]
        text = lines[2] if len(lines) > 2 else ""
        entries.append((idx_str, ts, text.strip()))
    return entries


if __name__ == "__main__":
    import threading

    t0 = time.monotonic()
    audio_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "音频")
    os.makedirs(audio_dir, exist_ok=True)
    audio_path = os.path.join(
        audio_dir, os.path.splitext(os.path.basename(sys.argv[3]))[0] + ".wav"
    )

    srt_path = sys.argv[3]
    log = create_logger(sys.argv[1])
    lock = threading.Lock()
    model_key = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_ASR_MODEL
    _progress_cb = None
    if os.environ.get("METRIBAR_JSON_PROGRESS"):
        def _progress_cb(stage, percent, message):
            print(json.dumps({"metriBarProgress": 1, "stage": stage, "percent": percent,
                              "message": message}, ensure_ascii=False), flush=True)
    run(sys.argv[1], sys.argv[2], srt_path, audio_path, lock, log,
        progress=_progress_cb, model_key=model_key)
    translate_srt(srt_path, sys.argv[1], log, progress=_progress_cb)  # 停止靠 SIGTERM(Swift terminate)
    merge_bilingual_srt(srt_path, sys.argv[1], log, progress=_progress_cb)
    dt = time.monotonic() - t0
    log.info(f"程序总耗时: {_fmt_duration(dt)}")
