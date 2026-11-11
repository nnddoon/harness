#!/usr/bin/env python3
"""Stop hook: don't let Claude stop mid-task without saying why.

Blocks the stop (once per stop chain — respects stop_hook_active) when:
  - task status is in_progress, unchecked steps/acceptance remain, and no gate is open
  - task status is review but no handoff package exists yet
Allows the stop otherwise (waiting_human / blocked / done / no task).
The long-running loop is driven by /goal; this hook is a safety net, not the engine.
Set HARNESS_STOP_GATE=off to disable.
"""
import json
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_lib as H  # noqa: E402


def block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": "[harness] " + reason}, ensure_ascii=False))
    sys.exit(0)


def main() -> None:
    if os.environ.get("HARNESS_STOP_GATE") == "off":
        return
    data = json.load(sys.stdin)
    if data.get("stop_hook_active"):
        return
    cwd = data.get("cwd") or os.getcwd()
    root, _, tid, card = H.current(cwd)
    if not card:
        return
    fm = H.read_frontmatter(card)
    status = fm.get("status")
    if status == "in_progress":
        if H.open_gates(root, tid):
            return
        todo = H.unchecked_items(card.read_text(encoding="utf-8"))
        if todo:
            block(f"{tid} 状态仍为 in_progress，还有 {len(todo)} 项未完成（例如：{todo[0][6:80]}）。"
                  "请选择其一：① 继续 /task-run {tid}；② 需要人判断 → /human-gate 并把 status 改为 waiting_human；"
                  "③ 无法继续 → status 改为 blocked 并在「7. 当前进展」写明原因与解除条件；"
                  "④ 上下文太重 → /handoff。".replace("{tid}", tid))
    elif status == "review":
        risk = str(fm.get("risk") or "low")
        if risk in ("medium", "high") and H.critic_plan(risk) and \
                not H.adversarial_done(card.read_text(encoding="utf-8")):
            n = len(H.critic_plan(risk))
            block(f"{tid} 是 risk {risk}，进入 review 前要先做对抗审查：开 {n} 个 `critic` 子代理各从一个角度挑错"
                  f"（角度：`python3 .claude/hooks/harness_lib.py critics {risk} verify`），再交给 `judge` 只留成立的，"
                  "修完后在任务卡「13. 对抗审查」记一行。")
        if not (root / ".harness" / "handoffs" / f"{tid}.md").exists():
            block(f"{tid} 已进入 review 但还没有交接包。请执行 /task-close {tid}。")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        print(f"[harness] stop_gate error: {e}", file=sys.stderr)
        sys.exit(0)
