#!/usr/bin/env python3
"""PreToolUse / PostToolUse (matcher "*"): one masked JSON line per tool event in the audit log (S-002 #15).

Written to state_dir(main)/audit/<YYYY-MM-DD>.jsonl, outside the repo: time, session, task (from the branch),
event, tool and a ≤ 1 KB summary of the input (paths and commands only; never file contents or tool output).
Never influences the tool call: always exit 0, never prints anything, failures are swallowed.
"""
import json
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees


def main() -> None:
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import harness_lib as H
        data = json.loads(sys.stdin.read() or "{}")
        H.audit_hook(data)
    except BaseException:
        pass


if __name__ == "__main__":
    main()
    sys.exit(0)
