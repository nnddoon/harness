"""harness serve：本地看板（只读）。三屏：今天要你决定的 / 晨报 / 需求。

- 只听 127.0.0.1；只用 Python 标准库；不写任何文件。
- 数据全部现读仓库里的 .harness/ 和 docs/specs/，用仓库自己装的 harness_lib 解析。
- 来自文件的文字一律 HTML 转义。

用法：harness serve [--repo DIR] [--port 8765]    （也可以 python3 pkg/cli/serve_cmd.py …）
"""
import glob
import html
import http.server
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

PKG = Path(__file__).resolve().parents[1]
KIND = {"ui": ("要你看一下", "accent"), "sensory": ("要你听一下", "warn"), "design": ("要你选", "accent"),
        "irreversible": ("要你点头", "ink"), "external": ("要你批准", "ink"), "ambiguity": ("要你澄清", "accent"),
        "unlock": ("要你放行", "ink")}
STATUS_WORD = {"done": "做好了", "integrated": "已整合", "review": "等你看", "waiting_human": "等你",
               "blocked": "卡住", "in_progress": "在做", "claimed": "在做", "ready": "排队中", "proposed": "待确认"}
CSS = """
*{box-sizing:border-box}body{margin:0;background:#F4F3EF;color:#15171C;font:15px/1.6 Inter,"Noto Sans SC","PingFang SC","Microsoft YaHei",system-ui,sans-serif}
a{color:#2953D6}nav{display:flex;gap:4px;padding:10px 20px;background:#fff;border-bottom:1px solid #E4E3DE;flex-wrap:wrap}
nav a{padding:8px 14px;border-radius:8px;text-decoration:none;color:#555B66}nav a.on{background:#15171C;color:#fff}
main{max-width:760px;margin:0 auto;padding:24px 16px 48px}h1{font-size:26px;margin:4px 0}.sub{color:#555B66;margin:0 0 18px}
.card{background:#fff;border:1px solid #E4E3DE;border-radius:16px;padding:16px 18px;margin:12px 0}
.tag{display:inline-block;font-size:12px;padding:2px 8px;border-radius:6px;margin-right:6px;font-weight:500}
.accent{background:#EAF0FD;color:#1C3FA8}.warn{background:#FCF1E1;color:#8A4B0A}.ink{background:#15171C;color:#fff}.ok{background:#E6F3EC;color:#1D6B45}
.muted{color:#6A707C;font-size:13px}.q{font-size:17px;font-weight:600;margin:6px 0}ul{margin:6px 0;padding-left:20px}
.rec{color:#1C3FA8;font-weight:500}code{background:#F1F0EC;padding:1px 5px;border-radius:4px;font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}td{padding:8px 4px;border-top:1px solid #EEEDE8;vertical-align:top}
"""


def load_lib(repo: Path):
    for p in (repo / ".claude/hooks/harness_lib.py", PKG / ".claude/hooks/harness_lib.py"):
        if p.exists():
            spec = importlib.util.spec_from_file_location("harness_lib_serve", p)
            mod = importlib.util.module_from_spec(spec)
            sys.dont_write_bytecode = True
            spec.loader.exec_module(mod)
            return mod
    raise SystemExit("找不到 harness_lib.py：这个仓库装过 harness 吗？")


def esc(x) -> str:
    return html.escape(str(x if x is not None else ""), quote=True)


def inline_md(text: str) -> str:
    """Escape first, then turn `code` into <code>. Nothing else is interpreted."""
    out = esc(text)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", out)


def page(title: str, active: str, body: str) -> bytes:
    tabs = [("/", "决定"), ("/morning", "晨报"), ("/needs", "需求")]
    nav = "".join(f'<a href="{h}" class="{"on" if h == active else ""}">{t}</a>' for h, t in tabs)
    return (f'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title>'
            f"<style>{CSS}</style></head><body><nav>{nav}</nav><main>{body}</main></body></html>").encode("utf-8")


