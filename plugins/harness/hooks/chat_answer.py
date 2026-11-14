#!/usr/bin/env python3
"""对话内答复门卡（S-002 #13，T-015；接口约定 v2）。

- UserPromptSubmit：用户消息（strip 后）恰好是 `G-x-n: L [备注]` → 写答案库，via 对话。
- PreToolUse(AskUserQuestion)（T-019）：有门卡题且 tool_input 出现 answers（预填）→ permissionDecision deny
  （判定在 import harness_lib 之前，库坏了也照样拒）；门卡题没有 answers → 写一次性标记
  state_dir/chat/<tool_use_id>.pre（0600，顺手清掉 24 小时前的）。从不输出 allow，不写答案库。
- PostToolUse(AskUserQuestion)：question 以 `<GID>：` 开头且其后正好是快照标题、header 缺省/空/同一门卡号、
  每个 label 恰为 `<L> <快照选项 L 原文>` → 按所选 label 写答案库。答案取 tool_input.answers（真机格式），
  不是 dict 时退回 tool_response.answers（旧格式）；annotations 忽略；Other 自由输入、多选题不记录。
  fail-closed：只认有同一 tool_use_id 标记的调用（先删标记，一次性），没有标记 → 整张不记录。

只经 harness_lib.record_answer 写库，先 snapshot_meta；字母不在快照里、门卡含义与快照不同、有后续效果的门卡选 A
→ 不记录，请人在终端（或看板 / Telegram）答复。每个结果都经 systemMessage 给人看。
无人值守 / strict / 非交互（claude -p、SDK、interactive:false）/ 嵌套（HARNESS_NESTED=1 或父进程链上 ≥ 2 个
Claude Code）时不生效。永远退出 0，字段不认识就静默。不调 settle：镜像与 decisions.md 由 gate-sync 的 settle_pending 补。
"""
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees

PROMPT_RE = re.compile(r"(G-[A-Za-z0-9-]+):\s*([A-Z])(\s+.*)?")  # fullmatch, no DOTALL
QUESTION_RE = re.compile(r"(G-[A-Za-z0-9-]+)[:：](.*)", re.S)     # match at position 0: nothing before the id
# Same pattern as harness_lib.GID_RE: the pre-fill check runs before harness_lib is imported (a broken lib still denies).
GID_RE = re.compile(r"G-[A-Za-z0-9]+-[A-Za-z0-9-]+")
TUID_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")
MARKER_TTL = 86400  # leftovers of Esc-cancelled calls
EFFECT_FREE = {"ui", "sensory", "ambiguity"}
EFFECT_KEYS = ("then", "then_tasks", "then_policy", "then_rules", "paths")


# ---------------------------------------------------------------- when the channel is off
def _claude_count(max_depth: int = 64) -> int:
    """Claude Code processes on the parent chain (ps fails -> 1: never switch the channel off because of it)."""
    n, pid = 0, os.getppid()
    for _ in range(max_depth):
        if pid <= 1:
            break
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=,args=", "-p", str(pid)], capture_output=True,
                                 text=True, timeout=5).stdout.strip()
        except Exception:
            return max(n, 1)
        if not out:
            break
        parts = out.split(None, 2)
        if len(parts) < 2 or not parts[0].isdigit():
            return max(n, 1)
        comm, args = parts[1], (parts[2] if len(parts) > 2 else "").split()
        if os.path.basename(comm) == "claude" or any(os.path.basename(a) == "claude" for a in args[:2]):
            n += 1
        pid = int(parts[0])
    return n


def off_cheap(data: dict) -> bool:
    env = os.environ
    return (env.get("HARNESS_UNATTENDED") == "1" or env.get("HARNESS_STRICT") == "1"
            or env.get("HARNESS_NESTED") == "1" or env.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk")
            or data.get("interactive") is False)


def nested() -> bool:
    return _claude_count() >= 2


# ---------------------------------------------------------------- recording
def has_effect(H, main, gid: str, meta: dict) -> bool:
    if str(meta.get("kind") or "") not in EFFECT_FREE:
        return True
    if any(meta.get(k) for k in EFFECT_KEYS):
        return True
    return H.read_pr(main, gid) is not None


