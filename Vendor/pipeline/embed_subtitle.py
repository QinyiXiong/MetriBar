#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将字幕嵌入到视频中 (硬字幕)"""

import argparse
import os
import re
import subprocess
import sys


def find_srt_candidates(video_path):
    base = os.path.splitext(video_path)[0]
    dir_name = os.path.dirname(video_path) or "."
    base_name = os.path.basename(base)
    candidates = []
    for f in sorted(os.listdir(dir_name)):
        if not f.endswith(".srt"):
            continue
        f_base = os.path.splitext(f)[0]
        # match: basename.srt, basename.(中文).srt, basename.(双语).srt, etc.
        if f_base == base_name or f_base.startswith(base_name + ".("):
            candidates.append(os.path.join(dir_name, f))
    return candidates


def label_srt(path):
    name = os.path.basename(path)
    base = os.path.splitext(name)[0]
    m = re.search(r"\.\((.+?)\)$", base)
    if m:
        tag = m.group(1)
        labels = {"中文": "简体中文", "双语": "双语 (原文+中文)"}
        return labels.get(tag, tag)
    return "原始语音"


def select_srt(candidates):
    if not candidates:
        return None
    if len(candidates) == 1:
        return candidates[0]
    print("\n找到以下字幕文件:")
    for i, p in enumerate(candidates, 1):
        print(f"  {i}) {os.path.basename(p):30s} ({label_srt(p)})")
    while True:
        try:
            raw = input(f"请选择 [1-{len(candidates)}，默认 1]: ").strip()
            if not raw:
                return candidates[0]
            idx = int(raw)
            if 1 <= idx <= len(candidates):
                return candidates[idx - 1]
        except (ValueError, EOFError):
            pass
        print("输入无效，请重新选择")


def build_output_path(video_path, srt_path):
    base = os.path.splitext(video_path)[0]
    srt_name = os.path.splitext(os.path.basename(srt_path))[0]
    m = re.search(r"\.\((.+?)\)$", srt_name)
    if m:
        tag = m.group(1)
        labels = {"中文": "中文字幕", "双语": "双语字幕"}
        suffix = labels.get(tag, tag)
    else:
        suffix = "原始字幕"
    return f"{base}.({suffix}嵌入).mp4"


def build_ffmpeg_args(video_path, srt_path, output_path, opts):
    srt_escaped = srt_path.replace("\\", "/").replace(":", r"\:").replace("'", r"\'")
    style = (
        f"FontName={opts.font_name},"
        f"FontSize={opts.font_size},"
        f"PrimaryColour={opts.font_color},"
        f"BackColour=&H80000000,"
        f"Bold={1 if opts.bold else 0},"
        f"OutlineColour={opts.outline_color},"
        f"BorderStyle={opts.border_style},"
        f"Outline={opts.outline},"
        f"Shadow={opts.shadow},"
        f"MarginV={opts.margin_v}"
    )
    vf = f"subtitles='{srt_escaped}':force_style='{style}'"
    return [
        "ffmpeg", "-y",
        "-i", video_path,
        "-vf", vf,
        "-c:v", "libx264",
        "-crf", str(opts.crf),
        "-preset", opts.preset,
        "-c:a", "copy",
        output_path,
    ]


def main():
    parser = argparse.ArgumentParser(
        description="将 SRT 字幕嵌入到视频中（硬字幕），生成新的视频文件"
    )
    parser.add_argument("video", help="输入视频文件路径")
    parser.add_argument("-s", "--srt", help="字幕文件路径（不指定则自动查找）")
    parser.add_argument("-o", "--output", help="输出视频路径（默认自动生成）")
    parser.add_argument(
        "--font-name", default="PingFang SC",
        help="字体名称 (默认: PingFang SC)"
    )
    parser.add_argument(
        "--font-size", type=int, default=20,
        help="字体大小 (默认: 20)"
    )
    parser.add_argument(
        "--font-color", default="&H0000FFFF",
        help="字体颜色, ASS 格式 (默认: &H0000FFFF 亮黄色)"
    )
    parser.add_argument(
        "--outline-color", default="&H00000000",
        help="描边颜色 (默认: &H00000000 黑色)"
    )
    parser.add_argument(
        "--outline", type=float, default=2.0,
        help="描边宽度 (默认: 2.0)"
    )
    parser.add_argument(
        "--shadow", type=float, default=1.0,
        help="阴影深度 (默认: 1.0)"
    )
    parser.add_argument(
        "--border-style", type=int, default=1,
        help="边框样式 1=描边, 3=背景框 (默认: 1)"
    )
    parser.add_argument(
        "--margin-v", type=int, default=12,
        help="垂直边距, 像素 (默认: 12)"
    )
    parser.add_argument(
        "--bold", action=argparse.BooleanOptionalAction, default=True,
        help="粗体 (默认: 是，可用 --no-bold 关闭)"
    )
    parser.add_argument(
        "--crf", type=int, default=18,
        help="视频编码质量 18~28, 越小质量越高 (默认: 18)"
    )
    parser.add_argument(
        "--preset", default="fast",
        choices=["ultrafast", "superfast", "veryfast", "faster", "fast",
                 "medium", "slow", "slower", "veryslow"],
        help="x264 编码预设 (默认: fast)"
    )

    args = parser.parse_args()

    if not os.path.isfile(args.video):
        print(f"错误: 视频文件不存在: {args.video}", file=sys.stderr)
        sys.exit(1)

    srt_path = args.srt
    if not srt_path:
        candidates = find_srt_candidates(args.video)
        srt_path = select_srt(candidates)
        if not srt_path:
            print(f"错误: 未找到与 {args.video} 关联的字幕文件 (.srt)", file=sys.stderr)
            sys.exit(1)
    else:
        if not os.path.isfile(srt_path):
            print(f"错误: 字幕文件不存在: {srt_path}", file=sys.stderr)
            sys.exit(1)

    output_path = args.output or build_output_path(args.video, srt_path)
    if os.path.exists(output_path):
        print(f"输出文件已存在，将覆盖: {output_path}")

    print(f"视频:      {args.video}")
    print(f"字幕:      {srt_path}  ({label_srt(srt_path)})")
    print(f"输出:      {output_path}")
    print(f"编码参数:  crf={args.crf} preset={args.preset}")
    print()

    cmd = build_ffmpeg_args(args.video, srt_path, output_path, args)

    try:
        proc = subprocess.Popen(
            cmd,
            stderr=subprocess.STDOUT,
            stdout=subprocess.PIPE,
            universal_newlines=True,
        )
        for line in proc.stdout:
            line = line.strip()
            if line and ("time=" in line or "Error" in line or "error" in line):
                print(f"  {line}")
        proc.wait()
        if proc.returncode != 0:
            print(f"错误: ffmpeg 退出码 {proc.returncode}", file=sys.stderr)
            sys.exit(1)
        print(f"\n完成: {output_path}")
    except FileNotFoundError:
        print("错误: 未找到 ffmpeg，请确认已安装且已在 PATH 中", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