def gate_title(path: str) -> str:
    txt = Path(path).read_text(encoding="utf-8")
    m = re.search(r"^# (?:G-\S+\s+)?(.+)$", txt.split("---", 2)[-1], re.M)
    return m.group(1).strip() if m else Path(path).stem


def gate_options(path: str) -> list:
    txt = Path(path).read_text(encoding="utf-8")
    sec = re.search(r"^## 选项\s*\n(.*?)(?=^## |\Z)", txt, re.M | re.S)
    if not sec:
        return []
    opts = []
    for line in sec.group(1).splitlines():
        m = re.match(r"^- \*\*([A-Z])(（推荐）)?\*\*[：:]\s*(.*)$", line.strip())
        if m and "<" not in m.group(3):
            opts.append((m.group(1), bool(m.group(2)), m.group(3)))
    return opts


def view_decide(repo: Path, H) -> bytes:
    gates = H.open_gates(repo)

    def minutes(g):
        try:
            return int(g.get("review_minutes") or 5)
        except (TypeError, ValueError):
            return 5
    gates.sort(key=lambda g: (0 if g.get("urgency") == "high" else 1, minutes(g), str(g.get("id"))))
    mins, items = H.review_load(repo)
    head = (f'<h1>今天要你决定 {len(gates)} 件事</h1><p class="sub">待你审阅：约 {mins} 分钟（{items} 项）。'
            "其余的都在跑，不需要你。</p>")
    cards = []
    for g in gates:
        word, cls = KIND.get(str(g.get("kind")), ("要你决定", "accent"))
        urgent = '<span class="tag warn">急</span>' if g.get("urgency") == "high" else ""
        rec = str(g.get("recommended") or "")
        opts = "".join(f'<li><b>{esc(k)}</b> {esc(t)}{" <span class=rec>推荐</span>" if (r or k == rec) else ""}</li>'
                       for k, r, t in gate_options(g["_path"]))
        where = f"GitHub Issue #{esc(g.get('issue'))}" if g.get("issue") else "对话里"
        cards.append(
            f'<div class="card">{urgent}<span class="tag {cls}">{esc(word)}</span>'
            f'<span class="muted">{esc(g.get("id"))} · 任务 {esc(g.get("task"))} · 约 {minutes(g)} 分钟</span>'
            f'<p class="q">{esc(gate_title(g["_path"]))}</p>'
            f'{"<ul>" + opts + "</ul>" if opts else ""}'
            f'<p class="muted">不回也没关系：{esc(g.get("default_if_no_answer") or "相关任务保持等待，其余照常进行")}。'
            f'在{where}回复 <code>{esc(g.get("id"))}: A</code>。</p></div>')
    if not cards:
        cards.append('<div class="card"><p class="q">现在没有要你决定的事</p><p class="muted">有新的会出现在这里。</p></div>')
    return page("今天要你决定的", "/", head + "".join(cards))