def record(H, main, gid: str, letter: str, note: str = "", meta: dict | None = None) -> list:
    """-> lines for the human and Claude. Writes only through record_answer."""
    if not H.valid_gid(gid):
        return []
    cmd = H.lib_cmd(main)
    meta = meta or H.snapshot_meta(main, gid)
    if not meta:
        return [f"{gid}：找不到这张门卡，没有记录。"]
    letters = H.meta_letters(meta)
    if letter not in letters:
        return [f"{gid}：没有选项 {letter}（可选：{'/'.join(letters)}），没有记录。"]
    state = H.gate_state(main, gid)
    if state == "unknown":
        return [f"{gid}：答案库读不了，没有记录；请在终端运行 `{cmd} answer {gid} {letter}`。"]
    if state == "answered":
        prev = H.read_answer(main, gid) or {}
        return [f"{gid}：已答复过（{prev.get('letter', '?')}，via {prev.get('via', '?')}），只认第一次，没有记录。"]
    card = H.find_gate_card(main, gid)
    diff = H.meaning_diff(meta, card) if card else []
    if diff:
        return [f"{gid}：门卡的类别 / 问题 / 选项和控制面第一次见到时不同，没有记录（" + "；".join(diff)
                + f"）。确认按快照答复：请在终端运行 `{cmd} answer {gid} {letter} --yes`。"]
    if letter == "A" and has_effect(H, main, gid, meta):
        return [f"{gid}：选 A 会触发后续动作，对话里不记录；请在终端运行 `{cmd} answer {gid} A`，"
                "或在看板 / Telegram 答复。门卡仍未答复。"]
    if H.record_answer(main, gid, letter, note, via="对话"):
        return [f"已记录 {gid}: {letter}"]
    return [f"{gid}：已答复过，只认第一次，没有记录。"]


def on_prompt(H, main, data: dict) -> list:
    prompt = data.get("prompt")
    if not isinstance(prompt, str):
        return []
    m = PROMPT_RE.fullmatch(prompt.strip())
    if not m or not H.valid_gid(m.group(1)) or nested():
        return []
    return record(H, main, m.group(1), m.group(2), (m.group(3) or "").strip())


def ask_one(H, main, q: dict, gid: str, answers, cmd: str) -> list:
    question, opts = q["question"], q.get("options")
    mismatch = (f"{gid}：选项卡和门卡快照不符（问题须是「{gid}：<门卡标题>」，header 留空或写门卡号，"
                f"每个选项 label 须是「<字母> <选项原文>」），没有记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。")
    if "header" in q and q["header"] not in ("", gid):
        return [mismatch]
    if q.get("multiSelect"):
        return [f"{gid}：门卡题是多选，对话里不记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。"]
    if (not isinstance(answers, dict) or question not in answers
            or not isinstance(opts, list) or not opts or not all(isinstance(o, dict) for o in opts)):
        return [f"{gid}：没取到选项卡的答案，没有记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。"]
    meta = H.snapshot_meta(main, gid)
    if not meta:
        return [f"{gid}：找不到这张门卡，没有记录。"]
    canon = {f"{L} {H.meta_option(meta, L)}": L for L in H.meta_letters(meta)}
    labels = [o.get("label") for o in opts]
    title = QUESTION_RE.match(question).group(2).strip()
    if title != str(meta.get("title", "")) or not all(isinstance(lb, str) and lb in canon for lb in labels):
        return [mismatch]
    val = answers[question]
    if not isinstance(val, str) or val not in labels:
        return [f"{gid}：所选不是选项卡里的单个选项（Other 自由输入 / 多选不记录），没有记录；"
                f"请在终端运行 `{cmd} answer {gid} <字母>` 答复。"]
    return record(H, main, gid, canon[val], meta=meta)


def ask_questions(data: dict):
    """-> (tool_input, [(question dict, gid)]) for an AskUserQuestion call; stdlib only (no harness_lib)."""
    if data.get("tool_name") != "AskUserQuestion":
        return None, []
    ti = data.get("tool_input")
    qs = ti.get("questions") if isinstance(ti, dict) else None
    if not isinstance(qs, list):
        return None, []
    out = []
    for q in qs:
        if isinstance(q, dict) and isinstance(q.get("question"), str):
            m = QUESTION_RE.match(q["question"])
            if m and GID_RE.fullmatch(m.group(1)):
                out.append((q, m.group(1)))
    return ti, out


def tool_use_id(data: dict):
    v = data.get("tool_use_id")
    return v if isinstance(v, str) and TUID_RE.fullmatch(v) else None


