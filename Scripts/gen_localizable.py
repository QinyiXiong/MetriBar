#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从源码提取中文字面量，合并 Scripts/i18n_en.json 的英文译文，生成 MetriBar/Localizable.xcstrings。

为什么这样做：
  · SwiftUI 的 `Text("中文")` 本身走 LocalizedStringKey，**中文原文即 key**；
    只要 catalog 里有该条目，调用点无需改动即可本地化；非 SwiftUI 场景用 L10n.t("中文") 包一层。
  · 因此词条表可以从源码自动提取，避免手写 key 漏项；英文译文集中在 Scripts/i18n_en.json 便于评审与增量补齐。

用法：
  python3 Scripts/gen_localizable.py            # 生成 Localizable.xcstrings
  python3 Scripts/gen_localizable.py --check    # 只校验（selftest 用）：打印统计并以非 0 退出表示有问题
"""

import json
import os
import re
import sys
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "MetriBar", "Localizable.xcstrings")
I18N = os.path.join(ROOT, "Scripts", "i18n_en.json")

# 中日韩统一表意文字 + 中文标点(CJK Symbols and Punctuation) + 全角符号
CJK = re.compile(r"[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]")
# 含 Swift 插值的字面量无法直接作为 key（SwiftUI 会转成 %lld/%@ 占位），单独统计
INTERP = re.compile(r"\\\(")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def source_files():
    files = glob.glob(os.path.join(ROOT, "MetriBar", "**", "*.swift"), recursive=True)
    # 测试台只在 --uitest 下运行，从不展示给用户，不参与本地化
    return [f for f in sorted(files) if not f.endswith("UITestHarness.swift")]


def strip_comments(src):
    """去掉 // 与 /* */ 注释（字符串字面量内部的不动）。

    必要性：本工程注释里大量出现带引号的中文（如 // 若菜单栏"少了东西"），
    直接正则提取会把这些**注释文案**当成词条收进词条表。
    """
    out, i, n = [], 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:          # 转义字符整体带走
                out.append(src[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c); i += 1
    return "".join(out)


def swift_literals(src):
    r"""产出源码中**真正的**字符串字面量（不含插值内部的嵌套串，也不含被插值打断的碎片）。

    为什么不能直接用正则：`"...\(expr ?? "fallback")..."` 这种嵌套引号会把正则切断，
    产生 ")），已停止" 之类的碎片假键。这里做一次小型词法扫描：遇到 \( 就跳过整个插值表达式
    （平衡括号，并跳过其中的字符串）。
    """
    out, i, n = [], 0, len(src)
    while i < n:
        if src[i] != '"':
            i += 1
            continue
        buf, j, has_interp = [], i + 1, False
        while j < n:
            ch = src[j]
            if ch == "\\":
                if j + 1 < n and src[j + 1] == "(":          # 插值开始
                    has_interp = True
                    j += 2
                    depth = 1
                    while j < n and depth > 0:
                        cj = src[j]
                        if cj == '"':                        # 插值内部的字符串，整体跳过
                            j += 1
                            while j < n and src[j] != '"':
                                if src[j] == "\\":
                                    j += 1
                                j += 1
                            j += 1
                            continue
                        if cj == "(":
                            depth += 1
                        elif cj == ")":
                            depth -= 1
                        j += 1
                    continue
                # 按 Swift 语义解码：catalog 的 key 是**运行期字符串值**，
                # 所以 \\ → \、\n → 真换行；正则串里的 \s 也还原成单反斜杠。
                esc = src[j + 1] if j + 1 < n else ""
                simple = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                          "\\": "\\", "\"": "\"", "'": "'"}
                if esc == "u" and j + 2 < n and src[j + 2] == "{":      # \u{1F600}
                    k = src.find("}", j + 3)
                    if k > 0:
                        if let := int(src[j + 3:k], 16):
                            buf.append(chr(let))
                        j = k + 1
                        continue
                buf.append(simple.get(esc, "\\" + esc))
                j += 2
                continue
            if ch == '"':
                j += 1
                break
            buf.append(ch)
            j += 1
        if not has_interp:
            out.append("".join(buf))
        i = j
    return out


def extract():
    """返回 {字面量: {出现的文件}}，仅含带中文的、可作 key 的字面量（已剔除注释与插值）。"""
    found, skipped_interp = {}, set()
    for path in source_files():
        src = strip_comments(open(path, encoding="utf-8").read())
        rel = os.path.relpath(path, ROOT)
        for lit in swift_literals(src):
            if not CJK.search(lit):
                continue
            found.setdefault(lit, set()).add(rel)
    return found, skipped_interp


def load_i18n():
    with open(I18N, encoding="utf-8") as fh:
        data = json.load(fh)
    skip = set(data.pop("_skip", []))
    notes = data.pop("_notes", None)
    return data, skip, notes


def build_catalog(found, translations, skip):
    strings = {}
    for lit in sorted(found):
        if lit in skip:
            continue
        entry = {"extractionState": "manual"}
        en = translations.get(lit)
        if en:
            entry["localizations"] = {"en": {"stringUnit": {"state": "translated", "value": en}}}
        strings[lit] = entry
    catalog = {
        "sourceLanguage": "zh-Hans",
        "strings": strings,
        "version": "1.0",
    }
    return catalog


def main():
    check_only = "--check" in sys.argv
    found, skipped_interp = extract()
    translations, skip, _ = load_i18n()
    catalog = build_catalog(found, translations, skip)

    keys = set(catalog["strings"])
    with_en = {k for k, v in catalog["strings"].items() if "localizations" in v}
    missing_en = sorted(keys - with_en)
    stale = sorted(set(translations) - keys)          # 译文表里有、源码里已没有
    stale_skip = sorted(skip - set(found))            # 排除表里有、源码里已没有

    print(f"源码中文字面量 : {len(found)} 条（另跳过 {len(skipped_interp)} 条含插值的）")
    print(f"词条表收录     : {len(keys)} 条（已排除日志/调试 {len(skip & set(found))} 条）")
    print(f"已有英文译文   : {len(with_en)} 条（覆盖 {len(with_en) * 100 // max(len(keys), 1)}%）")
    print(f"待补英文       : {len(missing_en)} 条")
    if stale:
        print(f"⚠️ 译文表过期   : {len(stale)} 条（源码已无此串）: {stale[:5]}")
    if stale_skip:
        print(f"⚠️ 排除表过期   : {len(stale_skip)} 条: {stale_skip[:5]}")
    if missing_en:
        print("   待补清单（前 40 条）:")
        for k in missing_en[:40]:
            print("     -", k if len(k) <= 60 else k[:57] + "…")

    if check_only:
        problems = []
        if stale:
            problems.append(f"译文表有过期条目 {len(stale)} 条")
        if stale_skip:
            problems.append(f"排除表有过期条目 {len(stale_skip)} 条")
        if problems:
            print("✗ i18n 校验失败: " + "；".join(problems))
            return 1
        print("✓ i18n 校验通过（词条表与源码同步）")
        return 0

    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    with open(CATALOG, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"✓ 已写出 {os.path.relpath(CATALOG, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
