#!/usr/bin/env python3
"""PostToolUse / PostToolUseFailure: stop error spin-outs (12-factor agents, factor 9).

Counts consecutive failures of the *same* tool call (tool name + normalised input) per session.
A success of that call resets its counter. At HARNESS_ERROR_LIMIT (default 3) failures in a row,
the failure hook exits 2 so its stderr reaches Claude: stop retrying as-is, change approach,
record it in the task card, or open an ambiguity gate.
State lives in the temp dir, never in the repo. HARNESS_ERROR_LIMIT=0 disables.
"""
import hashlib
import json
import os
import sys
import tempfile


def key_of(data: dict) -> str:
    ti = data.get("tool_input") or {}
    if data.get("tool_name") == "Bash":
        basis = " ".join((ti.get("command") or "").split())
    else:
        basis = json.dumps({k: ti.get(k) for k in ("file_path", "old_string", "pattern", "url") if k in ti},
                           sort_keys=True, ensure_ascii=False)
    return hashlib.sha1(f"{data.get('tool_name')}|{basis}".encode("utf-8")).hexdigest()[:16]


def main() -> int:
    limit = int(os.environ.get("HARNESS_ERROR_LIMIT", "3") or 0)
    if limit <= 0:
        return 0
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    sid = "".join(c for c in str(data.get("session_id") or "nosession") if c.isalnum() or c in "-_")[:80]
    path = os.path.join(tempfile.gettempdir(), f"harness-errors-{sid}.json")
    try:
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    k = key_of(data)
    failed = data.get("hook_event_name") == "PostToolUseFailure"
    if not failed:
        if k in state:
            state.pop(k)
            json.dump(state, open(path, "w", encoding="utf-8"))
        return 0
    state[k] = state.get(k, 0) + 1
    json.dump(state, open(path, "w", encoding="utf-8"))
    n = state[k]
    if n >= limit:
        what = (data.get("tool_input") or {}).get("command") or data.get("tool_name")
        print(f"[harness] 同一个调用已连续失败 {n} 次：{str(what)[:120]}\n"
              "不要原样再试。先把错误压缩成一句话，换一种做法；如果换法也不行，"
              "把「试过什么、错误是什么、怀疑的原因」写进任务卡「7. 当前进展 → 卡住的点」，"
              "再开 /human-gate ambiguity，或把任务标为 blocked。", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
