"""harness inbox：Telegram 收件箱。门卡推到你的 Telegram，点按钮就是答复（写进答案库，via Telegram）。

  harness inbox setup  [--repo DIR]          在终端里输入 bot token（不回显），显示一次性配对码（10 分钟有效）
  harness inbox run    [--once] [--repo DIR] 轮询（≤ 20 秒长轮询）：处理配对与按钮，给新的门卡发消息
  harness inbox start | stop | status [--repo DIR]   后台 bot（pid 文件在 state_dir/run/inbox-<pid>.pid）

配置 $XDG_CONFIG_HOME/harness/telegram.json（600）：token 只在这里，不进仓库、日志、命令行和 Claude 的环境。
只认配对过的那个人；按钮只带「门卡号|字母」，消息正文只取控制面的门卡快照；
irreversible / external / unlock 要再点一次确认。不接受自由文本指令。
环境变量：HARNESS_TELEGRAM_API（默认 https://api.telegram.org）、HARNESS_TELEGRAM_POLL（秒，默认 20，上限 20）、
HARNESS_NOW（测试用的「现在」）。
"""
import contextlib
import getpass
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PKG = Path(__file__).resolve().parents[1]
if str(PKG) not in sys.path:
    sys.path.insert(0, str(PKG))
from cli import doctor_cmd as D  # noqa: E402  pid 文件格式、进程核验、HARNESS_NOW、主仓库定位（T-013）

DEFAULT_API = "https://api.telegram.org"
PAIR_TTL = 600          # 配对码有效期（秒）
PAIR_TRIES = 5          # 配对码最多试错次数，超过作废
MAX_POLL = 20
TOKEN_RE = re.compile(r"\d{3,20}:[A-Za-z0-9_-]{20,100}")
PAIR_RE = re.compile(r"/pair(?:@[A-Za-z0-9_]+)?\s+(\d{6})")
DATA_RE = re.compile(r"(G-[A-Za-z0-9-]+)\|([A-Z])(\|ok)?")
MAX_TEXT = 3500


class ApiError(Exception):
    pass


# ---------------------------------------------------------------- 配置与状态
def cfg_path(H) -> Path:
    return H.config_dir() / "telegram.json"


