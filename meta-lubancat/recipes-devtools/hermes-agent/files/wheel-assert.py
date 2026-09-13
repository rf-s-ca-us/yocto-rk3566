#!/usr/bin/env python3
"""wheel 覆盖门禁:对 uv export 的需求集逐条分类。

口径与 2026-09-13 P0 探针一致(CPython 3.11 + linux-aarch64 + glibc):
- cp311 / cp3x(x<=11) / py3 系标签 × (manylinux|linux) aarch64 → native wheel,可装
- py3 系 × any → pure wheel,可装
- musllinux 单列统计,不作可用(glibc 目标的选择器不会选它)
- 仅 sdist → 下载解包扫原生信号;无信号 = 纯 Python sdist,放行进 pure-sdist.txt

uv 0.12.13 的 export 没有 --python-platform/--python-version(本地 uv.exe 实证,
help 只有 -p/--python),导出的是全平台通用需求集:行内保留 PEP 508 marker,
由安装步的 uv pip install --python-platform aarch64-unknown-linux-gnu
--python-version 3.11 按目标环境求值取舍。本门禁对同一批行做同样的 marker
求值(见下方 TARGET 环境常量),marker 排除的行不计入覆盖统计;求值不动的
marker(语法不认识/变量不在环境表内)一律保守视为"适用",只紧不松。

退出码:native-sdist(或完全无文件)计数非 0 时为 1——即"构建期不跑目标机代码"的门。
"""
import json
import os
import re
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

PYPI = "https://pypi.org/pypi/{name}/{version}/json"

# 断言目标环境:与 do_compile 安装步的 --python-version 3.11 +
# --python-platform aarch64-unknown-linux-gnu(glibc)及 pyvenv.cfg(3.11.16)对齐
TARGET = {
    "os_name": "posix",
    "sys_platform": "linux",
    "platform_system": "Linux",
    "platform_machine": "aarch64",
    "platform_python_implementation": "CPython",
    "python_implementation": "CPython",  # 旧写法别名
    "implementation_name": "cpython",
    "implementation_version": "3.11.16",
    "python_version": "3.11",
    "python_full_version": "3.11.16",
    "platform_release": "",  # glibc 目标不含 'android' 字样,'x not in platform_release' 恒真
    "platform_version": "",
}

_TOKEN = re.compile(
    r"""\s*(?:
        (?P<lparen>\() | (?P<rparen>\)) |
        (?P<op>==|!=|<=|>=|<|>) |
        (?P<str>'[^']*'|"[^"]*") |
        (?P<word>[A-Za-z_][A-Za-z0-9_.]*)
    )""",
    re.VERBOSE,
)

def _tok(marker):
    out, pos = [], 0
    while pos < len(marker):
        m = _TOKEN.match(marker, pos)
        if not m:
            if marker[pos:].strip() == "":
                break
            raise ValueError(f"无法 tokenize: {marker[pos:]!r}")
        pos = m.end()
        for k in ("lparen", "rparen", "op", "str", "word"):
            if m.group(k) is not None:
                out.append((k, m.group(k)))
                break
    return out

def _num_tuple(s):
    """版本串转数值元组(点分段取数字),用于 marker 的 <,>= 等数值比较。"""
    parts = []
    for p in s.split("."):
        m = re.match(r"\d+", p)
        parts.append(int(m.group()) if m else 0)
    return tuple(parts)

def _atom_value(tok):
    kind, val = tok
    if kind == "str":
        return val[1:-1]
    if kind == "word":
        if val in TARGET:
            return TARGET[val]
        raise ValueError(f"未知 marker 变量: {val}")
    raise ValueError(f"期望值,得到 {tok}")

def _cmp(left, op, right):
    # 通配符仅 uv/PEP508 的 == 'X.Y.*' 与 != 形态;其余带通配符的比较不认识,交给上层保守处理
    if right.endswith(".*") or left.endswith(".*"):
        if op == "==":
            return left.startswith(right[:-2]) if right.endswith(".*") else right.startswith(left[:-2])
        if op == "!=":
            return not (left.startswith(right[:-2]) if right.endswith(".*") else right.startswith(left[:-2]))
        raise ValueError(f"不支持的通配符比较: {left} {op} {right}")
    if op == "==":
        return left == right
    if op == "!=":
        return left != right
    l, r = _num_tuple(left), _num_tuple(right)
    n = max(len(l), len(r))
    l += (0,) * (n - len(l))
    r += (0,) * (n - len(r))
    return {"<": l < r, ">": l > r, "<=": l <= r, ">=": l >= r}[op]

