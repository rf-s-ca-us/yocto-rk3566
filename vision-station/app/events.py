"""事件引擎:目标类别出现 -> 冷却去抖 -> 落盘快照 -> 触发通知钩子。

只依赖标准库 + postprocess.Detection,host 可测。时间由调用方注入
(now 参数),测试不需要等真实时钟。
"""
import json
import os
import subprocess
import time
from dataclasses import dataclass, field

from postprocess import Detection


@dataclass
class Event:
    when: float
    labels: list[str]
    snapshot_path: str | None


@dataclass
class EventEngine:
    snapshot_dir: str
    target_labels: tuple[str, ...] = ("person", "cat", "dog")
    cooldown_s: float = 60.0
    max_snapshots: int = 200
    notify_cmd: str | None = None
    _last_event_at: float = field(default=-1e18, init=False)
    events_fired: int = field(default=0, init=False)

    def process(self, detections: list[Detection], frame_jpeg: bytes | None,
                now: float | None = None) -> Event | None:
        """喂入一帧的检测结果;命中目标且冷却已过时产生事件,否则 None。"""
        if now is None:
            now = time.time()
        hits = [d for d in detections if d.label in self.target_labels]
        if not hits:
            return None
        if now - self._last_event_at < self.cooldown_s:
            return None
        self._last_event_at = now
        self.events_fired += 1
        labels = sorted({d.label for d in hits})
        snapshot_path = None
        if frame_jpeg:
            snapshot_path = self._save_snapshot(frame_jpeg, labels, now)
        event = Event(when=now, labels=labels, snapshot_path=snapshot_path)
        self._notify(event)
        return event

    def _save_snapshot(self, frame_jpeg: bytes, labels: list[str],
                       now: float) -> str:
        os.makedirs(self.snapshot_dir, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now))
        name = f"{stamp}_{'-'.join(labels)}.jpg"
        path = os.path.join(self.snapshot_dir, name)
        with open(path, "wb") as f:
            f.write(frame_jpeg)
        self._trim()
        return path

    def _trim(self) -> None:
        files = sorted(
            (os.path.join(self.snapshot_dir, n)
             for n in os.listdir(self.snapshot_dir) if n.endswith(".jpg")),
        )
        excess = len(files) - self.max_snapshots
        for path in files[:max(0, excess)]:
            try:
                os.unlink(path)
            except OSError:
                pass

    def _notify(self, event: Event) -> None:
        """通知钩子:配置了 notify_cmd 才执行(板上指向 Hermes 通道)。

        事件信息走环境变量,命令本身在配置里写死,不拼字符串,避免注入。
        """
        if not self.notify_cmd:
            return
        env = dict(os.environ)
        env["VS_EVENT_LABELS"] = ",".join(event.labels)
        env["VS_EVENT_TIME"] = time.strftime(
            "%Y-%m-%d %H:%M:%S", time.localtime(event.when))
        env["VS_EVENT_SNAPSHOT"] = event.snapshot_path or ""
        try:
            subprocess.run(self.notify_cmd, shell=True, env=env,
                           timeout=30, check=False,
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except (subprocess.SubprocessError, OSError):
            pass

    def status(self) -> dict:
        return {
            "events_fired": self.events_fired,
            "last_event_at": self._last_event_at if self.events_fired else None,
            "targets": list(self.target_labels),
        }


def event_to_json(event: Event) -> str:
    return json.dumps({
        "when": event.when,
        "labels": event.labels,
        "snapshot": event.snapshot_path,
    }, ensure_ascii=False)