def view_morning(repo: Path, H) -> bytes:
    reports = sorted(glob.glob(str(repo / ".harness" / "reports" / "morning-*.md")))
    if reports:
        text, src = Path(reports[-1]).read_text(encoding="utf-8"), Path(reports[-1]).name
    else:
        text, src = H.morning(repo, None), "现算（还没有夜间运行的晨报）"
    out = []
    in_list = False
    for line in text.splitlines():
        if re.match(r"^\s+- ", line):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline_md(line.strip()[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.startswith("# "):
            out.append(f"<h1>{inline_md(line[2:])}</h1>")
        elif line.strip():
            out.append(f"<p>{inline_md(line)}</p>")
    if in_list:
        out.append("</ul>")
    body = f'{"".join(out)}<p class="muted">来源：{esc(src)}</p>'
    return page("晨报", "/morning", f'<div class="card">{body}</div>')


def acceptance(card_text: str, H) -> tuple:
    sec = H.section(card_text, "5.")
    done = len(re.findall(r"^\s*- \[x\]", sec, re.M | re.I))
    total = done + len(re.findall(r"^\s*- \[ \]", sec, re.M))
    return done, total


def view_needs(repo: Path, H) -> bytes:
    specs = []
    for p in sorted(glob.glob(str(repo / "docs" / "specs" / "S-*.md"))):
        txt = Path(p).read_text(encoding="utf-8")
        m = re.search(r"^# (.+)$", txt, re.M)
        sid = re.match(r"(S-\d+)", Path(p).name).group(1)
        specs.append((sid, m.group(1).strip() if m else Path(p).stem))
    rows_by = {}
    for r in H.backlog_rows(repo):
        loc = H.task_location(repo, r["id"])
        card = H.task_card_path(loc, r["id"])
        fm = H.read_frontmatter(card) if card else {}
        d, t = acceptance(card.read_text(encoding="utf-8"), H) if card else (0, 0)
        rows_by.setdefault(str(fm.get("spec") or "-"), []).append((r, d, t))
    blocks = []
    for sid, title in specs + [("-", "不属于任何 spec 的任务")]:
        rows = rows_by.get(sid, [])
        if sid == "-" and not rows:
            continue
        trs = "".join(
            f'<tr><td>{esc(r["id"])}</td><td>{esc(r["title"])}</td>'
            f'<td><span class="tag {"ok" if r["status"] in ("done", "integrated") else "warn" if r["status"] in ("review", "waiting_human", "blocked") else "accent"}">'
            f'{esc(STATUS_WORD.get(r["status"], r["status"]))}</span></td><td class="muted">验收 {d}/{t}</td></tr>'
            for r, d, t in rows) or '<tr><td class="muted">还没有任务</td></tr>'
        blocks.append(f'<div class="card"><p class="q">{esc(title)}</p><table>{trs}</table></div>')
    if not blocks:
        blocks.append('<div class="card"><p class="q">还没有需求</p><p class="muted">用 /spec 或 /task-align 写第一个。</p></div>')
    return page("需求", "/needs", "<h1>需求</h1>" + "".join(blocks))


ROUTES = {"/": view_decide, "/morning": view_morning, "/needs": view_needs}


def make_handler(repo: Path, H):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "harness-serve"

        def log_message(self, *a):  # quiet
            pass

        def _send(self, code: int, body: bytes, ctype="text/html; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def _host_ok(self) -> bool:
            # DNS rebinding: a web page on evil.example can point its name at 127.0.0.1 and read this
            # dashboard; the browser still sends Host: evil.example. Only answer our own names.
            port = self.server.server_address[1]
            return (self.headers.get("Host") or "") in {f"127.0.0.1:{port}", f"localhost:{port}"}

        def do_GET(self):
            if not self._host_ok():
                return self._send(421, b"misdirected request", "text/plain; charset=utf-8")
            path = self.path.split("?", 1)[0]
            view = ROUTES.get(path)
            if not view:
                return self._send(404, page("没有这一页", "", "<h1>没有这一页</h1>"))
            try:
                return self._send(200, view(repo, H))
            except Exception as e:  # show the problem, never a stack trace with paths
                return self._send(500, page("出错了", path, f'<h1>读取失败</h1><p class="muted">{esc(type(e).__name__)}: {esc(e)}</p>'))

        def do_POST(self):
            self._send(405, b"read-only", "text/plain; charset=utf-8")
        do_PUT = do_DELETE = do_PATCH = do_POST

    return Handler


def main(argv: list, pkg_root: str = str(PKG)) -> int:
    repo = Path(argv[argv.index("--repo") + 1]) if "--repo" in argv else Path.cwd()
    port = int(argv[argv.index("--port") + 1]) if "--port" in argv else 8765
    try:
        top = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, NotADirectoryError):
        print(f"✗ {repo} 不是 git 仓库", file=sys.stderr)
        return 1
    repo = Path(top)
    H = load_lib(repo)
    main_repo = H.main_checkout(repo) or repo  # backlog and gates live in the main checkout
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), make_handler(Path(main_repo), H))
    print(f"http://127.0.0.1:{srv.server_address[1]}/", flush=True)
    print("只读看板。Ctrl+C 结束。", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
