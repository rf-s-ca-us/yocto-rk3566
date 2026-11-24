#!/usr/bin/env python3
"""ONNX -> RKNN 转换(RKNN-Toolkit2,x86 host 上运行)。

用法:python3 convert.py <yolov8n.onnx> <target_platform> <out.rknn>

默认 FP 构建,不做 INT8 量化:第一版先证明链路,量化需要校准数据
集,收益(帧率)留到实机测过基线后再评估。
"""
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    onnx_path, target, out_path = sys.argv[1:4]
    try:
        from rknn.api import RKNN
    except ImportError:
        print("缺 rknn-toolkit2:请在装有该工具的 host/容器里运行"
              "(pip install rknn-toolkit2,仅 x86_64 Linux)", file=sys.stderr)
        return 1
    rknn = RKNN(verbose=False)
    rknn.config(mean_values=[[0, 0, 0]], std_values=[[255, 255, 255]],
                target_platform=target)
    if rknn.load_onnx(model=onnx_path) != 0:
        print("load_onnx 失败", file=sys.stderr)
        return 1
    if rknn.build(do_quantization=False) != 0:
        print("build 失败", file=sys.stderr)
        return 1
    if rknn.export_rknn(out_path) != 0:
        print("export_rknn 失败", file=sys.stderr)
        return 1
    rknn.release()
    print(f"已导出 {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
