"""events 主机测试:命中/冷却/落盘/保留上限。时间用注入的 now。"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from events import EventEngine
from postprocess import Detection

JPEG = b"\xff\xd8fake-jpeg\xff\xd9"
PERSON = Detection(0, 0, 10, 10, 0.9, 0)     # person
CAR = Detection(0, 0, 10, 10, 0.9, 2)        # car,非目标


def test_hit_fires_and_saves():
    with tempfile.TemporaryDirectory() as d:
        eng = EventEngine(snapshot_dir=d, cooldown_s=60)
        ev = eng.process([PERSON], JPEG, now=1000.0)
        assert ev is not None and ev.labels == ["person"]
        assert ev.snapshot_path and os.path.exists(ev.snapshot_path)
        assert eng.events_fired == 1


def test_non_target_no_event():
    with tempfile.TemporaryDirectory() as d:
        eng = EventEngine(snapshot_dir=d)
        assert eng.process([CAR], JPEG, now=1000.0) is None
        assert eng.events_fired == 0


def test_cooldown():
    with tempfile.TemporaryDirectory() as d:
        eng = EventEngine(snapshot_dir=d, cooldown_s=60)
        assert eng.process([PERSON], JPEG, now=1000.0) is not None
        assert eng.process([PERSON], JPEG, now=1030.0) is None  # 冷却中
        assert eng.process([PERSON], JPEG, now=1061.0) is not None
        assert eng.events_fired == 2


def test_no_jpeg_still_fires():
    with tempfile.TemporaryDirectory() as d:
        eng = EventEngine(snapshot_dir=d)
        ev = eng.process([PERSON], None, now=1000.0)
        assert ev is not None and ev.snapshot_path is None


def test_retention_trim():
    with tempfile.TemporaryDirectory() as d:
        eng = EventEngine(snapshot_dir=d, cooldown_s=0, max_snapshots=3)
        for i in range(6):
            eng.process([PERSON], JPEG, now=1000.0 + i * 2)
        files = [n for n in os.listdir(d) if n.endswith(".jpg")]
        assert len(files) == 3, files


def test_status():
    with tempfile.TemporaryDirectory() as d:
        eng = EventEngine(snapshot_dir=d)
        st = eng.status()
        assert st["events_fired"] == 0 and st["last_event_at"] is None
        eng.process([PERSON], JPEG, now=1000.0)
        st = eng.status()
        assert st["events_fired"] == 1 and st["last_event_at"] == 1000.0


if __name__ == "__main__":
    test_hit_fires_and_saves()
    test_non_target_no_event()
    test_cooldown()
    test_no_jpeg_still_fires()
    test_retention_trim()
    test_status()
    print("test_events:全部通过")
