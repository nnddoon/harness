#!/usr/bin/env python3
"""PermissionRequest: approve the routine requests so you are not clicking "allow" all day.

Allowed without asking (everything dangerous was already denied by the PreToolUse guards,
which run first and cannot be bypassed from here):
  - Bash where EVERY segment is read-only (ls, grep, git status/diff/log/show, ...) or matches a
    line of .harness/allow-commands.txt (your test / lint / build / dev commands, as regexes);
  - Edit / Write inside a task worktree, on a path within the task card's allowed_paths.
Everything else falls through to the normal prompt. HARNESS_AUTO_ALLOW=off disables it.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_lib as H  # noqa: E402
import guard_bash as G  # noqa: E402

# harness_lib subcommands that only read (set-status, sync-merged, trust --apply… still ask)
READ_SUB = r"(where|current-path|context|next-ready|decide|pick-batch|board|waves|critics|review-load|gate-policy|metrics|backlog-status|trust(?!.*--apply))\b"
READ_ONLY = [
    r"^(ls|pwd|wc|head|tail|cat|less|file|stat|du|df|tree|which|echo|printf|date|true|sort|uniq|cut|tr|diff|jq)\b",
    r"^(grep|rg|ag|fd|find)\b(?!.*\s-(delete|exec)\b)",
    r"^git (status|diff|log|show|branch|rev-parse|ls-files|blame|remote -v|worktree list|stash list)\b",
    r"^gh (pr|issue) (view|list|status|diff)\b",
    r"^python3? (\.claude/hooks|\.harness/lib)/harness_lib\.py " + READ_SUB,
    r"^(bash )?scripts/(gates|test-harness)\.sh\b",
]


def allow(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                             "decision": {"behavior": "allow"}}}))
    print(f"[harness] auto-allowed: {reason}", file=sys.stderr)
    sys.exit(0)


def user_patterns(root) -> list:
    f = root / ".harness" / "allow-commands.txt" if root else None
    if not f or not f.exists():
        return []
    return [l.strip() for l in f.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")]


def main() -> None:
    if os.environ.get("HARNESS_AUTO_ALLOW") == "off":
        return
    data = json.load(sys.stdin)
    tool, ti = data.get("tool_name"), data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    root = H.repo_root(cwd)
    if tool == "Bash":
        cmd = ti.get("command", "")
        if not cmd or re.search(r"[`]|\$\(|>\s*[^&]", cmd):  # substitutions / writes via redirection: ask
            return
        pats = READ_ONLY + user_patterns(root)
        plug = os.environ.get("CLAUDE_PLUGIN_ROOT")
        if plug:  # skills in the plugin call its lib by absolute path; only that exact path counts
            pats = pats + [r"^python3? " + re.escape(os.path.realpath(plug)) + r"/hooks/harness_lib\.py " + READ_SUB,
                           r"^python3? " + re.escape(plug) + r"/hooks/harness_lib\.py " + READ_SUB]
        base = cwd
        for argv in G.segments(cmd):
            kind, text, repo, envw = G.normalise(argv, base)
            if kind == "cd":
                base = repo
                continue
            if envw or not any(re.search(p, text) for p in pats):
                return
        allow(cmd[:80])
    if tool in ("Edit", "Write") and root:
        fp = ti.get("file_path", "")
        tid = H.task_id_for(root, H.current_branch(cwd))
        card = H.task_card_path(root, tid) if tid else None
        allowed = H.read_frontmatter(card).get("allowed_paths") if card else None
        if fp and allowed:
            rel = os.path.relpath(os.path.realpath(fp if os.path.isabs(fp) else os.path.join(cwd, fp)),
                                  os.path.realpath(root))
            if not rel.startswith("..") and H.matches_any(rel, allowed):
                allow(f"{tool} {rel}（在 {tid} 的 allowed_paths 内）")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        pass
    sys.exit(0)
