#!/usr/bin/env python3
"""wheel 覆盖门禁:对 uv export 的 aarch64 需求集逐条分类。

口径与 2026-09-13 P0 探针一致(CPython 3.11 + linux-aarch64 + glibc):
- cp311 / cp3x(x<=11) / py3 系标签 × (manylinux|linux) aarch64 → native wheel,可装
- py3 系 × any → pure wheel,可装
- musllinux 单列统计,不作可用(glibc 目标的选择器不会选它)
- 仅 sdist → 下载解包扫原生信号;无信号 = 纯 Python sdist,放行进 pure-sdist.txt

退出码:native-sdist(或完全无文件)计数非 0 时为 1——即"构建期不跑目标机代码"的门。
"""
import json
import re
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

PYPI = "https://pypi.org/pypi/{name}/{version}/json"
PY_TAGS = {"py3", "py2.py3", "py38", "py39", "py310", "py311", "cp39", "cp310", "cp311"}

def wheel_kind(fname):
    m = re.search(r"-([^-]+)-([^-]+)-([^-]+)\.whl$", fname)
    if not m:
        return None
    py, abi, plat = m.groups()
    if py not in PY_TAGS or abi not in ("none", "abi3", "cp311"):
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
    with tempfile.NamedTemporaryFile(suffix=".tar.gz") as f:
        f.write(data)
        f.flush()
        with tarfile.open(f.name) as t:
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
    return None

def main():
    req = Path(sys.argv[1])
    out = req.parent / "pure-sdist.txt"
    # uv export 的 hash 续行(行尾 \ + 缩进行)归并成逻辑行
    logical = []
    for raw in req.read_text().splitlines():
        if raw.startswith((" ", "\t")) and logical:
            logical[-1] += " " + raw.strip()
        else:
            logical.append(raw)
    stats = {"native": 0, "pure": 0, "musl": 0, "pure_sdist": 0, "blocked": 0}
    allowed = []
    for line in logical:
        line = line.strip()
        if not line or line.startswith(("#", "-")):
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
