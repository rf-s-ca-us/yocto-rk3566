#!/usr/bin/env python3
"""RK3566 NPU 视觉小站主程序。

链路:帧源(camera/dir/synthetic) -> 检测后端(rknn/fake/none)
     -> 事件引擎(目标类别 + 冷却 + 快照落盘 + 通知钩子)
     -> 预览服务(MJPEG + /health)

板上正式形态跑在 Podman 容器里(见 ../container/Containerfile);
host 上可用 synthetic + fake 做无硬件冒烟:
  python3 vision_station.py --source synthetic --detector fake \
      --bind 127.0.0.1 --port 8090 --snapshot-dir /tmp/vs-snaps
"""
import argparse
import base64
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from events import EventEngine, event_to_json
from postprocess import Detection, decode, letterbox
from server import FrameStore, make_server

# 1x1 透明 JPEG:host 无 cv2 时 synthetic 源与编码兜底用,仅为打通链路。
_PLACEHOLDER_JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////"
    "2wBDAf//////////////////////////////////////////////////////////////////////////////////////"
    "wAARCAABAAEDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAA"
    "AAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AvwEf/9k=")


def encode_jpeg(frame_rgb: np.ndarray) -> bytes:
    """RGB 帧 -> JPEG 字节。有 cv2 用 cv2,否则返回占位图(host 冒烟)。"""
    try:
        import cv2
        ok, buf = cv2.imencode(".jpg", frame_rgb[:, :, ::-1])
        if ok:
            return buf.tobytes()
    except ImportError:
        pass
    return _PLACEHOLDER_JPEG