def load_cfg(H) -> dict:
    try:
        d = json.loads(cfg_path(H).read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cfg(H, cfg: dict) -> None:
    H._write_private(cfg_path(H), cfg)   # 0600，目录 0700，原子替换


def inbox_path(H, main: Path) -> Path:
    return H.state_dir(main) / "inbox.json"


def load_inbox(H, main: Path) -> dict:
    try:
        d = json.loads(inbox_path(H, main).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        d = {}
    if not isinstance(d, dict):
        d = {}
    d.setdefault("offset", 0)
    if not isinstance(d.get("sent"), dict):
        d["sent"] = {}
    return d


def save_inbox(H, main: Path, data: dict) -> None:
    H._write_private(inbox_path(H, main), data)


@contextlib.contextmanager
def cycle_lock(H, main: Path):
    """同一个仓库同时只跑一个轮询周期（后台 bot 与手动 run --once 不会重复处理同一条更新）。"""
    d = H.state_dir(main)
    d.mkdir(parents=True, exist_ok=True)
    try:
        import fcntl
    except ImportError:
        yield
        return
    with open(d / "inbox.lock", "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def api_base(cfg: dict) -> str:
    return (os.environ.get("HARNESS_TELEGRAM_API") or cfg.get("api") or DEFAULT_API).rstrip("/")


def poll_secs() -> int:
    try:
        v = int(os.environ.get("HARNESS_TELEGRAM_POLL") or MAX_POLL)
    except ValueError:
        v = MAX_POLL
    return min(max(v, 1), MAX_POLL)


def clean(msg, token: str) -> str:
    """错误信息里绝不带 token（也不带 token 的秘密部分）。"""
    msg = str(msg)
    for t in (token, token.partition(":")[2]):
        if t:
            msg = msg.replace(t, "***")
    return msg


def call(cfg: dict, method: str, params: dict, timeout: float = 30):
    token = str(cfg.get("token") or "")
    url = f"{api_base(cfg)}/bot{token}/{method}"
    req = urllib.request.Request(url, data=json.dumps(params, ensure_ascii=False).encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise ApiError(f"Telegram 返回 {e.code}" + ("（token 无效？重跑 harness inbox setup）" if e.code == 401 else "")) from None
    except Exception as e:  # 连不上、超时、不是 JSON
        raise ApiError(clean(f"连不上 Telegram（{type(e).__name__}: {getattr(e, 'reason', e)}）", token)) from None
    if not isinstance(body, dict) or not body.get("ok"):
        desc = body.get("description", "") if isinstance(body, dict) else ""
        raise ApiError(clean(f"Telegram 拒绝了 {method}：{desc}", token))
    return body.get("result")


def now() -> float:
    return D.now()


def _sha(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()


# ---------------------------------------------------------------- 门卡 → 消息（只用快照）
def letters(H, meta: dict) -> list:
    real = [o["letter"] for o in meta.get("options") or [] if "<" not in str(o.get("text", ""))]
    return real or H.meta_letters(meta)


def is_policy(meta: dict) -> bool:
    return bool(meta.get("then_policy")) or bool(meta.get("then_rules"))


def gate_text(meta: dict) -> str:
    lines = [f"门卡 {meta.get('gid', '')}：{meta.get('title', '')}", f"类别：{meta.get('kind', '') or '-'}"]
    if meta.get("task"):
        lines.append(f"任务：{meta['task']}")
    for o in meta.get("options") or []:
        if "<" in str(o.get("text", "")):
            continue
        rec = "（推荐）" if o.get("letter") == meta.get("recommended") else ""
        lines.append(f"- {o.get('letter')}{rec}：{o.get('text', '')}")
    if meta.get("kind") == "unlock":
        lines.append("批准（A）后放开：" + ("、".join(str(p) for p in meta.get("paths") or []) or "（快照里没有路径）"))
    if meta.get("kind") in ("irreversible", "external", "unlock"):
        lines.append("点选后还要再确认一次。")
    return "\n".join(lines)[:MAX_TEXT]


def keyboard(H, meta: dict) -> dict | None:
    gid = meta.get("gid", "")
    ls = letters(H, meta)
    if is_policy(meta) or not all(len(f"{gid}|{l}|ok".encode()) <= 64 for l in ls):
        return None
    row = [{"text": l + ("（推荐）" if l == meta.get("recommended") else ""), "callback_data": f"{gid}|{l}"} for l in ls]
    return {"inline_keyboard": [row[i:i + 4] for i in range(0, len(row), 4)]}


def full_text(H, meta: dict) -> str:
    t = gate_text(meta)
    if is_policy(meta):
        t += "\n这张会改变规则（放权或采纳原则），只能在 GitHub 上或你自己的终端里批准。"
    elif keyboard(H, meta) is None:
        t += "\n门卡号太长，放不进按钮：请在终端里答复。"
    return t[:MAX_TEXT]


def answer_line(H, main: Path, gid: str, meta: dict) -> str:
    a = H.read_answer(main, gid) or {}
    opt = H.meta_option(meta, a.get("letter", ""))
    return (f"已答复：{a.get('letter') or '?'}" + (f"（{opt}）" if opt and "<" not in opt else "")
            + f" via {a.get('via') or '?'}")


def open_gate_ids(H, main: Path) -> list:
    """控制面认的开放门卡（任务自己的 worktree 或主仓库里的那张；别处的同名卡不算）。"""
    out = []
    for path, _br in H.worktrees(main) or [(main, "")]:
        for g in H.open_gates(Path(path)):
            gid = H.gate_id(g)
            if gid not in out:
                out.append(gid)
    return out


# ---------------------------------------------------------------- 一个轮询周期
def handle_pair(H, cfg: dict, msg: dict) -> None:
    """/pair <码>：只认 setup 显示的一次性码（10 分钟内、私聊）。错了不回复（不给猜码的人任何提示）。"""
    m = PAIR_RE.fullmatch(str(msg.get("text") or "").strip())
    if not m or not cfg.get("pair_sha256"):
        return
    try:
        expires = float(cfg.get("pair_expires") or 0)
    except (TypeError, ValueError):
        expires = 0.0
    frm, chat = msg.get("from") or {}, msg.get("chat") or {}
    if now() > expires:
        for k in ("pair_sha256", "pair_expires", "pair_tries"):
            cfg.pop(k, None)
        save_cfg(H, cfg)
        return
    good = hmac.compare_digest(_sha(m.group(1)), str(cfg["pair_sha256"]))
    if not good or chat.get("type") != "private" or frm.get("is_bot") or not isinstance(frm.get("id"), int):
        cfg["pair_tries"] = int(cfg.get("pair_tries") or 0) + 1
        if cfg["pair_tries"] >= PAIR_TRIES:   # 猜太多次：码作废，重跑 setup
            for k in ("pair_sha256", "pair_expires"):
                cfg.pop(k, None)
        save_cfg(H, cfg)
        return
    for k in ("pair_sha256", "pair_expires", "pair_tries"):
        cfg.pop(k, None)
    cfg["paired_user_id"], cfg["chat_id"] = frm["id"], chat.get("id")
    save_cfg(H, cfg)
    call(cfg, "sendMessage", {"chat_id": cfg["chat_id"], "text": "已配对：新的门卡会发到这里，点按钮就是答复。"})


def mine(cfg: dict, frm: dict, chat: dict) -> bool:
    uid = cfg.get("paired_user_id")
    return (isinstance(uid, int) and not isinstance(uid, bool) and frm.get("id") == uid
            and chat.get("id") == cfg.get("chat_id") and not frm.get("is_bot"))


def handle_callback(H, main: Path, cfg: dict, box: dict, cq: dict) -> None:
    msg = cq.get("message") or {}
    if not mine(cfg, cq.get("from") or {}, msg.get("chat") or {}):
        return  # 陌生人：不理，不回复

    def reply(text: str):
        call(cfg, "answerCallbackQuery", {"callback_query_id": cq.get("id"), "text": text})

    m = DATA_RE.fullmatch(str(cq.get("data") or ""))
    gid = m.group(1) if m else ""
    sent = box["sent"].get(gid) if m and H.valid_gid(gid) else None
    # 按钮必须来自我们发给这个聊天的那条门卡消息
    if not sent or sent.get("message_id") != msg.get("message_id") or sent.get("chat_id") != cfg.get("chat_id"):
        return reply("这个按钮无效")
    letter, ok = m.group(2), bool(m.group(3))
    meta = H.read_meta(main, gid)
    st = H.gate_state(main, gid)
    if st == "answered":
        return reply("已经答过了")
    if st != "open" or not meta:
        return reply("答案库读不了，这张门卡的状态未知")
    if is_policy(meta):
        return reply("这张只能在 GitHub 上或你的终端里批准")
    if letter not in letters(H, meta):
        return reply("没有这个选项")
    if meta.get("kind") in H.APPROVAL_KINDS and not (ok and sent.get("confirm") == letter):
        opt = H.meta_option(meta, letter)
        sent["confirm"] = letter
        save_inbox(H, main, box)
        others = [{"text": f"改选 {l}", "callback_data": f"{gid}|{l}"} for l in letters(H, meta) if l != letter]
        kb = {"inline_keyboard": [[{"text": f"确认 {letter}", "callback_data": f"{gid}|{letter}|ok"}]]
              + ([others] if others else [])}
        text = full_text(H, meta) + f"\n\n要选 {letter}" + (f"（{opt}）" if opt and "<" not in opt else "") \
            + " 吗？这一类做了就撤不回，再点一次「确认」。"
        call(cfg, "editMessageText", {"chat_id": cfg["chat_id"], "message_id": sent["message_id"],
                                      "text": text[:4000], "reply_markup": kb})
        return reply(f"再点一次「确认 {letter}」")
    recorded, _status, _tid = H.answer_gate(main, gid, letter, "", "Telegram")   # 写库 + 镜像 + 接续
    if not recorded:
        return reply("已经答过了" if H.gate_state(main, gid) == "answered" else "没记上（答案库写不了？）")
    sent["closed"] = True
    sent.pop("confirm", None)
    save_inbox(H, main, box)
    call(cfg, "editMessageText", {"chat_id": cfg["chat_id"], "message_id": sent["message_id"],
                                  "text": (gate_text(meta) + "\n\n" + answer_line(H, main, gid, meta))[:4000]})
    reply(f"已记录：{letter}")


def push_gates(H, main: Path, cfg: dict, box: dict) -> None:
    chat = cfg.get("chat_id")
    open_ids = open_gate_ids(H, main)
    for gid in open_ids:
        s = box["sent"].get(gid)
        if s and s.get("chat_id") == chat:
            continue
        meta = H.snapshot_meta(main, gid)   # 第一次看到就冻结含义；之后改卡不影响消息
        if not meta:
            continue
        params = {"chat_id": chat, "text": full_text(H, meta)}
        kb = keyboard(H, meta)
        if kb:
            params["reply_markup"] = kb
        res = call(cfg, "sendMessage", params) or {}
        box["sent"][gid] = {"message_id": res.get("message_id"), "chat_id": chat, "at": int(now())}
        save_inbox(H, main, box)
    # 别处答复了的（终端、看板、GitHub）：把消息改成结果、去掉按钮；卡没了的不再跟踪
    for gid, s in list(box["sent"].items()):
        if s.get("closed") or s.get("chat_id") != chat or gid in open_ids:
            continue
        st, meta = H.gate_state(main, gid), H.read_meta(main, gid)
        if st == "unknown":
            continue
        if st == "answered" and meta:
            call(cfg, "editMessageText", {"chat_id": chat, "message_id": s.get("message_id"),
                                          "text": (gate_text(meta) + "\n\n" + answer_line(H, main, gid, meta))[:4000]})
        s["closed"] = True
        save_inbox(H, main, box)


def run_cycle(H, main: Path) -> int:
    if not load_cfg(H).get("token"):
        print("还没设置 Telegram：先在你的终端里跑 harness inbox setup", file=sys.stderr)
        return 1
    with cycle_lock(H, main):
        cfg, box, poll = load_cfg(H), load_inbox(H, main), poll_secs()
        ups = call(cfg, "getUpdates", {"offset": int(box.get("offset") or 0), "timeout": poll,
                                       "allowed_updates": ["message", "callback_query"]}, timeout=poll + 15)
        for u in ups if isinstance(ups, list) else []:
            if not isinstance(u, dict) or not isinstance(u.get("update_id"), int):
                continue
            box["offset"] = max(int(box.get("offset") or 0), u["update_id"] + 1)
            save_inbox(H, main, box)   # 先前移 offset：处理出错也不会反复处理同一条
            cfg = load_cfg(H)
            if isinstance(u.get("callback_query"), dict):
                handle_callback(H, main, cfg, box, u["callback_query"])
            elif isinstance(u.get("message"), dict) and not cfg.get("paired_user_id"):
                handle_pair(H, cfg, u["message"])
            # 其余（已配对后的任何文字，包括 /pair）一律不理：不接受自由文本指令
        cfg = load_cfg(H)
        if cfg.get("paired_user_id") and cfg.get("chat_id") is not None:
            push_gates(H, main, cfg, box)
    return 0


def run(H, main: Path, once: bool) -> int:
    def tok() -> str:
        return str(load_cfg(H).get("token") or "")
    if once:
        try:
            return run_cycle(H, main)
        except ApiError as e:
            print(f"✗ {clean(e, tok())}", file=sys.stderr)
        except Exception as e:
            print(f"✗ 收件箱出错：{clean(f'{type(e).__name__}: {e}', tok())}", file=sys.stderr)
        return 1
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    fails = 0
    while True:
        t = time.time()
        try:
            fails = 0 if run_cycle(H, main) == 0 else fails + 1
        except Exception as e:
            fails += 1
            print(f"✗ {clean(f'{type(e).__name__}: {e}', tok())}", file=sys.stderr, flush=True)
        time.sleep(min(60, 2 ** fails) if fails else max(0.0, 1.0 - (time.time() - t)))


# ---------------------------------------------------------------- setup
def setup(H) -> int:
    old = load_cfg(H)
    try:
        token = getpass.getpass("Telegram bot token（找 @BotFather 要；输入不显示，直接回车 = 保留原来的）：").strip()
    except (EOFError, KeyboardInterrupt):
        token = ""
    token = token or str(old.get("token") or "")
    if not TOKEN_RE.fullmatch(token):
        print("✗ 这不像 bot token（形如 123456789:AA…），没保存", file=sys.stderr)
        return 2
    cfg = {"token": token, "paired_user_id": None, "chat_id": None,
           "api": os.environ.get("HARNESS_TELEGRAM_API") or old.get("api") or DEFAULT_API}
    name = ""
    try:
        name = str((call(cfg, "getMe", {}, timeout=15) or {}).get("username") or "")
    except ApiError as e:
        if "401" in str(e):
            print("✗ Telegram 说这个 token 无效，没保存", file=sys.stderr)
            return 1
        print(f"! 暂时连不上 Telegram，先保存（{clean(e, token)}）", file=sys.stderr)
    code = f"{secrets.randbelow(10 ** 6):06d}"
    cfg.update({"pair_sha256": _sha(code), "pair_expires": now() + PAIR_TTL, "pair_tries": 0})
    save_cfg(H, cfg)
    who = f"@{name}" if re.fullmatch(r"[A-Za-z0-9_]{1,64}", name) else "你的 bot"
    print(f"在 Telegram 里给 {who} 发：/pair {code}")
    print("配对码 10 分钟内有效、只能用一次；重新配对就重跑 harness inbox setup。")
    print(f"token 存在 {cfg_path(H)}（权限 600，只在这台电脑上）。配好后跑 harness inbox start。")
    return 0


# ---------------------------------------------------------------- 后台 bot
def run_dir(H, main: Path) -> Path:
    return H.state_dir(main) / "run"


def live_bots(H, main: Path) -> list:
    """[(pid 文件, (pid, starttime))]：核验过还在跑的 bot；过期的 pid 文件顺手删掉。"""
    rd, out = run_dir(H, main), []
    for p in sorted(rd.glob("inbox-*.pid")) if rd.is_dir() else []:
        rec = D.read_pid(p)
        if rec and D.ours(*rec):
            out.append((p, rec))
        else:
            p.unlink(missing_ok=True)
    return out


def start(H, main: Path) -> int:
    cfg = load_cfg(H)
    if not cfg.get("token"):
        print("还没设置 Telegram：先在你的终端里跑 harness inbox setup", file=sys.stderr)
        return 1
    bots = live_bots(H, main)
    if bots:
        print(f"收件箱已经在跑：pid {bots[0][1][0]}")
        return 0
    rd = run_dir(H, main)
    rd.mkdir(parents=True, exist_ok=True)
    log = H.state_dir(main) / "inbox.log"
    env = H.scrub_env(dict(os.environ))   # bot 不需要别的凭证；token 只从配置文件读
    env.pop("HARNESS_STRICT", None)
    fd = os.open(str(log), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as lf:
        p = subprocess.Popen([sys.executable, str(PKG / "bin" / "harness"), "inbox", "run", "--repo", str(main)],
                             stdin=subprocess.DEVNULL, stdout=lf, stderr=lf, env=env, cwd=str(main),
                             start_new_session=True, close_fds=True)
    st = D.starttime(p.pid)
    tmp = rd / f".inbox-{p.pid}.tmp"
    tmp.write_text(f"{p.pid} {st}" if st else str(p.pid), encoding="utf-8")
    os.replace(tmp, rd / f"inbox-{p.pid}.pid")
    print(f"收件箱已启动：pid {p.pid}（日志 {log}）"
          + ("" if cfg.get("paired_user_id") else "；还没配对：在 Telegram 里发 /pair <码>"))
    return 0


def stop(H, main: Path) -> int:
    bots = live_bots(H, main)
    if not bots:
        print("收件箱没在跑")
        return 0
    rc = 0
    for pf, rec in bots:
        try:
            os.kill(rec[0], signal.SIGTERM)
        except OSError:
            pass
        deadline = time.time() + 5
        while time.time() < deadline and D.same(*rec):
            time.sleep(0.1)
        if D.same(*rec):
            print(f"✗ {rec[0]} 收到 SIGTERM 后未停止，保留 pid 文件；需要的话手动 kill {rec[0]}", file=sys.stderr)
            rc = 1
        else:
            pf.unlink(missing_ok=True)
            print(f"已停止收件箱：pid {rec[0]}")
    return rc


def status(H, main: Path) -> int:
    cfg = load_cfg(H)
    bots = live_bots(H, main)
    print(f"收件箱在跑：pid {' '.join(str(b[1][0]) for b in bots)}" if bots else "收件箱没在跑")
    if not cfg.get("token"):
        print("还没设置（harness inbox setup）")
    else:
        print("已配对" if cfg.get("paired_user_id") else "还没配对（在 Telegram 里发 /pair <码>）")
    n = sum(1 for s in load_inbox(H, main)["sent"].values() if not s.get("closed"))
    print(f"等你答复的门卡消息：{n}")
    return 0


def main(argv: list, pkg_root: str = "") -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    sub, repo = argv[0], D._repo_arg(argv)
    H = D._lib(repo)
    root = D.main_repo(repo)
    fn = {"setup": lambda: setup(H), "run": lambda: run(H, root, "--once" in argv), "start": lambda: start(H, root),
          "stop": lambda: stop(H, root), "status": lambda: status(H, root)}.get(sub)
    if not fn:
        print(f"未知子命令：inbox {sub}（harness inbox --help）", file=sys.stderr)
        return 2
    return fn()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], str(PKG)))
