#!/usr/bin/env python3
"""对话内答复门卡（S-002 #13，T-015）。

- UserPromptSubmit：用户消息（strip 后）恰好是 `G-x-n: L [备注]` → 写答案库，via 对话。
- PostToolUse(AskUserQuestion)：问题或 header 以门卡号开头、所选 label 是带字母前缀的选项 → 写答案库。
  只信 tool_response.answers（tool_input 里的 answers 可能是 Claude 自己填的）。

只经 harness_lib.record_answer 写库，先 snapshot_meta；字母不在快照里、门卡含义与快照不同 → 不记录，请人在终端答复。
无人值守 / strict / 非交互（claude -p、SDK、interactive:false）时不生效。永远退出 0，字段不认识就静默。
不调 settle：镜像与 decisions.md 由 gate-sync 的 settle_pending 补。
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees

PROMPT_RE = re.compile(r"(G-[A-Za-z0-9-]+):\s*([A-Z])(\s+.*)?")  # fullmatch, no DOTALL
HEAD_RE = re.compile(r"(G-[A-Za-z0-9-]+)\s*[:：]")
LABEL_RE = re.compile(r"([A-Z])(?:[\s：:.、)）]|$)")


def disabled(data: dict) -> bool:
    env = os.environ
    return (env.get("HARNESS_UNATTENDED") == "1" or env.get("HARNESS_STRICT") == "1"
            or env.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk") or data.get("interactive") is False)


def record(H, main, gid: str, letter: str, note: str = "") -> list:
    """-> lines for additionalContext. Writes only through record_answer."""
    if not H.valid_gid(gid):
        return []
    cmd = H.lib_cmd(main)
    meta = H.snapshot_meta(main, gid)
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
        return [f"{gid}：已答复过（{prev.get('letter', '?')}，via {prev.get('via', '?')}），只认第一次。"]
    card = H.find_gate_card(main, gid)
    diff = H.meaning_diff(meta, card) if card else []
    if diff:
        return [f"{gid}：门卡的类别 / 问题 / 选项和控制面第一次见到时不同，没有记录（" + "；".join(diff)
                + f"）。确认按快照答复：请在终端运行 `{cmd} answer {gid} {letter} --yes`。"]
    if H.record_answer(main, gid, letter, note, via="对话"):
        return [f"已记录 {gid}: {letter}"]
    return [f"{gid}：已答复过，只认第一次。"]


def on_prompt(H, main, data: dict) -> list:
    prompt = data.get("prompt")
    if not isinstance(prompt, str):
        return []
    m = PROMPT_RE.fullmatch(prompt.strip())
    if not m or not H.valid_gid(m.group(1)):
        return []
    return record(H, main, m.group(1), m.group(2), (m.group(3) or "").strip())


def gate_of(H, header, question) -> str | None:
    if isinstance(header, str) and H.valid_gid(header.strip()):
        return header.strip()
    for s in (header, question):
        if isinstance(s, str):
            m = HEAD_RE.match(s.lstrip())
            if m and H.valid_gid(m.group(1)):
                return m.group(1)
    return None


def on_ask(H, main, data: dict) -> list:
    if data.get("tool_name") != "AskUserQuestion":
        return []
    ti, tr = data.get("tool_input"), data.get("tool_response")
    qs = ti.get("questions") if isinstance(ti, dict) else None
    if not isinstance(qs, list):
        return []
    answers = tr.get("answers") if isinstance(tr, dict) else None  # never tool_input.answers
    cmd, out = H.lib_cmd(main), []
    for q in qs:
        if not isinstance(q, dict):
            continue
        question, opts = q.get("question"), q.get("options")
        gid = gate_of(H, q.get("header"), question)
        if not gid:
            continue
        ask_terminal = f"{gid}：没取到选项卡的答案，没有记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。"
        if (not isinstance(answers, dict) or not isinstance(question, str) or question not in answers
                or not isinstance(opts, list) or not all(isinstance(o, dict) for o in opts)):
            out.append(ask_terminal)
            continue
        val = answers[question]
        labels = [o.get("label") for o in opts if isinstance(o.get("label"), str)]
        m = LABEL_RE.match(val) if isinstance(val, str) and val in labels else None
        if not m:
            out.append(f"{gid}：所选不是带字母的单个选项，没有记录；请在终端运行 `{cmd} answer {gid} <字母>` 答复。")
            continue
        out += record(H, main, gid, m.group(1))
    return out


def run() -> None:
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    try:
        data = json.loads(raw)
    except ValueError:
        return
    if not isinstance(data, dict) or disabled(data):
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
        print(json.dumps({"hookSpecificOutput": {"hookEventName": ev, "additionalContext": "\n".join(lines)}},
                         ensure_ascii=False))


if __name__ == "__main__":
    try:
        run()
    except BaseException:  # a hook never blocks or crashes the session
        pass
    sys.exit(0)
