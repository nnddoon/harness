"""harness serve：本地看板（只读）。三屏：今天要你决定的 / 晨报 / 需求。

- 只听 127.0.0.1；只用 Python 标准库。
- 答复门卡（唯一的写入）：要启动时生成的令牌（只打印到你的终端；在 Claude 的 Bash 里启动不会有），
  存在 HttpOnly + SameSite=Strict 的 cookie；查 Origin 和 Host；放权 / 采纳原则的门卡不能在这里批准；
  写回逻辑与 GitHub 收件箱是同一个函数（gate_github.apply_answer）。
- 数据全部现读仓库里的 .harness/ 和 docs/specs/，用仓库自己装的 harness_lib 解析。
- 来自文件的文字一律 HTML 转义。

用法：harness serve [--repo DIR] [--port 8765]    （也可以 python3 pkg/cli/serve_cmd.py …）
"""
import glob
import hmac
import html
import http.server
import importlib.util
import os
import re
import secrets
import subprocess
import threading
import urllib.parse
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
.rec{color:#1C3FA8;font-weight:500}.reqs{list-style:none;padding:0}.req{padding:10px 0;border-top:1px solid #EEEDE8}
details summary{cursor:pointer;margin-top:4px}td:first-child,.tag{white-space:nowrap}.ans{margin:10px 0 4px}.ans input[type=text]{width:100%;padding:10px 12px;border:1px solid #D5D3CC;border-radius:10px;font:inherit}
.btns{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}.btn{flex:1;min-height:44px;padding:10px 14px;border-radius:10px;border:1px solid #D5D3CC;background:#fff;font:inherit;cursor:pointer}
.btn.pri{background:#15171C;color:#fff;border-color:#15171C}.card.ok{background:#E6F3EC;border-color:#BFE0CC;color:#1D6B45}code{background:#F1F0EC;padding:1px 5px;border-radius:4px;font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}td{padding:8px 4px;border-top:1px solid #EEEDE8;vertical-align:top}
"""


def _load(repo: Path, name: str):
    for d in (repo / ".claude/hooks", repo / ".harness/lib", PKG / ".claude/hooks", PKG / "hooks"):
        p = d / f"{name}.py"
        if p.exists():
            sys.dont_write_bytecode = True
            if str(d) not in sys.path:
                sys.path.insert(0, str(d))  # gate_github imports harness_lib by name
            spec = importlib.util.spec_from_file_location(f"{name}_serve", p)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise SystemExit(f"找不到 {name}.py：这个仓库装过 harness 吗？")


def load_lib(repo: Path):
    return _load(repo, "harness_lib")


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


MAX_BODY = 4096
COOKIE = "harness_t"
TOKEN_OK = re.compile(r"^[A-Za-z0-9_-]{6,128}$")
WRITE_LOCK = threading.Lock()  # one answer at a time: check-then-write and decision numbers stay consistent


def one_line(text: str) -> str:
    """Everything str.splitlines() would split on (\\r, U+2028, \\x1c...) becomes a space, so a note can never
    forge a frontmatter field or a decisions.md line; other control characters are dropped."""
    flat = " ".join(str(text).splitlines())
    return "".join(ch for ch in flat if ch == " " or ch.isprintable()).strip()


def all_gates(repo: Path, H) -> list:
    """Gates live where the task runs (its worktree) or in the main checkout. Same id twice -> the task's copy."""
    seen = {}
    for path, _br in H.worktrees(repo) or [(repo, "")]:
        for g in H.gates(Path(path)):
            gid = str(g.get("id"))
            if gid not in seen or Path(path) != Path(repo):
                seen[gid] = g
    return list(seen.values())


def load_minutes(repo: Path, H, gates: list) -> tuple:
    mins = items = 0
    for g in gates:
        if g.get("status") == "open" and not g.get("pr"):
            try:
                mins += int(g.get("review_minutes") or 5)
            except (TypeError, ValueError):
                mins += 5
            items += 1
    for r in H.backlog_rows(repo):
        if r["status"] in ("review", "integrated"):
            risk = H.card_fm(H.task_location(repo, r["id"]), r["id"]).get("risk", "low")
            mins += H.REVIEW_MIN.get(str(risk), 2)
            items += 1
    return mins, items


def is_policy_gate(g: dict) -> bool:
    return bool(g.get("then_policy")) or bool(g.get("then_rules"))


def answer_forms(g: dict, opts: list) -> str:
    if is_policy_gate(g):
        return '<p class="muted">这张会改变规则（放权或采纳原则），只能在 GitHub 上或你自己的终端里批准。</p>'
    gid = esc(g.get("id"))
    btns = "".join(
        f'<button type="submit" name="letter" value="{esc(k)}" class="btn{" pri" if r else ""}">选 {esc(k)}</button>'
        for k, r, _ in opts)
    return (f'<form method="post" action="/answer" class="ans"><input type="hidden" name="gate" value="{gid}">'
            f'<input type="text" name="note" maxlength="300" placeholder="补一句（可选）" aria-label="备注">'
            f'<div class="btns">{btns}</div></form>')


def running_line(repo: Path, H) -> str:
    """Say what is actually happening (dogfood 2026-11-12: the page claimed everything was running when nothing was)."""
    st = [r["status"] for r in H.backlog_rows(repo)]
    running, queued = sum(s in ("in_progress", "claimed") for s in st), st.count("ready")
    if running:
        return f"另外 {running} 件在跑" + (f"、{queued} 件在排队" if queued else "") + "，不需要你。"
    return f"现在没有任务在跑，{queued} 件在排队。" if queued else "现在没有任务在跑。"


def view_decide(repo: Path, H, authed: bool = False, done: str = "") -> bytes:
    every = all_gates(repo, H)
    gates = [g for g in every if g.get("status") == "open"]

    def minutes(g):
        try:
            return int(g.get("review_minutes") or 5)
        except (TypeError, ValueError):
            return 5
    gates.sort(key=lambda g: (0 if g.get("urgency") == "high" else 1, minutes(g), str(g.get("id"))))
    mins, items = load_minutes(repo, H, every)
    flash = (f'<div class="card ok">已记下 {esc(done)}。任务会在下一次调度时接着做'
             '（夜间循环或 <code>scripts/gate-sync.sh --resume</code>）。</div>') if done else ""
    hint = ("" if authed else '<p class="muted">要在这里直接点选项答复：用你终端里 <code>harness serve</code> '
            '打印的带令牌的地址打开这一页。</p>')
    head = flash + (f'<h1>今天要你决定 {len(gates)} 件事</h1><p class="sub">待你审阅：约 {mins} 分钟（{items} 项）。'
            f"{running_line(repo, H)}</p>") + (hint if gates else "")
    cards = []
    for g in gates:
        word, cls = KIND.get(str(g.get("kind")), ("要你决定", "accent"))
        urgent = '<span class="tag warn">急</span>' if g.get("urgency") == "high" else ""
        rec = str(g.get("recommended") or "")
        olist = gate_options(g["_path"])
        opts = "".join(f'<li><b>{esc(k)}</b> {esc(t)}{" <span class=rec>推荐</span>" if (r or k == rec) else ""}</li>'
                       for k, r, t in olist)
        where = f"GitHub Issue #{esc(g.get('issue'))}" if g.get("issue") else "对话里"
        cards.append(
            f'<div class="card">{urgent}<span class="tag {cls}">{esc(word)}</span>'
            f'<span class="muted">{esc(g.get("id"))} · 任务 {esc(g.get("task"))} · 约 {minutes(g)} 分钟</span>'
            f'<p class="q">{esc(gate_title(g["_path"]))}</p>'
            f'{"<ul>" + opts + "</ul>" if opts else ""}'
            f'{answer_forms(g, olist) if authed and olist else ""}'
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


REQ_REF = re.compile(r"\b(S-\d+)#(\d+)\b")
REQ_ORDER = ["做好了", "等你看", "等你", "卡住", "在做", "排队中", "还没有任务"]
REQ_CLASS = {"做好了": "ok", "等你看": "warn", "等你": "warn", "卡住": "warn", "在做": "accent", "排队中": "accent",
             "还没有任务": "accent"}


def spec_requirements(text: str) -> list:
    """Numbered items under the spec's 验收 heading -> [(n, text)]. These are the ids S-xxx#n."""
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            inside = "验收" in line
            continue
        m = re.match(r"^\s*(\d+)[.)]\s+(.+)$", line) if inside else None
        if m:
            out.append((int(m.group(1)), m.group(2).strip()))
    return out


def table_rows(section_text: str) -> list:
    return [[c.strip() for c in l.strip().strip("|").split("|")]
            for l in section_text.splitlines() if re.match(r"^\|\s*\d+\s*\|", l.strip())]


def requirement_status(refs: list) -> str:
    if not refs:
        return "还没有任务"
    st = {r["status"] for r in refs}
    if "waiting_human" in st:
        return "等你"
    if "blocked" in st:
        return "卡住"
    if all(r["checked"] for r in refs):
        return "做好了" if st <= {"done"} else "等你看"
    if st & {"in_progress", "claimed", "review", "integrated"}:
        return "在做"
    return "排队中"


def view_needs(repo: Path, H) -> bytes:
    specs = []
    for p in sorted(glob.glob(str(repo / "docs" / "specs" / "S-*.md"))):
        txt = Path(p).read_text(encoding="utf-8")
        m = re.search(r"^# (.+)$", txt, re.M)
        sid = re.match(r"(S-\d+)", Path(p).name).group(1)
        specs.append((sid, m.group(1).strip() if m else Path(p).stem))
    rows_by, refs_by, detail = {}, {}, {}
    for r in H.backlog_rows(repo):
        loc = H.task_location(repo, r["id"])
        card = H.task_card_path(loc, r["id"])
        fm = H.read_frontmatter(card) if card else {}
        text = card.read_text(encoding="utf-8") if card else ""
        d, t = acceptance(text, H) if card else (0, 0)
        rows_by.setdefault(str(fm.get("spec") or "-"), []).append((r, d, t))
        attempts = table_rows(H.section(text, "11.")) if card else []
        adv = table_rows(H.section(text, "13.")) if card else []
        paths = fm.get("allowed_paths") or []
        detail[r["id"]] = {
            "status": r["status"], "paths": paths if isinstance(paths, list) else [paths],
            "attempts": len(attempts), "last": attempts[-1][-1] if attempts else "",
            "adv": adv[-1][-1] if adv else ""}
        for line in H.section(text, "5.").splitlines():
            m = re.match(r"^\s*- \[([ xX])\]\s*(.*)$", line)
            if not m:
                continue
            for sid_ref, n in REQ_REF.findall(m.group(2)):
                ev = m.group(2).split("证据：", 1)[1].strip() if "证据：" in m.group(2) else ""
                refs_by.setdefault((sid_ref, int(n)), []).append(
                    {"tid": r["id"], "status": r["status"], "checked": m.group(1).lower() == "x", "evidence": ev})
    blocks = []
    spec_text = {}
    for p in sorted(glob.glob(str(repo / "docs" / "specs" / "S-*.md"))):
        spec_text[re.match(r"(S-\d+)", Path(p).name).group(1)] = Path(p).read_text(encoding="utf-8")
    for sid, title in specs + [("-", "不属于任何 spec 的任务")]:
        rows = rows_by.get(sid, [])
        if sid == "-" and not rows:
            continue
        reqs = spec_requirements(spec_text.get(sid, "")) if sid != "-" else []
        req_html, counts = "", {}
        for n, rtext in reqs:
            refs = refs_by.get((sid, n), [])
            stw = requirement_status(refs)
            counts[stw] = counts.get(stw, 0) + 1
            evid = "；".join(esc(x["evidence"]) for x in refs if x["evidence"])
            parts = []
            for tid in dict.fromkeys(x["tid"] for x in refs):
                dd = detail.get(tid, {})
                bits = [f'<b>{esc(tid)}</b> {esc(STATUS_WORD.get(dd.get("status"), dd.get("status", "")))}']
                if dd.get("paths"):
                    bits.append("影响：" + "、".join(f"<code>{esc(x)}</code>" for x in dd["paths"]))
                if dd.get("attempts"):
                    bits.append(f'试了 {dd["attempts"]} 次（最后：{esc(dd["last"])}）')
                if dd.get("adv"):
                    bits.append(f'挑错：{esc(dd["adv"])}')
                parts.append('<div class="muted">' + " · ".join(bits) + "</div>")
            more = (f'<details><summary class="muted">来龙去脉</summary>{"".join(parts)}</details>') if parts else ""
            evid_html = f'<div class="muted">证据：{evid}</div>' if evid else ""
            req_html += (f'<li class="req" id="{esc(sid)}-{n}"><span class="tag {REQ_CLASS[stw]}">{esc(stw)}</span>'
                         f'{esc(rtext)} <span class="muted">{esc(sid)}#{n}</span>{evid_html}{more}</li>')
        summary = ""
        if reqs:
            summary = (f'<p class="muted">{len(reqs)} 句需求 · ' +
                       " · ".join(f"{counts[k]} {k}" for k in REQ_ORDER if counts.get(k)) + "</p>")
            req_html = '<ul class="reqs">' + req_html + "</ul>"
        trs = "".join(
            f'<tr><td>{esc(r["id"])}</td><td>{esc(r["title"])}</td>'
            f'<td><span class="tag {"ok" if r["status"] in ("done", "integrated") else "warn" if r["status"] in ("review", "waiting_human", "blocked") else "accent"}">'
            f'{esc(STATUS_WORD.get(r["status"], r["status"]))}</span></td><td class="muted">验收 {d}/{t}</td></tr>'
            for r, d, t in rows) or '<tr><td class="muted">还没有任务</td></tr>'
        task_head = '<p class="muted">任务</p>' if reqs else ""
        blocks.append(f'<div class="card"><p class="q">{esc(title)}</p>{summary}{req_html}{task_head}<table>{trs}</table></div>')
    if not blocks:
        blocks.append('<div class="card"><p class="q">还没有需求</p><p class="muted">用 /spec 或 /task-align 写第一个。</p></div>')
    return page("需求", "/needs", "<h1>需求</h1>" + "".join(blocks))


ROUTES = {"/": view_decide, "/morning": view_morning, "/needs": view_needs}


def make_handler(repo: Path, H, token: str | None = None, G=None):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "harness-serve"

        def log_message(self, *a):  # quiet
            pass

        def _send(self, code: int, body: bytes, ctype="text/html; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def _host_ok(self) -> bool:
            # DNS rebinding: a web page on evil.example can point its name at 127.0.0.1 and read this
            # dashboard; the browser still sends Host: evil.example. Only answer our own names.
            port = self.server.server_address[1]
            return (self.headers.get("Host") or "") in {f"127.0.0.1:{port}", f"localhost:{port}"}

        def _authed(self) -> bool:
            if not token:
                return False
            for part in (self.headers.get("Cookie") or "").split(";"):
                k, _, v = part.strip().partition("=")
                if k == COOKIE and hmac.compare_digest(v, token):
                    return True
            return False

        def _redirect(self, where: str, cookie: str = ""):
            self.send_response(303)
            self.send_header("Location", where)
            if cookie:
                self.send_header("Set-Cookie", cookie)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            if not self._host_ok():
                return self._send(421, b"misdirected request", "text/plain; charset=utf-8")
            path, _, query = self.path.partition("?")
            q = urllib.parse.parse_qs(query)
            t = (q.get("t") or [""])[0]
            if token and t and hmac.compare_digest(t, token):
                return self._redirect("/", f"{COOKIE}={token}; HttpOnly; SameSite=Strict; Path=/")
            view = ROUTES.get(path)
            if not view:
                return self._send(404, page("没有这一页", "", "<h1>没有这一页</h1>"))
            try:
                if view is view_decide:
                    done = (q.get("done") or [""])[0][:40]
                    return self._send(200, view_decide(repo, H, self._authed(), done))
                return self._send(200, view(repo, H))
            except Exception as e:  # show the problem, never a stack trace with paths
                return self._send(500, page("出错了", path, f'<h1>读取失败</h1><p class="muted">{esc(type(e).__name__)}: {esc(e)}</p>'))

        def _text(self, code: int, msg: str):
            return self._send(code, msg.encode("utf-8"), "text/plain; charset=utf-8")

        def do_POST(self):
            if self.path.split("?", 1)[0] != "/answer":
                return self._text(405, "read-only")
            if not self._host_ok():
                return self._text(421, "misdirected request")
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return self._text(400, "bad length")
            if n < 0:
                return self._text(400, "bad length")
            if n > MAX_BODY:
                return self._text(413, "too large")
            port = self.server.server_address[1]
            if (self.headers.get("Origin") or "") not in {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}:
                return self._text(403, "wrong origin")
            if not self._authed():
                return self._text(403, "需要从你终端里打印的带令牌地址打开看板")
            form = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
            gid = (form.get("gate") or [""])[0].strip()
            letter = (form.get("letter") or [""])[0].strip().upper()
            note = one_line((form.get("note") or [""])[0])[:300]
            with WRITE_LOCK:
                g = next((x for x in all_gates(repo, H) if str(x.get("id")) == gid), None)
                if not g:
                    return self._text(404, "没有这张门卡")
                if g.get("status") != "open":
                    return self._text(409, "这张门卡已经答复过了")
                if is_policy_gate(g):
                    return self._text(403, "放权 / 采纳原则只能在 GitHub 上或你自己的终端里批准")
                if letter not in {k for k, _, _ in gate_options(g["_path"])}:
                    return self._text(400, "没有这个选项")
                try:
                    G.apply_answer(Path(g["_path"]), letter, note, "看板")
                except Exception as e:  # never leave the browser hanging
                    return self._text(500, f"写入失败（{type(e).__name__}）：门卡可能已标记答复但决策没记上，请检查 .harness/decisions.md")
            return self._redirect(f"/?done={urllib.parse.quote(gid)}")

        do_PUT = do_DELETE = do_PATCH = lambda self: self._text(405, "read-only")

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
    G = _load(repo, "gate_github")
    main_repo = H.main_checkout(repo) or repo  # backlog and gates live in the main checkout
    # The token is the only way to write. It is printed to YOUR terminal; started from a non-terminal
    # (e.g. Claude's Bash tool) there is none, so the board stays read-only.
    token = os.environ.get("HARNESS_SERVE_TOKEN") or (secrets.token_urlsafe(18) if sys.stdout.isatty() else None)
    if token and not TOKEN_OK.match(token):
        print("✗ HARNESS_SERVE_TOKEN 只能是 6–128 位字母、数字、- 或 _；这次以只读启动", file=sys.stderr)
        token = None
    if "--read-only" in argv:
        token = None
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), make_handler(Path(main_repo), H, token, G))
    base = f"http://127.0.0.1:{srv.server_address[1]}/"
    print(base + (f"?t={token}" if token else ""), flush=True)
    print("用上面的地址打开就能答复门卡。Ctrl+C 结束。" if token else "只读看板（不是从终端启动，不能答复）。Ctrl+C 结束。", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
