#!/usr/bin/env python3
"""QQ 适配层的跨文件符号校验。

在没有 Swift 编译器的机器上，用它替代一部分编译期检查：

1. `QQModelAdapter.<name>` 的调用点，必须在 QQModelAdapter 里有对应 static func。
2. `client.<name>` 的调用点，必须在 QQMusicClient 里有对应方法。
3. `QQIDRegistry.shared.<name>` 的调用点，必须在 QQIDRegistry 里有对应方法。
4. `QQMusicAPI` 的每个 `qq.<name>` 调用点必须在 QQMusicAPI 中定义。
5. NeteaseAPI 三个文件里每个 `qq.x(...)` 的实参标签，必须与 QQMusicAPI 形参标签一致。
6. 顶层声明的类型名不可重复。

退出码 0 = 通过。
"""

from __future__ import annotations

import collections
import pathlib
import re
import sys

NETWORKING = pathlib.Path("MeloX/Core/Networking")
QQ_FILES = [
    "QQMusicClient.swift",
    "QQWireModels.swift",
    "QQModelAdapter.swift",
    "QQIDRegistry.swift",
    "QQMusicAPI.swift",
    "QQMusicBackend.swift",
    "QQMateMirror.swift",
    "PlaybackURLNormalizer.swift",
    "QQSongLibraryCache.swift",
]
PATCHED_FILES = [
    "NeteaseAPI.swift",
    "NeteaseAPI+Home.swift",
    "NeteaseAPI+SearchSuggestions.swift",
]


def read(name: str) -> str:
    return (NETWORKING / name).read_text(encoding="utf-8")


def methods_of(source: str, *, static: bool | None = None) -> set[str]:
    pattern = r"^\s+(static\s+)?func\s+(\w+)"
    found: set[str] = set()
    for match in re.finditer(pattern, source, re.MULTILINE):
        is_static = match.group(1) is not None
        if static is None or static == is_static:
            found.add(match.group(2))
    return found


def labels_of(source: str, name: str) -> list[str]:
    """抓取 `func name(` 后到匹配右括号之间的实参标签。"""
    pattern = rf"^\s+func\s+{re.escape(name)}\s*\("
    match = re.search(pattern, source, re.MULTILINE)
    if not match:
        return []
    start = match.end() - 1
    depth = 0
    index = start
    while index < len(source):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                break
        index += 1
    body = source[start + 1:index]
    # 去掉参数默认值里的括号内容，粗暴但足够
    body = re.sub(r"\([^)]*\)", "", body)
    body = re.sub(r"\[[^\]]*\]", "", body)
    labels: list[str] = []
    for part in body.split(","):
        part = part.strip()
        if not part:
            continue
        head = part.split(":")[0].strip()
        tokens = head.split()
        if not tokens:
            continue
        if len(tokens) >= 2:
            labels.append(tokens[0])
        else:
            labels.append("_")
    return labels


