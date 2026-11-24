"""postprocess 主机测试:合成 YOLOv8 输出,断言解码/NMS/letterbox。

跑法:cd vision-station && python3 -m pytest tests/ 或逐个执行本文件。
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from postprocess import decode, letterbox, nms


def make_output(boxes):
    """boxes: [(cx, cy, w, h, cls, score), ...] in 640 letterbox coords."""
    out = np.zeros((1, 84, 8400), dtype=np.float32)
    for i, (cx, cy, w, h, cls, score) in enumerate(boxes):
        out[0, 0, i] = cx
        out[0, 1, i] = cy
        out[0, 2, i] = w
        out[0, 3, i] = h
        out[0, 4 + cls, i] = score
    return out


def test_decode_single_person():
    # 1280x720 帧:letterbox r=0.5, pad_y=(640-360)/2=140
    # 模型坐标 cx=320, cy=320, w=200, h=280 -> 原图 x 240..1040? 换算:
    # x1=(320-100-0)/0.5=440, x2=(320+100)/0.5=840
    # y1=(320-140-140)/0.5=80, y2=(320+140-140)/0.5=640
    out = make_output([(320, 320, 200, 280, 0, 0.9)])
    dets = decode(out, 1280, 720, conf_thresh=0.25)
    assert len(dets) == 1, dets
    d = dets[0]
    assert d.label == "person"
    assert abs(d.x1 - 440) < 1 and abs(d.x2 - 840) < 1
    assert abs(d.y1 - 80) < 1 and abs(d.y2 - 640) < 1
    assert abs(d.score - 0.9) < 1e-6


def test_decode_below_threshold():
    out = make_output([(320, 320, 100, 100, 0, 0.1)])
    assert decode(out, 640, 640, conf_thresh=0.25) == []


def test_decode_empty():
    out = np.zeros((1, 84, 8400), dtype=np.float32)
    assert decode(out, 640, 640) == []


def test_nms_suppresses_overlap_same_class():
    out = make_output([
        (320, 320, 200, 200, 0, 0.9),
        (325, 322, 200, 200, 0, 0.8),  # 与上几乎重合,应被抑制
        (100, 100, 80, 80, 0, 0.7),    # 独立框,保留
        (320, 320, 200, 200, 16, 0.85),  # 同位置但 dog 类,不抑制
    ])
    dets = decode(out, 640, 640, conf_thresh=0.25)
    labels = sorted((d.label, round(d.score, 2)) for d in dets)
    assert labels == [("dog", 0.85), ("person", 0.7), ("person", 0.9)], labels


def test_nms_direct():
    boxes = np.array([[0, 0, 100, 100], [10, 10, 110, 110],
                      [300, 300, 400, 400]], dtype=float)
    scores = np.array([0.9, 0.8, 0.7])
    classes = np.array([0, 0, 0])
    keep = nms(boxes, scores, classes, 0.45)
    assert keep == [0, 2], keep


def test_letterbox_shape_and_padding():
    frame = np.zeros((720, 1280, 3), dtype=np.uint8)
    frame[:, :] = (10, 20, 30)
    out = letterbox(frame, 640)
    assert out.shape == (640, 640, 3)
    # 上下填充带应为 114,中间是原图颜色
    assert (out[0, 0] == [114, 114, 114]).all()
    assert (out[320, 320] == [10, 20, 30]).all()


if __name__ == "__main__":
    test_decode_single_person()
    test_decode_below_threshold()
    test_decode_empty()
    test_nms_suppresses_overlap_same_class()
    test_nms_direct()
    test_letterbox_shape_and_padding()
    print("test_postprocess:全部通过")
