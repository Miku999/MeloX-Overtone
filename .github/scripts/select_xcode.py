#!/usr/bin/env python3
"""在 macOS runner 上挑选满足最低 iOS SDK 要求的 Xcode，并切换 xcode-select。

用法：
    python3 .github/scripts/select_xcode.py --min-ios-sdk 27.1

行为：
1. 扫描 /Applications/Xcode*.app，按版本号从高到低排序。
2. 依次 `sudo xcode-select -s`，读取 `xcrun --sdk iphoneos --show-sdk-version`。
3. 第一个满足 SDK 版本 >= 阈值者即选中，打印环境信息并写入 GITHUB_ENV。
4. 全部不满足则打印可用清单与建议，退出 1。

注意：macOS 自带 bash 3.2，没有 mapfile / readarray，所以这段逻辑用 Python 实现。
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys


DEFAULT_PATTERN = "/Applications/Xcode*.app"
PLAIN_XCODE = "/Applications/Xcode.app"


def run(cmd: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        return proc.returncode, (proc.stdout + proc.stderr).strip()
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def parse_version(text: str) -> tuple[int, ...]:
    """把 '27.1' / '27.1.0' / '26' 解析成可比较的元组，尾部 0 去掉。"""
    parts: list[int] = []
    for chunk in text.strip().split("."):
        match = re.match(r"\d+", chunk)
        if not match:
            break
        parts.append(int(match.group(0)))
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts) or (0,)


def version_key(path: str) -> tuple[int, ...]:
    match = re.search(r"Xcode_?(\d+(?:\.\d+)*)", path)
    if not match:
        return (0,)
    return parse_version(match.group(1))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--min-ios-sdk", default="27.1")
    parser.add_argument("--pattern", default=DEFAULT_PATTERN)
    args = parser.parse_args()

    required = parse_version(args.min_ios_sdk)

    candidates = sorted(glob.glob(args.pattern), key=version_key, reverse=True)
    # /Applications/Xcode.app 没有版本号，作为最后的兜底
    if os.path.isdir(PLAIN_XCODE) and PLAIN_XCODE not in candidates:
        candidates.append(PLAIN_XCODE)

    if not candidates:
        print("::error title=No Xcode::找不到任何 Xcode 安装")
        return 1

    print(f"required iOS SDK >= {'.'.join(str(x) for x in required)}")
    print(f"candidates: {len(candidates)}")

    chosen = ""
    chosen_sdk = ""

    for app in candidates:
        developer_dir = os.path.join(app, "Contents", "Developer")
        if not os.path.isdir(developer_dir):
            print(f"skip (no Contents/Developer): {app}")
            continue

        code, _ = run(["sudo", "xcode-select", "-s", developer_dir])
        if code != 0:
            print(f"skip (xcode-select failed): {app}")
            continue

        code, sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"])
        if code != 0 or not sdk:
            print(f"skip (no iphoneos SDK): {app}")
            continue

        sdk_version = parse_version(sdk)
        print(f"candidate: {app} -> iOS SDK {sdk}")

        if sdk_version >= required:
            chosen = app
            chosen_sdk = sdk
            break

    if not chosen:
        print(
            f"::error title=iOS SDK too old::没有找到 iOS SDK >= {args.min_ios_sdk} 的 Xcode。"
            "请把 workflow_dispatch 的 runner 换成带新版 Xcode 的镜像（例如 xcode-27）后重跑。"
        )
        return 1

    developer_dir = os.path.join(chosen, "Contents", "Developer")
    print(f"using Xcode: {chosen} (iOS SDK {chosen_sdk})")

    for cmd in (["xcodebuild", "-version"], ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]):
        code, out = run(cmd)
        print(f"$ {' '.join(cmd)}\n{out}")
        if code != 0:
            print(f"::error::{' '.join(cmd)} failed")
            return 1

    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with open(github_env, "a", encoding="utf-8") as handle:
            handle.write(f"DEVELOPER_DIR={developer_dir}\n")
            handle.write(f"IOS_SDK_VERSION={chosen_sdk}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
