"""预览服务:stdlib http.server 实现的 MJPEG 推流 + 健康检查。

端点:
  /          简单预览页(嵌 /stream)
  /stream    multipart/x-mixed-replace MJPEG 流
  /snapshot.jpg  最新一帧 JPEG
  /health    JSON:帧计数、最近事件引擎状态

只绑配置给定的地址(板上默认局域网/隧道地址),不出外网。
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FrameStore:
    """线程安全的最新帧存放处:主循环写,HTTP 线程读。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jpeg: bytes | None = None
        self._seq = 0
        self._updated_at = 0.0

    def put(self, jpeg: bytes) -> None:
        with self._lock:
            self._jpeg = jpeg
            self._seq += 1
            self._updated_at = time.time()

    def get(self) -> tuple[bytes | None, int]:
        with self._lock:
            return self._jpeg, self._seq

    def status(self) -> dict:
        with self._lock:
            return {
                "frames": self._seq,
                "last_frame_age_s": (
                    round(time.time() - self._updated_at, 1)
                    if self._seq else None),
            }


_INDEX_HTML = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>视觉小站预览</title></head>
<body style="margin:0;background:#111;color:#eee;font-family:sans-serif">
<div style="padding:8px 12px">RK3566 视觉小站 · 实时预览</div>
<img src="/stream" style="max-width:100vw;max-height:92vh;display:block">
</body></html>
"""


def make_server(host: str, port: int, store: FrameStore,
                status_fn) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # 静音访问日志
            pass

        def do_GET(self):
            if self.path == "/":
                body = _INDEX_HTML.encode()
                self._send(200, "text/html; charset=utf-8", body)
            elif self.path == "/snapshot.jpg":
                jpeg, _ = store.get()
                if jpeg is None:
                    self._send(503, "text/plain", b"no frame yet")
                else:
                    self._send(200, "image/jpeg", jpeg)
            elif self.path == "/health":
                payload = {"ok": True, **store.status(),
                           "events": status_fn()}
                self._send(200, "application/json",
                           json.dumps(payload).encode())
            elif self.path == "/stream":
                self._stream()
            else:
                self._send(404, "text/plain", b"not found")

        def _send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _stream(self):
            self.send_response(200)
            self.send_header(
                "Content-Type",
                "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            last_seq = -1
            try:
                while True:
                    jpeg, seq = store.get()
                    if jpeg is not None and seq != last_seq:
                        last_seq = seq
                        self.wfile.write(b"--frame\r\n")
                        self.wfile.write(b"Content-Type: image/jpeg\r\n")
                        self.wfile.write(
                            f"Content-Length: {len(jpeg)}\r\n\r\n".encode())
                        self.wfile.write(jpeg)
                        self.wfile.write(b"\r\n")
                    else:
                        time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass

    return ThreadingHTTPServer((host, port), Handler)
