"""harness inbox：Telegram 收件箱。门卡推到你的 Telegram，点按钮就是答复（写进答案库，via Telegram）。

  harness inbox setup  [--repo DIR]          在终端里输入 bot token（不回显），显示一次性配对码（10 分钟有效）
  harness inbox run    [--once] [--repo DIR] 轮询（≤ 20 秒长轮询）：处理配对与按钮，给新的门卡发消息
  harness inbox start | stop | status [--repo DIR]   后台 bot（pid 文件在 state_dir/run/inbox-<pid>.pid）

配置 $XDG_CONFIG_HOME/harness/telegram.json（600）：token 只在这里，不进仓库、日志、命令行和 Claude 的环境。
只认配对过的那个人；按钮只带「门卡号|字母」，消息正文只取控制面的门卡快照；
点 A 一律要再点一次确认；其他选项点一次就记。门卡连续 3 个周期找不到才关掉对应消息。
一个 token 只跑一个 bot（记录在 config_dir/inbox-bot.pid）：bot 在跑时任何仓库的 run / run --once 都拒绝，
stop / status 从任何仓库都能找到它。setup 把配置目录与状态目录加进 ~/.claude/settings.json 的 permissions.deny。
不接受自由文本指令。
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
from cli import init_cmd  # noqa: E402  settings.json 的 deny 合并

DEFAULT_API = "https://api.telegram.org"
PAIR_TTL = 600          # 配对码有效期（秒）
PAIR_TRIES = 5          # 每个 Telegram 用户最多试错几次（按 from.id 计）
PAIR_KEYS = ("pair_sha256", "pair_expires", "pair_tries")
MISSING_CYCLES = 3      # 门卡连续几个周期找不到才关掉消息
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


def soft(cfg: dict, method: str, params: dict):
    """改消息 / 应答回调：出错只记日志，本周期继续（答案已入库，消息只是显示）。-> 结果；出错 -> None"""
    try:
        return call(cfg, method, params)
    except ApiError as e:
        print(f"! {method} 失败：{clean(e, str(cfg.get('token') or ''))}", file=sys.stderr, flush=True)
        return None


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
    # 含义行（同 GitHub 通道，全部取自快照）
    if meta.get("kind") in APPROVAL:
        lines.append("选 A = 批准，其他 = 拒绝")
    if meta.get("then") == "ready":
        lines.append("批准后变为 ready：" + ", ".join(meta.get("then_tasks") or [meta.get("task") or "-"]))
    if meta.get("paths") or meta.get("kind") == "unlock":
        lines.append("批准后放开：" + (", ".join(str(p) for p in meta.get("paths") or []) or "（快照里没有路径）"))
    if meta.get("then_policy"):
        lines.append(f"批准后放权：{meta['then_policy']} 类门卡")
    if meta.get("then_rules"):
        lines.append("批准后写入原则：" + "；".join(meta["then_rules"]))
    lines.append("点 A 后还要再确认一次。")
    return "\n".join(lines)[:MAX_TEXT]


APPROVAL = {"irreversible", "unlock", "external"}   # = harness_lib.APPROVAL_KINDS


def btn_label(meta: dict, letter: str) -> str:
    if meta.get("kind") in APPROVAL:
        lab = f"{letter} 批准" if letter == "A" else f"{letter} 拒绝"
    else:
        lab = letter
    return lab + ("（推荐）" if letter == meta.get("recommended") else "")


def keyboard(H, meta: dict) -> dict | None:
    gid = meta.get("gid", "")
    ls = letters(H, meta)
    if is_policy(meta) or not all(len(f"{gid}|{l}|ok".encode()) <= 64 for l in ls):
        return None
    row = [{"text": btn_label(meta, l), "callback_data": f"{gid}|{l}"} for l in ls]
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
def drop_pairing(H, cfg: dict) -> None:
    if any(k in cfg for k in PAIR_KEYS):
        for k in PAIR_KEYS:
            cfg.pop(k, None)
        save_cfg(H, cfg)


def expire_pairing(H, cfg: dict) -> None:
    """过期的配对码在下个周期清掉（telegram.json 只留 token / paired_user_id / chat_id / api）。"""
    try:
        expires = float(cfg.get("pair_expires") or 0)
    except (TypeError, ValueError):
        expires = 0.0
    if any(k in cfg for k in PAIR_KEYS) and (not cfg.get("pair_sha256") or now() > expires):
        drop_pairing(H, cfg)


def handle_pair(H, cfg: dict, msg: dict) -> None:
    """/pair <码>：只认 setup 显示的一次性码（10 分钟内、私聊）。错了不回复；每个人最多试 5 次（按 from.id），
    陌生人猜错不会废掉你的码。群聊里的 /pair 不理。"""
    m = PAIR_RE.fullmatch(str(msg.get("text") or "").strip())
    frm, chat = msg.get("from") or {}, msg.get("chat") or {}
    uid = frm.get("id")
    if (not m or not cfg.get("pair_sha256") or chat.get("type") != "private" or frm.get("is_bot")
            or not isinstance(uid, int) or isinstance(uid, bool) or chat.get("id") != uid):
        return
    expire_pairing(H, cfg)
    if not cfg.get("pair_sha256"):
        return
    tries = cfg.get("pair_tries") if isinstance(cfg.get("pair_tries"), dict) else {}
    if int(tries.get(str(uid)) or 0) >= PAIR_TRIES:
        return
    if not hmac.compare_digest(_sha(m.group(1)), str(cfg["pair_sha256"])):
        tries[str(uid)] = int(tries.get(str(uid)) or 0) + 1
        cfg["pair_tries"] = tries
        save_cfg(H, cfg)
        return
    for k in PAIR_KEYS:
        cfg.pop(k, None)
    cfg["paired_user_id"], cfg["chat_id"] = uid, chat.get("id")
    save_cfg(H, cfg)
    soft(cfg, "sendMessage", {"chat_id": cfg["chat_id"], "text": "已配对：新的门卡会发到这里，点按钮就是答复。"})


def mine(cfg: dict, frm: dict, chat: dict) -> bool:
    uid = cfg.get("paired_user_id")
    return (isinstance(uid, int) and not isinstance(uid, bool) and frm.get("id") == uid
            and chat.get("id") == cfg.get("chat_id") and not frm.get("is_bot"))


def handle_callback(H, main: Path, cfg: dict, box: dict, cq: dict) -> None:
    msg = cq.get("message") or {}
    if not mine(cfg, cq.get("from") or {}, msg.get("chat") or {}):
        return  # 陌生人：不理，不回复

    def reply(text: str):
        soft(cfg, "answerCallbackQuery", {"callback_query_id": cq.get("id"), "text": text})

    m = DATA_RE.fullmatch(str(cq.get("data") or ""))
    gid = m.group(1) if m else ""
    sent = box["sent"].get(gid) if m and H.valid_gid(gid) else None
    mid = msg.get("message_id")
    # 按钮必须来自我们发给这个聊天的那条门卡消息（或确认那步另发的那条）
    if (not sent or sent.get("chat_id") != cfg.get("chat_id") or mid is None
            or mid not in (sent.get("message_id"), sent.get("confirm_mid"))):
        return reply("这个按钮无效")
    letter, ok = m.group(2), bool(m.group(3))
    meta = H.read_meta(main, gid)
    st = H.gate_state(main, gid)
    if st == "answered":
        return reply("已经答过了")
    if sent.get("closed"):
        return reply("这条消息已失效，请点新发的那条")
    if st != "open" or not meta:
        return reply("答案库读不了，这张门卡的状态未知")
    if is_policy(meta):
        return reply("这张只能在 GitHub 上或你的终端里批准")
    if letter not in letters(H, meta):
        return reply("没有这个选项")
    if ok and (letter != "A" or sent.get("confirm") != letter):
        return reply("先点选项，再点确认")   # 没点过第一次的「确认」无效
    if not ok and letter == "A":   # 批准一律要再点一次确认
        sent["confirm"] = letter
        save_inbox(H, main, box)
        others = [{"text": "改选 " + btn_label(meta, l), "callback_data": f"{gid}|{l}"}
                  for l in letters(H, meta) if l != letter]
        kb = {"inline_keyboard": [[{"text": "确认 " + btn_label(meta, letter), "callback_data": f"{gid}|{letter}|ok"}]]
              + ([others] if others else [])}
        opt = H.meta_option(meta, letter)
        text = (full_text(H, meta) + f"\n\n要选 {letter}" + (f"（{opt}）" if opt and "<" not in opt else "")
                + " 吗？再点一次「确认」才算数。")[:4000]
        if soft(cfg, "editMessageText", {"chat_id": cfg["chat_id"], "message_id": mid, "text": text,
                                         "reply_markup": kb}) is None:
            # 改不了原消息：另发一条带确认按钮的新消息，在它上面点确认也有效
            res = soft(cfg, "sendMessage", {"chat_id": cfg["chat_id"], "text": text, "reply_markup": kb})
            if isinstance(res, dict) and res.get("message_id") is not None:
                sent["confirm_mid"] = res["message_id"]
                save_inbox(H, main, box)
        return reply("再点一次「确认 " + letter + "」")
    recorded, _status, _tid = H.answer_gate(main, gid, letter, "", "Telegram")   # 写库 + 镜像 + 接续
    if not recorded:
        return reply("已经答过了" if H.gate_state(main, gid) == "answered" else "没记上（答案库写不了？）")
    sent["closed"] = True   # 先记下关掉，再改消息（改消息失败也不会再被当成开着的）
    sent.pop("confirm", None)
    save_inbox(H, main, box)
    done = (gate_text(meta) + "\n\n" + answer_line(H, main, gid, meta))[:4000]
    for m_id in dict.fromkeys(x for x in (sent.get("message_id"), sent.get("confirm_mid")) if x is not None):
        soft(cfg, "editMessageText", {"chat_id": cfg["chat_id"], "message_id": m_id, "text": done})
    reply(f"已记录：{letter}")


def push_gates(H, main: Path, cfg: dict, box: dict) -> None:
    chat = cfg.get("chat_id")
    open_ids = open_gate_ids(H, main)
    for gid in open_ids:
        s = box["sent"].get(gid)
        if s and s.get("chat_id") == chat and not s.get("closed"):
            if s.get("missing"):
                s["missing"] = 0   # 中途又出现：重新计数，不重发
                save_inbox(H, main, box)
            continue   # 已发且还开着；关掉过的（卡消失过）再出现就重发
        meta = H.snapshot_meta(main, gid)   # 第一次看到就冻结含义；之后改卡不影响消息
        if not meta:
            continue
        params = {"chat_id": chat, "text": full_text(H, meta)}
        kb = keyboard(H, meta)
        if kb:
            params["reply_markup"] = kb
        try:
            res = call(cfg, "sendMessage", params) or {}
        except ApiError as e:
            print(f"! 发 {gid} 失败：{clean(e, str(cfg.get('token') or ''))}", file=sys.stderr, flush=True)
            continue
        box["sent"][gid] = {"message_id": res.get("message_id"), "chat_id": chat, "at": int(now())}
        save_inbox(H, main, box)
    # 别处答复了的（终端、看板、GitHub）：先标关掉，再把消息改成结果、去掉按钮；
    # 卡连续 MISSING_CYCLES 个周期找不到才关掉（git 切分支、改名时卡会短暂消失）
    for gid, s in list(box["sent"].items()):
        if s.get("closed") or s.get("chat_id") != chat or gid in open_ids:
            continue
        st, meta = H.gate_state(main, gid), H.read_meta(main, gid)
        if st == "unknown":
            continue
        if st != "answered":
            s["missing"] = int(s.get("missing") or 0) + 1
            if s["missing"] < MISSING_CYCLES:
                save_inbox(H, main, box)
                continue
        s["closed"] = True
        s.pop("confirm", None)
        save_inbox(H, main, box)
        if st == "answered" and meta:
            done = (gate_text(meta) + "\n\n" + answer_line(H, main, gid, meta))[:4000]
            for m_id in dict.fromkeys(x for x in (s.get("message_id"), s.get("confirm_mid")) if x is not None):
                soft(cfg, "editMessageText", {"chat_id": chat, "message_id": m_id, "text": done})


def run_cycle(H, main: Path) -> int:
    if not load_cfg(H).get("token"):
        print("还没设置 Telegram：先在你的终端里跑 harness inbox setup", file=sys.stderr)
        return 1
    with cycle_lock(H, main):
        cfg, box, poll = load_cfg(H), load_inbox(H, main), poll_secs()
        expire_pairing(H, cfg)
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


def other_bot(H):
    """这个 token 在跑的 bot（不是本进程）-> (pid, starttime) | None；过期记录顺手删掉。"""
    f = bot_file(H)
    rec = D.read_pid(f) if f.exists() else None
    if rec and rec[0] != os.getpid() and D.ours(*rec):
        return rec
    if rec and rec[0] != os.getpid():
        f.unlink(missing_ok=True)
    return None


def refuse(rec) -> int:
    print(f"✗ 这个 token 已经有 bot 在跑：pid {rec[0]}（仓库 {bot_repo(rec[0])}）。一个 token 只能跑一个 bot："
          f"用 harness inbox stop 停掉它再来", file=sys.stderr)
    return 1


def run(H, main: Path, once: bool) -> int:
    def tok() -> str:
        return str(load_cfg(H).get("token") or "")
    if once:
        with start_lock(H):
            rec = other_bot(H)
        if rec:
            return refuse(rec)
        try:
            return run_cycle(H, main)
        except ApiError as e:
            print(f"✗ {clean(e, tok())}", file=sys.stderr)
        except Exception as e:
            print(f"✗ 收件箱出错：{clean(f'{type(e).__name__}: {e}', tok())}", file=sys.stderr)
        return 1
    with start_lock(H):   # 前台 run 也占用「这个 token 的 bot」（start 起的子进程会看到自己的 pid）
        rec = other_bot(H)
        if rec:
            return refuse(rec)
        st = D.starttime(os.getpid())
        if (D.read_pid(bot_file(H)) if bot_file(H).exists() else None) != (os.getpid(), st):
            write_pid(bot_file(H), os.getpid(), st)
    me = (os.getpid(), D.starttime(os.getpid()))

    def bye(*_):
        if (D.read_pid(bot_file(H)) if bot_file(H).exists() else None) == me:
            bot_file(H).unlink(missing_ok=True)
        sys.exit(0)
    signal.signal(signal.SIGTERM, bye)
    fails = 0
    try:
        while True:
            t = time.time()
            try:
                fails = 0 if run_cycle(H, main) == 0 else fails + 1
            except Exception as e:
                fails += 1
                print(f"✗ {clean(f'{type(e).__name__}: {e}', tok())}", file=sys.stderr, flush=True)
            # 出错后的等待不超过 HARNESS_TELEGRAM_POLL：API 恢复后很快接上
            time.sleep(min(poll_secs(), 2 ** fails) if fails else max(0.0, 1.0 - (time.time() - t)))
    except KeyboardInterrupt:
        bye()


# ---------------------------------------------------------------- setup
def setup(H, root: Path) -> int:
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
    # 让 Claude 读不到 token 与答案库：加进用户级 ~/.claude/settings.json 的 permissions.deny
    # （init 的合并逻辑：不覆盖已有键与规则、不重复）。仓库里受版本管理的 settings.json 不动，机器路径不进仓库。
    notes: list = []
    want = [f"Read(/{H.config_dir().resolve()}/**)", f"Read(/{H.state_dir(root).resolve()}/**)"]
    n = init_cmd.merge_deny(Path(os.environ.get("HOME") or Path.home()), want, notes)
    for line in notes:
        print(f"! {line}", file=sys.stderr)
    if n:
        print(f"已在 ~/.claude/settings.json 的 permissions.deny 里加了 {n} 条：Claude 读不到 token 和答案库。")
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


def bot_file(H) -> Path:
    """一个 token 一个 bot：在跑的那个记在 config_dir（"<pid> <starttime>"，T-013 格式）。"""
    return H.config_dir() / "inbox-bot.pid"


def bot_repo(pid: int) -> str:
    a = D.cmdline(pid).split()
    return a[a.index("--repo") + 1] if "--repo" in a and a.index("--repo") + 1 < len(a) else "?"


@contextlib.contextmanager
def start_lock(H):
    """并发 start 互斥：检查、启动、写 pid 文件是一步。"""
    d = H.config_dir()
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    try:
        import fcntl
    except ImportError:
        yield
        return
    with open(d / "inbox-start.lock", "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def write_pid(path: Path, pid: int, st) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(f"{pid} {st}" if st else str(pid), encoding="utf-8")
    os.replace(tmp, path)


def start(H, main: Path) -> int:
    cfg = load_cfg(H)
    if not cfg.get("token"):
        print("还没设置 Telegram：先在你的终端里跑 harness inbox setup", file=sys.stderr)
        return 1
    with start_lock(H):
        bots = live_bots(H, main)
        if bots:
            print(f"收件箱已经在跑：pid {bots[0][1][0]}")
            return 0
        rec = D.read_pid(bot_file(H)) if bot_file(H).exists() else None
        if rec and D.ours(*rec):
            print(f"✗ 这个 token 已经有 bot 在跑：pid {rec[0]}（仓库 {bot_repo(rec[0])}）。一个 token 只能跑一个 bot："
                  f"先在那边 harness inbox stop", file=sys.stderr)
            return 1
        bot_file(H).unlink(missing_ok=True)
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
        write_pid(rd / f"inbox-{p.pid}.pid", p.pid, st)
        write_pid(bot_file(H), p.pid, st)
    print(f"收件箱已启动：pid {p.pid}（日志 {log}）"
          + ("" if cfg.get("paired_user_id") else "；还没配对：在 Telegram 里发 /pair <码>"))
    return 0


def token_bots(H, main: Path) -> list:
    """[(pid 文件|None, (pid, starttime))]：本仓库的 bot，加上 config_dir 记录的这个 token 的 bot（可能在别的仓库）。"""
    out = live_bots(H, main)
    f = bot_file(H)
    rec = D.read_pid(f) if f.exists() else None
    if rec and D.ours(*rec):
        if all(r != rec for _p, r in out):
            out.append((None, rec))
    elif rec:
        f.unlink(missing_ok=True)
    return out


def stop(H, main: Path) -> int:
    bots = token_bots(H, main)
    if not bots:
        print("收件箱没在跑")
        return 0
    rc = 0
    for pf, rec in bots:
        repo = bot_repo(rec[0])   # 停之前读：进程没了就读不到命令行
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
            continue
        if pf:
            pf.unlink(missing_ok=True)
        elif repo != "?":   # 别的仓库的 bot：把它那边的 pid 文件也清掉
            (H.state_dir(Path(repo)) / "run" / f"inbox-{rec[0]}.pid").unlink(missing_ok=True)
        if (D.read_pid(bot_file(H)) if bot_file(H).exists() else None) == rec:
            bot_file(H).unlink(missing_ok=True)
        print(f"已停止收件箱：pid {rec[0]}")
    return rc


def status(H, main: Path) -> int:
    cfg = load_cfg(H)
    bots = token_bots(H, main)
    print(("收件箱在跑：" + "；".join(f"pid {r[0]}（仓库 {bot_repo(r[0])}）" for _p, r in bots)) if bots else "收件箱没在跑")
    if not cfg.get("token"):
        print("还没设置（harness inbox setup）")
    else:
        print("已配对" if cfg.get("paired_user_id") else "还没配对（在 Telegram 里发 /pair <码>）")
    n = sum(1 for s in load_inbox(H, main)["sent"].values() if not s.get("closed"))
    print(f"本仓库等你答复的门卡消息：{n}")
    return 0


def main(argv: list, pkg_root: str = "") -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    sub, repo = argv[0], D._repo_arg(argv)
    H = D._lib(repo)
    root = D.main_repo(repo)
    fn = {"setup": lambda: setup(H, root), "run": lambda: run(H, root, "--once" in argv), "start": lambda: start(H, root),
          "stop": lambda: stop(H, root), "status": lambda: status(H, root)}.get(sub)
    if not fn:
        print(f"未知子命令：inbox {sub}（harness inbox --help）", file=sys.stderr)
        return 2
    return fn()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], str(PKG)))