def chat_dir(H, main) -> str:
    return os.path.join(str(H.state_dir(main)), "chat")


def write_marker(H, main, tuid: str) -> None:
    """state_dir/chat/<tool_use_id>.pre: dir 0700, file 0600, O_EXCL|O_NOFOLLOW; existing -> left alone."""
    try:
        d = chat_dir(H, main)
        os.makedirs(d, mode=0o700, exist_ok=True)
        if os.path.islink(d):
            return
        os.chmod(d, 0o700)
        cutoff = time.time() - MARKER_TTL
        for name in os.listdir(d):
            p = os.path.join(d, name)
            try:
                if name.endswith(".pre") and os.lstat(p).st_mtime < cutoff:
                    os.unlink(p)
            except OSError:
                pass
        fd = os.open(os.path.join(d, tuid + ".pre"), os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, b"pre\n")
        finally:
            os.close(fd)
    except OSError:
        pass


def take_marker(H, main, tuid) -> bool:
    """Consume the marker (single use): True only if this call removed it."""
    if not tuid:
        return False
    try:
        os.unlink(os.path.join(chat_dir(H, main), tuid + ".pre"))
        return True
    except OSError:
        return False


def prefill_reason(data: dict, found: list) -> str:
    cwd = data.get("cwd")
    root = cwd if isinstance(cwd, str) and cwd else os.getcwd()
    cmd = ("python3 .claude/hooks/harness_lib.py" if os.path.exists(os.path.join(root, ".claude/hooks/harness_lib.py"))
           else "python3 .harness/lib/harness_lib.py")
    gids = list(dict.fromkeys(gid for _, gid in found))
    return "\n".join(f"{gid}：选项卡调用里带了预填答案，已拒绝这次调用；请去掉 answers 重新弹选项卡让人自己选，"
                     f"或请人在终端运行 `{cmd} answer {gid} <字母>` 答复。" for gid in gids)


def on_ask(H, main, data: dict) -> list:
    ti, found = ask_questions(data)
    found = [(q, gid) for q, gid in found if H.valid_gid(gid)]
    if not found or nested():
        return []
    cmd = H.lib_cmd(main)
    if not take_marker(H, main, tool_use_id(data)):  # fail-closed: PreToolUse never saw (or denied) this call
        return [f"{gid}：这次选项卡没有经过调用前检查（PreToolUse），没有记录；"
                f"请在终端运行 `{cmd} answer {gid} <字母>` 答复。" for gid in dict.fromkeys(g for _, g in found)]
    tr = data.get("tool_response")
    answers = ti.get("answers")  # real format: the user's choice is here (pre-fills were denied at PreToolUse)
    if not isinstance(answers, dict):
        answers = tr.get("answers") if isinstance(tr, dict) else None  # older format
    out = []
    for q, gid in found:
        out += ask_one(H, main, q, gid, answers, cmd)
    return out


def run() -> None:
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    try:
        data = json.loads(raw)
    except ValueError:
        return
    if not isinstance(data, dict) or off_cheap(data):
        return
    ev = data.get("hook_event_name")
    if ev not in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
        return
    if ev == "PreToolUse":
        ti, found = ask_questions(data)
        if not found:
            return  # not a gate card call: never touched
        if "answers" in ti:  # pre-filled: denied before any heavy import; never an 'allow' otherwise
            reason = prefill_reason(data, found)
            print(json.dumps({"hookSpecificOutput": {"hookEventName": ev, "permissionDecision": "deny",
                                                     "permissionDecisionReason": reason},
                              "systemMessage": reason}, ensure_ascii=False))
            return
        tuid = tool_use_id(data)
        if not tuid:
            return
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import harness_lib as H
    cwd = data.get("cwd")
    main = H.store_main(cwd if isinstance(cwd, str) and cwd else os.getcwd())
    if ev == "PreToolUse":
        write_marker(H, main, tuid)
        return
    lines = on_prompt(H, main, data) if ev == "UserPromptSubmit" else on_ask(H, main, data)
    if lines:
        text = "\n".join(lines)
        print(json.dumps({"systemMessage": text,
                          "hookSpecificOutput": {"hookEventName": ev, "additionalContext": text}},
                         ensure_ascii=False))


if __name__ == "__main__":
    try:
        run()
    except BaseException:  # a hook never blocks or crashes the session
        pass
    sys.exit(0)
