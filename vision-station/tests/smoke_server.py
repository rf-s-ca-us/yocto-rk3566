"""server 冒烟:起服务 -> /health、/snapshot.jpg、/stream 各验一次。

跑法:python3 tests/smoke_server.py(退出码 0 = 通过)。
"""
import os
import sys
import threading
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from server import FrameStore, make_server

JPEG = b"\xff\xd8smoke\xff\xd9"


def get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.status, r.headers.get_content_type(), r.read()


def main():
    store = FrameStore()
    server = make_server("127.0.0.1", 18099, store,
                         lambda: {"events_fired": 0})
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:18099"
    try:
        status, _, _ = get(base + "/snapshot.jpg")
        raise AssertionError("无帧时 /snapshot.jpg 应为 503")
    except urllib.error.HTTPError as e:
        assert e.code == 503, e.code

    store.put(JPEG)
    status, ctype, body = get(base + "/snapshot.jpg")
    assert status == 200 and ctype == "image/jpeg" and body == JPEG

    status, ctype, body = get(base + "/health")
    assert status == 200 and ctype == "application/json"
    assert b'"frames": 1' in body, body

    # /stream:用裸 socket 读到一个 multipart 帧段即算通过
    # (http.client 的 read(n) 会等满 n 字节,不适合无长度的推流响应)
    import socket
    with socket.create_connection(("127.0.0.1", 18099), timeout=5) as s:
        s.sendall(b"GET /stream HTTP/1.0\r\nHost: localhost\r\n\r\n")
        data = b""
        while JPEG not in data:
            chunk = s.recv(4096)
            assert chunk, "流提前关闭"
            data += chunk
        assert b"multipart/x-mixed-replace" in data
        assert b"--frame" in data

    status, _, body = get(base + "/")
    assert status == 200 and b"/stream" in body
    server.shutdown()
    print("smoke_server:全部通过")


if __name__ == "__main__":
    main()
