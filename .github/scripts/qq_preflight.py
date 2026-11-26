#!/usr/bin/env python3
"""QQ 适配层编译前预检：括号平衡、分流守卫计数、方法覆盖交叉校验。

在 CI 里早失败，避免等 xcodebuild 跑十几分钟才报一个括号错误。
退出码 0 = 通过，1 = 失败。
"""

from __future__ import annotations

import pathlib
import re
import sys

NETWORKING = pathlib.Path("MeloX/Core/Networking")

REQUIRED_QQ_FILES = [
    "QQMusicClient.swift",
    "QQWireModels.swift",
    "QQModelAdapter.swift",
    "QQIDRegistry.swift",
    "QQMusicAPI.swift",
    "QQMusicBackend.swift",
    "QQMateMirror.swift",
    "PlaybackURLNormalizer.swift",
]

PATCHED_FILES = [
    "NeteaseAPI.swift",
    "NeteaseAPI+Home.swift",
    "NeteaseAPI+SearchSuggestions.swift",
]

PAIRS = {")": "(", "}": "{", "]": "["}


def strip_noise(source: str) -> str:
    """去掉字符串字面量与注释，避免括号统计被内容干扰。"""
    out: list[str] = []
    i = 0
    length = len(source)
    while i < length:
        ch = source[i]
        # 行注释
        if ch == "/" and i + 1 < length and source[i + 1] == "/":
            while i < length and source[i] != "\n":
                i += 1
            continue
        # 块注释
        if ch == "/" and i + 1 < length and source[i + 1] == "*":
            i += 2
            while i + 1 < length and not (source[i] == "*" and source[i + 1] == "/"):
                i += 1
            i += 2
            continue
        # 多行字符串 """
        if source.startswith('"""', i):
            i += 3
            while i < length and not source.startswith('"""', i):
                i += 1
            i += 3
            continue
        # 单行字符串
        if ch == '"':
            i += 1
            while i < length:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    break
                if source[i] == "\n":
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_balance(path: pathlib.Path) -> bool:
    source = strip_noise(path.read_text(encoding="utf-8"))
    opens = {"(": 0, "{": 0, "[": 0}
    ok = True
    for ch in source:
        if ch in opens:
            opens[ch] += 1
        elif ch in PAIRS:
            opens[PAIRS[ch]] -= 1
            if opens[PAIRS[ch]] < 0:
                ok = False
                break
    balanced = ok and all(v == 0 for v in opens.values())
    detail = " ".join(f"{k}{opens[k]:+d}" if opens[k] else f"{k}ok" for k in "({[")
    print(f"{'PASS' if balanced else 'FAIL'} balance {path} [{detail}]")
    return balanced


def main() -> int:
    if not NETWORKING.is_dir():
        print(f"FAIL missing directory {NETWORKING}")
        return 1

    failures = 0

    for name in REQUIRED_QQ_FILES:
        path = NETWORKING / name
        if not path.exists():
            print(f"FAIL missing {path}")
            failures += 1
            continue
        size = path.stat().st_size
        print(f"PASS exists {path} ({size} bytes)")
        if not check_balance(path):
            failures += 1

    for name in PATCHED_FILES:
        path = NETWORKING / name
        if not path.exists():
            print(f"FAIL missing {path}")
            failures += 1
            continue
        if not check_balance(path):
            failures += 1

    # 分流守卫：每个被改造的方法入口应有一处 QQMusicBackend.enabled
    guard_total = 0
    for name in PATCHED_FILES:
        path = NETWORKING / name
        if not path.exists():
            continue
        guards = path.read_text(encoding="utf-8").count("QQMusicBackend.enabled")
        guard_total += guards
        print(f"INFO guards {name}: {guards}")

    if guard_total < 20:
        print(f"FAIL guard count too low: {guard_total} (expected >= 20)")
        failures += 1
    else:
        print(f"PASS guard count {guard_total}")

    # 调用点 / 方法定义交叉校验
    api_path = NETWORKING / "QQMusicAPI.swift"
    if api_path.exists():
        api_src = api_path.read_text(encoding="utf-8")
        defined = set(re.findall(r"^\s{4}func\s+(\w+)", api_src, re.MULTILINE))
        called: set[str] = set()
        for name in PATCHED_FILES:
            path = NETWORKING / name
            if not path.exists():
                continue
            called |= set(re.findall(r"\bqq\.(\w+)\s*\(", path.read_text(encoding="utf-8")))

        missing = sorted(called - defined)
        if missing:
            print(f"FAIL qq.<method> called but not defined: {', '.join(missing)}")
            failures += 1
        else:
            print(f"PASS qq call sites covered: {len(called)} methods")

    print(f"RESULT {'PASS' if failures == 0 else 'FAIL'} failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
