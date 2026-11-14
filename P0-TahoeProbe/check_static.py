#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
P0-TahoeProbe 静态自检（在 Windows / Linux / macOS 上都能跑，不需要 macOS SDK）。

用途：这份工程是在非 Mac 环境下写的，第一次上真机前，用机械检查先排除
「一定编译不过」和「一定会运行出错」的低级问题，减少来回往返。

检查项：
  1. 源文件编码 / BOM / 换行符（CRLF 会让 bash build.sh 直接失败）
  2. 括号配对（去掉注释与字符串字面量后计数）
  3. 头文件声明的 C 函数与 ObjC 方法，是否能在 .m 中找到实现
  4. build.sh 的 SOURCES 是否齐全
  5. README 里承诺的命令行参数，main.m 是否真的解析 / 提示了
  6. 源码中是否残留了不该用的 API（CGDisplayStream / CGDisplayCreateImage / NSStringFromCGRect）

退出码 0 = 全部通过；1 = 有失败项。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src"

results: list[tuple[bool, str, str]] = []


def report(ok: bool, name: str, detail: str = "") -> None:
    results.append((ok, name, detail))


def strip_literals_and_comments(text: str) -> str:
    """粗粒度去掉 // /* */ "..." '...'，让括号计数不受注释/字符串干扰。"""
    out: list[str] = []
    i, n = 0, len(text)
    state = "code"
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                i += 2
                continue
            if c == '"':
                state = "str"
                i += 1
                continue
            if c == "'":
                state = "char"
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == "line":
            if c == "\n":
                state = "code"
                out.append("\n")
            i += 1
            continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = "code"
                i += 2
                continue
            i += 1
            continue
        # str / char
        if c == "\\":
            i += 2
            continue
        if (state == "str" and c == '"') or (state == "char" and c == "'"):
            state = "code"
        i += 1
    return "".join(out)


def read_text_files():
    files = [ROOT / "build.sh", ROOT / "README.md", ROOT / "run_p0.sh"]
    files += sorted(SRC.glob("*"))
    return [f for f in files if f.is_file()]


def check_encoding() -> None:
    bad = []
    for f in read_text_files():
        raw = f.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            bad.append(f"{f.name}: UTF-8 BOM")
        if b"\r\n" in raw:
            bad.append(f"{f.name}: CRLF")
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError as e:
            bad.append(f"{f.name}: not UTF-8 ({e})")
    report(not bad, "编码 / 换行符", "; ".join(bad) if bad else "全部 UTF-8 无 BOM、纯 LF")


def check_brackets() -> None:
    bad = []
    for f in sorted(SRC.glob("*")):
        if f.suffix not in (".h", ".m"):
            continue
        code = strip_literals_and_comments(f.read_text(encoding="utf-8"))
        for op, cl in (("{", "}"), ("(", ")"), ("[", "]")):
            d = code.count(op) - code.count(cl)
            if d:
                bad.append(f"{f.name}: '{op}{cl}' 差 {d}")
    report(not bad, "括号配对", "; ".join(bad) if bad else "所有 .h/.m 的 {} () [] 平衡")


def declared_c_functions(header: str) -> set[str]:
    # 匹配形如 `NSDictionary * P0SystemInfo(void);` / `void P0Log(...);`
    return set(re.findall(r"^\s*[\w \*<>?,:]+?\b(P0\w+|VD\w+)\s*\(", header, re.M))


def check_declarations() -> None:
    headers = {f.name: f.read_text(encoding="utf-8") for f in SRC.glob("*.h")}
    impls = "\n".join(f.read_text(encoding="utf-8") for f in SRC.glob("*.m"))
    impl_plain = strip_literals_and_comments(impls)

    missing = []
    for hname, htext in headers.items():
        for fn in sorted(declared_c_functions(htext)):
            if not re.search(r"\b" + re.escape(fn) + r"\s*\(", impl_plain):
                missing.append(f"{hname}: {fn}()")
    report(not missing, "C 函数声明→实现", "; ".join(missing) if missing else "所有 P0*/VD* 声明均有实现")

    # ObjC 方法：只检查 @interface 段落（@protocol 里的私有 API 重声明不要求本地实现）。
    missing_m = []
    for hname, htext in headers.items():
        # 先剥注释：CGVirtualDisplaySPI.h 的注释里有「不声明 @interface」字样，
        # 不剥离会把后面的 @protocol 段误当成 @interface。
        clean = strip_literals_and_comments(htext)
        interfaces = "\n".join(re.findall(r"@interface\b[\s\S]*?@end", clean))
        methods = re.findall(r"^\s*[-+]\s*\([^)]*\)\s*(\w+)", interfaces, re.M)
        for m in sorted(set(methods)):
            # 类扩展 / category 里的方法不要求出现在头文件，反过来检查即可
            if not re.search(r"^\s*[-+]\s*\([^)]*\)\s*" + re.escape(m) + r"\b", impl_plain, re.M):
                missing_m.append(f"{hname}: -/{m}")
    report(not missing_m, "ObjC 方法声明→实现", "; ".join(missing_m) if missing_m else "头文件方法均有实现")


def check_sources() -> None:
    build = (ROOT / "build.sh").read_text(encoding="utf-8")
    listed = re.findall(r"^\s*(src/[\w.]+)\s*$", build, re.M)
    missing = [p for p in listed if not (ROOT / p).is_file()]
    report(bool(listed) and not missing, "build.sh SOURCES",
           "缺文件: " + ", ".join(missing) if missing else f"{len(listed)} 个源文件齐全")


def check_args() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    main = (SRC / "main.m").read_text(encoding="utf-8")
    # 两边统一成不带 -- 前缀的参数名
    doc = set(re.findall(r"--([a-z][a-z-]*)", readme))
    code = set(re.findall(r"--([a-z][a-z-]*)", main))
    code |= set(re.findall(r'isEqualToString:@"([a-z][a-z-]*)"', main))
    code |= set(re.findall(r'args\[@"([a-z][a-z-]*)"\]', main))
    # 这些不是本工具的 flag：子命令名、内部 key、README 里的 xcode-select 参数
    noise = {"help", "command", "probe", "capabilities", "verify", "hold", "install"}
    undocumented = sorted((code - doc) - noise)
    ghost = sorted((doc - code) - noise)
    detail = []
    if undocumented:
        detail.append("代码有但 README 未列: " + ", ".join(undocumented))
    if ghost:
        detail.append("README 有但代码未处理: " + ", ".join(ghost))
    report(not detail, "CLI 参数一致性", "; ".join(detail) if detail else "README 与 main.m 参数集合一致")


def check_forbidden_apis() -> None:
    forbidden = ("CGDisplayStream", "CGDisplayCreateImage", "NSStringFromCGRect",
                 "CGWindowListCreateImage")
    hits = []
    for f in sorted(SRC.glob("*.m")):
        code = strip_literals_and_comments(f.read_text(encoding="utf-8"))
        for api in forbidden:
            if api in code:
                hits.append(f"{f.name}: {api}")
    report(not hits, "禁用 API 残留", "; ".join(hits) if hits else "无 CGDisplayStream / 旧截图 API / NSStringFromCGRect")


def main() -> int:
    check_encoding()
    check_brackets()
    check_declarations()
    check_sources()
    check_args()
    check_forbidden_apis()

    for ok, name, detail in results:
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}")
    failed = sum(1 for ok, _, _ in results if not ok)
    print(f"\n{len(results) - failed}/{len(results)} 项通过")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
