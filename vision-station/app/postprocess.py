"""YOLOv8 检测后处理:解码 + NMS。纯 numpy,host 可测。

输入是模型原始输出 (1, 84, 8400):前 4 通道为 cx, cy, w, h(640x640
letterbox 坐标系),后 80 通道为 COCO 类别分数(无 objectness,YOLOv8
anchor-free 输出)。输出统一为 Detection 列表,坐标已换算回原图。
"""
from dataclasses import dataclass

import numpy as np

COCO_LABELS = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
    "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
    "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
    "sports ball", "kite", "baseball bat", "baseball glove", "skateboard",
    "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork",
    "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
    "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv",
    "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
    "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
    "scissors", "teddy bear", "hair drier", "toothbrush",
]


@dataclass
class Detection:
    x1: float
    y1: float
    x2: float
    y2: float
    score: float
    cls: int

    @property
    def label(self) -> str:
        return COCO_LABELS[self.cls]


def _iou(a: np.ndarray, b: np.ndarray) -> float:
    x1 = max(a[0], b[0])
    y1 = max(a[1], b[1])
    x2 = min(a[2], b[2])
    y2 = min(a[3], b[3])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    area_a = (a[2] - a[0]) * (a[3] - a[1])
    area_b = (b[2] - b[0]) * (b[3] - b[1])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def nms(boxes: np.ndarray, scores: np.ndarray, classes: np.ndarray,
        iou_thresh: float = 0.45) -> list[int]:
    """按类别分别做 NMS,返回保留的下标(按分数降序)。"""
    order = np.argsort(-scores)
    keep: list[int] = []
    suppressed = np.zeros(len(boxes), dtype=bool)
    for idx in order:
        if suppressed[idx]:
            continue
        keep.append(int(idx))
        for other in order:
            if other == idx or suppressed[other]:
                continue
            if classes[other] != classes[idx]:
                continue
            if _iou(boxes[idx], boxes[other]) > iou_thresh:
                suppressed[other] = True
    return keep


def decode(output: np.ndarray, frame_w: int, frame_h: int,
           input_size: int = 640, conf_thresh: float = 0.25,
           iou_thresh: float = 0.45) -> list[Detection]:
    """把 YOLOv8 原始输出解码为原图坐标系下的 Detection 列表。

    letterbox 约定与 preprocess.letterbox 一致:等比缩放后居中填充,
    缩放比 r = input_size / max(frame_w, frame_h),填充在短边两侧均分。
    """
    pred = np.asarray(output)
    if pred.ndim == 3:
        pred = pred[0]
    # (84, N) -> (N, 84)
    pred = pred.T
    boxes_cxcywh = pred[:, :4]
    class_scores = pred[:, 4:]
    classes = np.argmax(class_scores, axis=1)
    scores = class_scores[np.arange(len(pred)), classes]
    mask = scores >= conf_thresh
    if not np.any(mask):
        return []
    boxes_cxcywh = boxes_cxcywh[mask]
    scores = scores[mask]
    classes = classes[mask]

    r = input_size / max(frame_w, frame_h)
    pad_x = (input_size - frame_w * r) / 2.0
    pad_y = (input_size - frame_h * r) / 2.0

    cx, cy, w, h = (boxes_cxcywh[:, i] for i in range(4))
    x1 = (cx - w / 2.0 - pad_x) / r
    y1 = (cy - h / 2.0 - pad_y) / r
    x2 = (cx + w / 2.0 - pad_x) / r
    y2 = (cy + h / 2.0 - pad_y) / r
    boxes = np.stack([x1, y1, x2, y2], axis=1)
    boxes[:, [0, 2]] = np.clip(boxes[:, [0, 2]], 0, frame_w)
    boxes[:, [1, 3]] = np.clip(boxes[:, [1, 3]], 0, frame_h)

    keep = nms(boxes, scores, classes, iou_thresh)
    return [
        Detection(float(boxes[i][0]), float(boxes[i][1]),
                  float(boxes[i][2]), float(boxes[i][3]),
                  float(scores[i]), int(classes[i]))
        for i in keep
    ]


def letterbox(frame: np.ndarray, input_size: int = 640) -> np.ndarray:
    """把 RGB uint8 帧等比缩放并填充到 input_size x input_size。

    优先用 cv2(板上/容器内有),缺失时用 numpy 最近邻兜底(host 冒烟用,
    精度不影响链路验证)。填充值 114 与 YOLO 训练约定一致。
    """
    h, w = frame.shape[:2]
    r = input_size / max(w, h)
    new_w, new_h = int(round(w * r)), int(round(h * r))
    try:
        import cv2
        resized = cv2.resize(frame, (new_w, new_h),
                             interpolation=cv2.INTER_LINEAR)
    except ImportError:
        ys = (np.arange(new_h) / r).astype(int)
        xs = (np.arange(new_w) / r).astype(int)
        resized = frame[ys][:, xs]
    canvas = np.full((input_size, input_size, 3), 114, dtype=np.uint8)
    pad_x = (input_size - new_w) // 2
    pad_y = (input_size - new_h) // 2
    canvas[pad_y:pad_y + new_h, pad_x:pad_x + new_w] = resized
    return canvas