def main() -> int:
    failures = 0
    sources = {name: read(name) for name in QQ_FILES}
    patched = {name: read(name) for name in PATCHED_FILES}

    adapter_source = sources["QQModelAdapter.swift"]
    client_source = sources["QQMusicClient.swift"]
    registry_source = sources["QQIDRegistry.swift"]
    api_source = sources["QQMusicAPI.swift"]

    adapter_static = methods_of(adapter_source, static=True)
    client_methods = methods_of(client_source)
    registry_methods = methods_of(registry_source)
    api_methods = methods_of(api_source)

    consumers = list(sources.values()) + list(patched.values())
    all_text = "\n".join(consumers)

    # 1) QQModelAdapter.*
    used_adapter = set(re.findall(r"\bQQModelAdapter\.(\w+)\s*\(", all_text))
    missing = sorted(used_adapter - adapter_static)
    if missing:
        print(f"FAIL QQModelAdapter 未定义: {', '.join(missing)}")
        failures += 1
    else:
        print(f"PASS QQModelAdapter 符号全部存在 ({len(used_adapter)} 个)")

    # 2) client.*
    used_client = set(re.findall(r"\bclient\.(\w+)\s*\(", api_source))
    skipped = {"data", "decode", "decodeIfPresent", "container"}
    missing = sorted(used_client - client_methods - skipped)
    if missing:
        print(f"FAIL QQMusicClient 未定义: {', '.join(missing)}")
        failures += 1
    else:
        print(f"PASS QQMusicClient 符号全部存在 ({len(used_client - skipped)} 个)")

    # 3) QQIDRegistry.shared.*
    used_registry = set(re.findall(r"QQIDRegistry\.shared\.(\w+)\s*\(", all_text))
    missing = sorted(used_registry - registry_methods)
    if missing:
        print(f"FAIL QQIDRegistry 未定义: {', '.join(missing)}")
        failures += 1
    else:
        print(f"PASS QQIDRegistry 符号全部存在 ({len(used_registry)} 个)")

    # 4) qq.* 方法存在性
    used_qq = set(re.findall(r"\bqq\.(\w+)\s*\(", "\n".join(patched.values())))
    missing = sorted(used_qq - api_methods)
    if missing:
        print(f"FAIL QQMusicAPI 未定义: {', '.join(missing)}")
        failures += 1
    else:
        print(f"PASS QQMusicAPI 分流方法全部存在 ({len(used_qq)} 个)")

    # 5) qq.x(...) 实参标签与形参标签一致性
    label_mismatch = 0
    for source_name, text in patched.items():
        for match in re.finditer(r"\bqq\.(\w+)\s*\(([^)]*)\)", text):
            method = match.group(1)
            arguments = match.group(2).strip()
            expected = labels_of(api_source, method)
            if not expected:
                continue
            actual: list[str] = []
            if arguments:
                depth = 0
                current = ""
                for char in arguments:
                    if char in "([":
                        depth += 1
                    elif char in ")]":
                        depth -= 1
                    if char == "," and depth == 0:
                        actual.append(current)
                        current = ""
                    else:
                        current += char
                if current.strip():
                    actual.append(current)
            actual_labels = [chunk.split(":")[0].strip() for chunk in actual if chunk.strip()]
            # 允许全位置实参（无标签）——只要数量不超过形参即可
            has_labels = any(":" in chunk for chunk in actual)
            if has_labels and len(actual_labels) > len(expected):
                print(
                    f"FAIL {source_name}: qq.{method} 传入 {len(actual_labels)} 个实参，"
                    f"形参只有 {len(expected)} 个"
                )
                label_mismatch += 1
                continue
            if has_labels:
                for index, label in enumerate(actual_labels):
                    if index >= len(expected):
                        break
                    allowed = {expected[index], "_"}
                    if label not in allowed and expected[index] != "_":
                        print(
                            f"FAIL {source_name}: qq.{method} 第 {index + 1} 个实参标签 "
                            f"'{label}'，形参为 '{expected[index]}'"
                        )
                        label_mismatch += 1
    if label_mismatch == 0:
        print("PASS qq 调用实参标签与形参一致")
    else:
        failures += 1

    # 6) 顶层类型名重复
    declarations: collections.Counter[str] = collections.Counter()
    locations: dict[str, list[str]] = collections.defaultdict(list)
    for name, source in sources.items():
        for line_no, line in enumerate(source.splitlines(), 1):
            match = re.match(
                r"^(?:nonisolated\s+)?(?:private\s+)?(?:final\s+)?(struct|enum|class)\s+(\w+)",
                line,
            )
            if match:
                declarations[match.group(2)] += 1
                locations[match.group(2)].append(f"{name}:{line_no}")
    duplicates = {k: v for k, v in declarations.items() if v > 1}
    if duplicates:
        for key in duplicates:
            print(f"FAIL 顶层类型重复: {key} -> {locations[key]}")
        failures += 1
    else:
        print(f"PASS 顶层类型无重复 ({len(declarations)} 个)")

    print(f"RESULT {'PASS' if failures == 0 else 'FAIL'} failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
