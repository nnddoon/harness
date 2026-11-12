#!/usr/bin/env python3
"""SessionStart (startup|resume|clear|compact): inject a short harness briefing.

Plain stdout is added to Claude's context. Keep it short (< ~40 lines).
"""
import json
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_lib as H  # noqa: E402


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    cwd = data.get("cwd") or os.getcwd()
    src = data.get("source", "startup")
    root, br, tid, card = H.current(cwd)
    if not root or not (root / ".harness").exists():
        return
    lines = ["[harness briefing]", H.cmd_where(cwd)]
    if card:
        txt = card.read_text(encoding="utf-8")
        prog = H.section(txt, "7.").strip()
        un = H.unchecked_items(txt)
        lines.append(f"未完成项 {len(un)} 个" + (f"，下一项：{un[0][6:90]}" if un else ""))
        if prog:
            lines.append("当前进展：\n" + "\n".join(prog.splitlines()[:6]))
        og = H.open_gates(root, tid)
        if og:
            lines.append("本任务待人工门：" + ", ".join(g.get("id", "?") for g in og))
        if src == "compact":
            lines.append(f"刚发生上下文压缩：继续前先完整重读 {card.relative_to(root)}。")
        else:
            lines.append(f"继续前先读 {card.relative_to(root)}；执行用 /task-run {tid}。")
    else:
        nr = H.next_ready(root)
        og = H.open_gates(root)
        lines.append("当前不在任务分支。" + (f"下一个可认领任务：{nr}（scripts/new-task.sh {nr}）。" if nr
                                          else "没有 ready 任务：新需求用 /task-align，或开审核对话 /backlog-groom。"))
        if og:
            lines.append("待处理人工门：" + ", ".join(f"{g.get('id')}({g.get('kind')})" for g in og) + "，查看：scripts/gates.sh")
    if os.environ.get("HARNESS_UNATTENDED") == "1":
        lines.append("无人值守模式：不要使用 AskUserQuestion，也不要等待回复。需要人判断时写门卡并在输出首行写 "
                     "`NEEDS_HUMAN: <门卡号> <一句话>`；/task-close 第 6 步一律选默认（开新对话）并只输出启动块。")
    if os.environ.get("HARNESS_MODE") in ("groom", "review"):
        lines.append("审核模式：只读代码，只允许写 .harness/ 下的文件。")
    locks = H.read_locks(root)
    if locks:
        lines.append("冻结路径（不得修改）：" + ", ".join(p for p, _ in locks[:12]) + (" …" if len(locks) > 12 else ""))
    print("\n".join(lines))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[harness] session_start error: {e}", file=sys.stderr)
    sys.exit(0)
