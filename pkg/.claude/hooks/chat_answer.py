#!/usr/bin/env python3
"""对话内答复门卡（S-002 #13，T-015；接口约定 v2）。

- UserPromptSubmit：用户消息（strip 后）恰好是 `G-x-n: L [备注]` → 写答案库，via 对话。
- PostToolUse(AskUserQuestion)：question 以 `<GID>：` 开头且其后正好是快照标题、header 缺省/空/同一门卡号、
  每个 label 恰为 `<L> <快照选项 L 原文>` → 按所选 label 写答案库。只信 tool_response.answers；
  tool_input 里已有 answers（可能是 Claude 预填的）→ 本次一题都不记录。

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

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees

PROMPT_RE = re.compile(r"(G-[A-Za-z0-9-]+):\s*([A-Z])(\s+.*)?")  # fullmatch, no DOTALL
QUESTION_RE = re.compile(r"(G-[A-Za-z0-9-]+)[:：](.*)", re.S)     # match at position 0: nothing before the id
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


def gate_questions(H, qs: list) -> list:
    """[(question dict, gid)] for questions whose text starts with '<GID>：' / '<GID>:' (nothing before it)."""
    out = []
    for q in qs:
        if isinstance(q, dict) and isinstance(q.get("question"), str):
            m = QUESTION_RE.match(q["question"])
            if m and H.valid_gid(m.group(1)):
                out.append((q, m.group(1)))
    return out


def ask_one(H, main, q: dict, gid: str, answers, cmd: str) -> list:
    question, opts = q["question"], q.get("options")
    mismatch = (f"{gid}：选项卡和门卡快照不符（问题须是「{gid}：<门卡标题>」，header 留空或写门卡号，"
                f"每个选项 label 须是「<字母> <选项原文>」），没有记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。")
    if "header" in q and q["header"] not in ("", gid):
        return [mismatch]
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
        return [f"{gid}：所选不是选项卡里的单个选项，没有记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。"]
    return record(H, main, gid, canon[val], meta=meta)


def on_ask(H, main, data: dict) -> list:
    if data.get("tool_name") != "AskUserQuestion":
        return []
    ti, tr = data.get("tool_input"), data.get("tool_response")
    qs = ti.get("questions") if isinstance(ti, dict) else None
    if not isinstance(qs, list):
        return []
    found = gate_questions(H, qs)
    if not found or nested():
        return []
    cmd = H.lib_cmd(main)
    if "answers" in ti:  # pre-filled (possibly by Claude): nothing from this call counts
        return [f"{gid}：选项卡调用里带了预填答案，一题都不记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。"
                for _, gid in found]
    answers = tr.get("answers") if isinstance(tr, dict) else None  # never tool_input.answers
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
    if ev not in ("UserPromptSubmit", "PostToolUse"):
        return
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import harness_lib as H
    cwd = data.get("cwd")
    main = H.store_main(cwd if isinstance(cwd, str) and cwd else os.getcwd())
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
