#!/usr/bin/env python3
"""假 Telegram Bot API（T-016 测试用）：python3 telegram.py <目录>

- 监听 127.0.0.1 的随机端口，端口号写进 <目录>/port。
- 路径 /bot<token>/<方法>；token 与环境变量 FAKETG_TOKEN 不符，或 <目录>/fail 存在 → 401。
- <目录>/fail_methods 每行一个方法名：这些方法回 400 {"ok": false}（模拟 editMessageText 等出错）。
- 每个请求追加一行 JSON 到 <目录>/requests.jsonl：{"method", "params", "auth", "message_id", "t"}——只记方法与参数，
  不记路径（路径里有 token）；t = 收到的时间（秒）。
- getUpdates：<目录>/queue.json 是更新列表（测试往里加）；按 offset 丢掉 update_id < offset 的，返回剩下的（不真的等待）。
- sendMessage → 新的 message_id（从 101 起递增，也记进日志的 "message_id"）；editMessageText / answerCallbackQuery / 其他 → ok。
参数可以是查询串、表单或 JSON；reply_markup 是字符串时按 JSON 解开再记。
"""
import fcntl
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, urlsplit

D = sys.argv[1]
TOKEN = os.environ.get("FAKETG_TOKEN", "")
LOCK = threading.Lock()
STATE = {"mid": 100}


def locked(name):
    fh = open(os.path.join(D, name + ".lock"), "a")
    fcntl.flock(fh, fcntl.LOCK_EX)
    return fh


def log(entry):
    with LOCK, open(os.path.join(D, "requests.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def updates(offset):
    lk = locked("queue")
    try:
        p = os.path.join(D, "queue.json")
        try:
            q = json.load(open(p, encoding="utf-8"))
        except (OSError, ValueError):
            q = []
        if offset is not None:
            q = [u for u in q if int(u.get("update_id", 0)) >= offset]
            with open(p + ".tmp", "w", encoding="utf-8") as fh:
                json.dump(q, fh, ensure_ascii=False)
            os.replace(p + ".tmp", p)
        return q[:100]
    finally:
        lk.close()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _params(self):
        u = urlsplit(self.path)
        params = dict(parse_qsl(u.query))
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        ct = (self.headers.get("Content-Type") or "").lower()
        if body:
            if "json" in ct:
                try:
                    params.update(json.loads(body.decode("utf-8")))
                except ValueError:
                    pass
            else:
                params.update(dict(parse_qsl(body.decode("utf-8"))))
        for k in ("reply_markup", "allowed_updates"):
            if isinstance(params.get(k), str):
                try:
                    params[k] = json.loads(params[k])
                except ValueError:
                    pass
        return u.path, params

    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _handle(self):
        path, params = self._params()
        parts = path.strip("/").split("/")
        method = parts[-1] if parts else ""
        tok = parts[0][3:] if parts and parts[0].startswith("bot") else None
        auth = tok == TOKEN and len(parts) == 2 and not os.path.exists(os.path.join(D, "fail"))
        mid = None
        if auth and method == "sendMessage":
            with LOCK:
                STATE["mid"] += 1
                mid = STATE["mid"]
        try:
            failing = set(open(os.path.join(D, "fail_methods")).read().split())
        except OSError:
            failing = set()
        if method in failing:
            mid = None
        log({"method": method, "params": params, "auth": auth, "message_id": mid, "t": time.time()})
        if not auth:
            return self._send(401, {"ok": False, "error_code": 401, "description": "Unauthorized"})
        if method in failing:
            return self._send(400, {"ok": False, "error_code": 400, "description": "Bad Request: fake failure"})
        if method == "getUpdates":
            off = params.get("offset")
            try:
                off = int(off) if off is not None and off != "" else None
            except (TypeError, ValueError):
                off = None
            return self._send(200, {"ok": True, "result": updates(off)})
        if method == "sendMessage":
            chat = params.get("chat_id")
            try:
                chat = int(chat)
            except (TypeError, ValueError):
                pass
            return self._send(200, {"ok": True, "result": {"message_id": mid, "date": 0, "chat": {"id": chat, "type": "private"},
                                                           "text": params.get("text", "")}})
        if method == "getMe":
            return self._send(200, {"ok": True, "result": {"id": 1, "is_bot": True, "first_name": "fake", "username": "fake_bot"}})
        return self._send(200, {"ok": True, "result": True})

    do_GET = _handle
    do_POST = _handle


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(D, "port.tmp"), "w") as fh:
    fh.write(str(srv.server_address[1]))
os.replace(os.path.join(D, "port.tmp"), os.path.join(D, "port"))
srv.serve_forever()