class _Parser:
    def __init__(self, toks):
        self.toks, self.i = toks, 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self):
        t = self.peek()
        self.i += 1
        return t

    def expr(self):
        v = self.and_expr()
        while self.peek() == ("word", "or"):
            self.take()
            r = self.and_expr()
            v = v or r
        return v

    def and_expr(self):
        v = self.unit()
        while self.peek() == ("word", "and"):
            self.take()
            r = self.unit()
            v = v and r
        return v

    def unit(self):
        if self.peek()[0] == "lparen":
            self.take()
            v = self.expr()
            if self.take()[0] != "rparen":
                raise ValueError("括号不配对")
            return v
        left = _atom_value(self.take())
        kind, val = self.take()
        if kind == "word" and val == "in":
            return left in _atom_value(self.take())
        if kind == "word" and val == "not":
            k2, v2 = self.take()
            if not (k2 == "word" and v2 == "in"):
                raise ValueError("期望 'not in'")
            return left not in _atom_value(self.take())
        if kind != "op":
            raise ValueError(f"期望比较符,得到 {val}")
        return _cmp(left, val, _atom_value(self.take()))

def marker_applies(marker):
    """marker 对目标环境是否成立;解析不了 → True(保守:当作适用,门只会更严)。"""
    marker = marker.strip()
    if not marker:
        return True
    try:
        return bool(_Parser(_tok(marker)).expr())
    except Exception:
        return True

def _py_tag_ok(py):
    """py 标签是否兼容目标 CPython 3.11:py3/py2.py3 通配;py3x/cp3x 的 x<=11
    (abi3 与 py3x wheel 均前向兼容,如 psutil 的 cp36-abi3-manylinux2014_aarch64)。"""
    if py in ("py3", "py2.py3"):
        return True
    m = re.fullmatch(r"(cp|py)3(\d{1,2})", py)
    return bool(m) and int(m.group(2)) <= 11

def wheel_kind(fname):
    m = re.search(r"-([^-]+)-([^-]+)-([^-]+)\.whl$", fname)
    if not m:
        return None
    py, abi, plat = m.groups()
    if not _py_tag_ok(py) or abi not in ("none", "abi3", "cp311"):
        return None
    tags = plat.split(".")
    if any("musllinux" in t and "aarch64" in t for t in tags):
        return "musl"
    if any(t == "any" for t in tags):
        return "pure"
    if any(("manylinux" in t or t.startswith("linux")) and "aarch64" in t for t in tags):
        return "native"
    return None

def sdist_native_signal(url):
    """返回原生信号描述(有 = 阻断),None = 验明纯 Python。"""
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    fd, tmp = tempfile.mkstemp(suffix=".tar.gz")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        with tarfile.open(tmp) as t:
            for m in t.getmembers():
                if not m.isfile():
                    continue
                low = m.name.lower()
                if low.endswith((".so", ".pyd", ".pyx")) or low.endswith("cargo.toml"):
                    return f"binary/extension file {m.name}"
                if low.endswith(("setup.py", "pyproject.toml")):
                    text = t.extractfile(m).read().decode("utf-8", "replace").lower()
                    for hint in ("ext_modules", "maturin", "setuptools-rust", "cython", "cffi"):
                        if hint in text:
                            return f"native build signal '{hint}' in {m.name}"
    finally:
        os.unlink(tmp)
    return None

def entries(req_path):
    """[(spec 行, marker)]:只取顶层行;hash/注释续行不参与分类。"""
    out = []
    for raw in req_path.read_text().splitlines():
        if raw.startswith((" ", "\t")):
            continue
        line = raw.strip()
        if not line or line.startswith(("#", "-")):
            continue
        marker = ""
        if ";" in line:
            line, marker = line.split(";", 1)
            marker = marker.strip().rstrip("\\").strip()
        line = line.strip().rstrip("\\").strip()
        out.append((line, marker))
    return out

def main():
    req = Path(sys.argv[1])
    out = req.parent / "pure-sdist.txt"
    stats = {"native": 0, "pure": 0, "musl": 0, "pure_sdist": 0, "blocked": 0, "marker_skip": 0}
    allowed = []
    for line, marker in entries(req):
        if not marker_applies(marker):
            stats["marker_skip"] += 1
            print(f"MARKER-SKIP(目标环境不适用): {line} ; {marker}")
            continue
        spec = line.split(" ")[0]
        name, _, version = spec.partition("==")
        if not version:
            continue
        with urllib.request.urlopen(PYPI.format(name=name, version=version), timeout=60) as r:
            info = json.load(r)
        kinds = set()
        for u in info["urls"]:
            k = wheel_kind(u["filename"])
            if k:
                kinds.add(k)
        if "native" in kinds or "pure" in kinds:
            stats["native" if "native" in kinds else "pure"] += 1
            continue
        if "musl" in kinds:
            stats["musl"] += 1
            print(f"MUSL-ONLY(不可用): {spec}")
            continue
        sd = [u for u in info["urls"] if u["packagetype"] == "sdist"]
        if not sd:
            stats["blocked"] += 1
            print(f"NO-FILES(阻断): {spec}")
            continue
        reason = sdist_native_signal(sd[0]["url"])
        if reason:
            stats["blocked"] += 1
            print(f"NATIVE-SDIST(阻断): {spec} — {reason}")
        else:
            stats["pure_sdist"] += 1
            allowed.append(spec)
    out.write_text("".join(s + "\n" for s in allowed))
    print("wheel 覆盖统计:", stats)
    if stats["blocked"]:
        sys.exit(1)

if __name__ == "__main__":
    main()
