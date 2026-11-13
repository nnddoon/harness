#!/usr/bin/env python3
"""PostToolUse(Edit|Write): run the project's fast check on the file just changed.

Runs `.harness/quick-check.sh <file>` (lint + types for that one file, a few seconds). A failure
exits 2 so its output reaches Claude right away (the edit already happened; nothing is undone).
Skips harness bookkeeping and docs. Not configured / HARNESS_QUICK_CHECK=off -> does nothing.
strict（HARNESS_STRICT=1）：hook 跑在沙箱外，不执行任何项目命令，只提示 Claude 在沙箱 Bash 里自己跑（S-002 T-009）。
"""
import json
import os
import shlex
import subprocess
import sys

SKIP_EXT = (".md", ".txt", ".json", ".lock", ".yaml", ".yml", ".png", ".jpg", ".svg", ".wav")


def main() -> int:
    if os.environ.get("HARNESS_QUICK_CHECK") == "off":
        return 0
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    fp = (data.get("tool_input") or {}).get("file_path") or ""
    cwd = data.get("cwd") or os.getcwd()
    if not fp or "/.harness/" in fp.replace("\\", "/") or fp.endswith(SKIP_EXT):
        return 0
    try:
        root = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=cwd, capture_output=True,
                              text=True, timeout=10).stdout.strip() or cwd
    except Exception:
        root = cwd
    script = os.path.join(root, ".harness", "quick-check.sh")
    if not os.path.exists(script):
        return 0
    if os.environ.get("HARNESS_STRICT") == "1":
        rel = shlex.quote(os.path.relpath(fp, root))
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": f"[harness] strict：hook 不在沙箱外运行项目命令，请你自己在 Bash 里运行：bash .harness/quick-check.sh {rel}",
        }}, ensure_ascii=False))
        return 0
    try:
        r = subprocess.run(["bash", script, fp], cwd=root, capture_output=True, text=True,
                           timeout=int(os.environ.get("HARNESS_QUICK_CHECK_TIMEOUT", "90")))
    except subprocess.TimeoutExpired:
        return 0
    if r.returncode == 0:
        return 0
    tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-25:])
    print(f"[harness] 快检没过（{os.path.relpath(fp, root)}）：\n{tail}\n先修好这些再继续下一处改动。", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