def draw_boxes(frame_rgb: np.ndarray, detections: list[Detection]) -> np.ndarray:
    """在帧上画框(需要 cv2);无 cv2 时原样返回。"""
    try:
        import cv2
    except ImportError:
        return frame_rgb
    out = frame_rgb.copy()
    for d in detections:
        cv2.rectangle(out, (int(d.x1), int(d.y1)), (int(d.x2), int(d.y2)),
                      (0, 255, 0), 2)
        cv2.putText(out, f"{d.label} {d.score:.2f}",
                    (int(d.x1), max(0, int(d.y1) - 5)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
    return out


class SyntheticSource:
    """生成渐变测试帧(1280x720),host 冒烟用。"""

    def __init__(self) -> None:
        self._i = 0

    def read(self) -> np.ndarray:
        self._i += 1
        frame = np.zeros((720, 1280, 3), dtype=np.uint8)
        frame[:, :, 0] = (self._i * 3) % 255
        frame[:, :, 1] = np.linspace(0, 255, 1280, dtype=np.uint8)[None, :]
        frame[:, :, 2] = 128
        return frame


class DirSource:
    """循环播放目录里的图片文件(需要 cv2 读图),离线调试用。"""

    def __init__(self, path: str) -> None:
        import cv2
        self._cv2 = cv2
        self._files = sorted(
            os.path.join(path, n) for n in os.listdir(path)
            if n.lower().endswith((".jpg", ".jpeg", ".png")))
        if not self._files:
            raise SystemExit(f"目录里没有图片:{path}")
        self._i = 0

    def read(self) -> np.ndarray:
        img = self._cv2.imread(self._files[self._i % len(self._files)])
        self._i += 1
        return img[:, :, ::-1]


class CameraSource:
    """USB UVC 摄像头(V4L2),板上正式帧源。"""

    def __init__(self, device: int = 0) -> None:
        import cv2
        self._cv2 = cv2
        self._cap = cv2.VideoCapture(device, cv2.CAP_V4L2)
        if not self._cap.isOpened():
            raise SystemExit(f"打不开摄像头 /dev/video{device}")
        self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

    def read(self) -> np.ndarray:
        ok, img = self._cap.read()
        if not ok:
            raise RuntimeError("摄像头读帧失败")
        return img[:, :, ::-1]


class RknnDetector:
    """RKNN 推理后端(rknn-toolkit-lite2),仅板上可用。"""

    def __init__(self, model_path: str, conf_thresh: float = 0.25) -> None:
        from rknnlite.api import RKNNLite
        self._rknn = RKNNLite()
        if self._rknn.load_rknn(model_path) != 0:
            raise SystemExit(f"RKNN 模型加载失败:{model_path}")
        if self._rknn.init_runtime() != 0:
            raise SystemExit("RKNN 运行时初始化失败(NPU 驱动/设备节点?)")
        self._conf = conf_thresh

    def detect(self, frame_rgb: np.ndarray) -> list[Detection]:
        inp = letterbox(frame_rgb)[None, :, :, :]
        outputs = self._rknn.inference(inputs=[inp])
        h, w = frame_rgb.shape[:2]
        return decode(outputs[0], w, h, conf_thresh=self._conf)


class FakeDetector:
    """固定返回一个 person 框,host 端到端冒烟用。"""

    def detect(self, frame_rgb: np.ndarray) -> list[Detection]:
        h, w = frame_rgb.shape[:2]
        return [Detection(w * 0.3, h * 0.2, w * 0.6, h * 0.9, 0.99, 0)]


class NullDetector:
    def detect(self, frame_rgb: np.ndarray) -> list[Detection]:
        return []


def load_config(path: str | None) -> dict:
    cfg = {
        "source": "camera",
        "camera_device": 0,
        "image_dir": "",
        "detector": "rknn",
        "model": "",
        "conf_thresh": 0.25,
        "target_labels": ["person", "cat", "dog"],
        "cooldown_s": 60,
        "max_snapshots": 200,
        "snapshot_dir": "/data/snapshots",
        "notify_cmd": "",
        "bind": "0.0.0.0",
        "port": 8090,
        "max_fps": 10,
    }
    if path:
        with open(path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser(description="RK3566 NPU 视觉小站")
    ap.add_argument("--config", default="")
    ap.add_argument("--source", choices=["camera", "dir", "synthetic"])
    ap.add_argument("--detector", choices=["rknn", "fake", "none"])
    ap.add_argument("--model", default="")
    ap.add_argument("--image-dir", default="")
    ap.add_argument("--snapshot-dir", default="")
    ap.add_argument("--bind", default="")
    ap.add_argument("--port", type=int, default=0)
    args = ap.parse_args()

    cfg = load_config(args.config or None)
    for key, val in [("source", args.source), ("detector", args.detector),
                     ("model", args.model), ("image_dir", args.image_dir),
                     ("snapshot_dir", args.snapshot_dir),
                     ("bind", args.bind)]:
        if val:
            cfg[key] = val
    if args.port:
        cfg["port"] = args.port

    if cfg["source"] == "camera":
        source = CameraSource(int(cfg["camera_device"]))
    elif cfg["source"] == "dir":
        source = DirSource(cfg["image_dir"])
    else:
        source = SyntheticSource()

    if cfg["detector"] == "rknn":
        detector = RknnDetector(cfg["model"], float(cfg["conf_thresh"]))
    elif cfg["detector"] == "fake":
        detector = FakeDetector()
    else:
        detector = NullDetector()

    engine = EventEngine(
        snapshot_dir=cfg["snapshot_dir"],
        target_labels=tuple(cfg["target_labels"]),
        cooldown_s=float(cfg["cooldown_s"]),
        max_snapshots=int(cfg["max_snapshots"]),
        notify_cmd=cfg["notify_cmd"] or None,
    )
    store = FrameStore()
    server = make_server(cfg["bind"], int(cfg["port"]), store, engine.status)
    import threading
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"视觉小站已启动:http://{cfg['bind']}:{cfg['port']} "
          f"(source={cfg['source']}, detector={cfg['detector']})",
          flush=True)

    min_interval = 1.0 / max(1, int(cfg["max_fps"]))
    while True:
        t0 = time.time()
        frame = source.read()
        detections = detector.detect(frame)
        annotated = draw_boxes(frame, detections)
        jpeg = encode_jpeg(annotated)
        store.put(jpeg)
        event = engine.process(detections, jpeg)
        if event:
            print(f"事件:{event_to_json(event)}", flush=True)
        elapsed = time.time() - t0
        if elapsed < min_interval:
            time.sleep(min_interval - elapsed)


if __name__ == "__main__":
    raise SystemExit(main())
