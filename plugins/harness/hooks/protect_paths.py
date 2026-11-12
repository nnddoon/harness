#!/usr/bin/env python3
"""PreToolUse(Edit|Write|NotebookEdit): enforce task scope + frozen paths.

Deny rules (in order):
  1. In a linked worktree, never write into the main checkout.
  2. .harness/locks.txt is append-only.
  3. .harness/backlog.md is single-writer: not editable from a linked worktree.
  4. Paths in .harness/locks.txt or task `locked_paths` (unless in task `unlock`
     AND an approved `kind: unlock` gate exists for the task).
  5. If the task card has non-empty `allowed_paths`, paths outside it
     (harness bookkeeping under .harness/ is always allowed, except rule 2/3).
  0. HARNESS_MODE=groom|review: only .harness/** is writable.
  0b. No new SUMMARY/REPORT/NOTES/FINDINGS/ANALYSIS/PROGRESS/STATUS/HANDOFF/TODO*.md outside .harness/.
  6. Dependency manifests (package.json, requirements*.txt, go.mod, ...) need an approved unlock gate.
  7. Tester/builder split (task card test_owner: tester, the default): only the `tester` subagent edits
     test files (.harness/test-paths.txt or defaults), and it edits nothing else.
Set HARNESS_GUARD=off to disable (e.g. while editing the harness itself by hand).
"""
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_lib as H  # noqa: E402

DEP_MANIFESTS = ["**/package.json", "**/package-lock.json", "**/pnpm-lock.yaml", "**/yarn.lock", "**/bun.lockb",
                 "**/requirements*.txt", "**/pyproject.toml", "**/poetry.lock", "**/Pipfile", "**/Pipfile.lock",
                 "**/uv.lock", "**/go.mod", "**/go.sum", "**/Cargo.toml", "**/Cargo.lock", "**/Gemfile",
                 "**/Gemfile.lock", "**/composer.json", "**/composer.lock", "**/pom.xml", "**/build.gradle*"]
DEFAULT_TEST_GLOBS = ["**/test/**", "**/tests/**", "**/__tests__/**", "**/e2e/**", "**/*.test.*", "**/*.spec.*",
                      "**/*_test.*", "**/test_*.py", "**/conftest.py"]


def test_globs(root: Path) -> list:
    f = root / ".harness" / "test-paths.txt"
    if f.exists():
        g = [l.strip() for l in f.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")]
        if g:
            return g
    return DEFAULT_TEST_GLOBS


BOOKKEEPING_OK = [".harness/tasks/**", ".harness/handoffs/**", ".harness/gates/**",
                  ".harness/decisions.md", ".harness/current"]


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "[harness] " + reason,
    }}, ensure_ascii=False))
    sys.exit(0)


def main() -> None:
    if os.environ.get("HARNESS_GUARD") == "off":
        return
    data = json.load(sys.stdin)
    ti = data.get("tool_input") or {}
    target = ti.get("file_path") or ti.get("notebook_path") or ti.get("path")
    if not target:
        return
    cwd = data.get("cwd") or os.getcwd()
    root = H.repo_root(cwd)
    if not root:
        return
    abs_t = Path(target) if os.path.isabs(target) else Path(cwd) / target
    abs_t = Path(os.path.realpath(abs_t))
    root_r = Path(os.path.realpath(root))

    # 1. worktree must not write into main checkout
    if H.is_linked_worktree(cwd):
        mc = H.main_checkout(cwd)
        if mc:
            mc_r = Path(os.path.realpath(mc))
            if root_r not in abs_t.parents and abs_t != root_r and (mc_r == abs_t or mc_r in abs_t.parents):
                deny(f"你在 worktree {root_r} 中，不允许修改主仓库文件 {abs_t}。"
                     "需要改 backlog/全局状态时写进本任务的交接包，由控制塔会话同步。")

    try:
        rel = abs_t.relative_to(root_r).as_posix()
    except ValueError:
        return  # outside repo: leave to normal permission system

    # 0. groom / review sessions may only touch harness bookkeeping
    if os.environ.get("HARNESS_MODE") in ("groom", "review") and not (
            rel.startswith(".harness/") or rel.startswith("docs/specs/")
            or re.match(r"^\.claude/worktrees/[^/]+/\.harness/", rel)):
        deny(f"当前是 {os.environ.get('HARNESS_MODE')} 模式（规划/审核），只允许写 .harness/、docs/specs/ 和各 worktree 的 .harness/，不改业务代码：{rel}")

    # 0b. no stray report files: content belongs in the task card / handoff / reply
    #     (idea from danyuchn/claude-work-mode scratch-doc-guard, MIT)
    if (data.get("tool_name") == "Write" and not abs_t.exists() and not rel.startswith(".harness/")
            and re.match(r"^(SUMMARY|REPORT|NOTES|FINDINGS|ANALYSIS|PROGRESS|STATUS|HANDOFF|TODO)[-_A-Za-z0-9]*\.md$",
                         abs_t.name, re.I)):
        deny(f"不要新建 {rel}。这类总结/进度/笔记写进当前任务卡（「7. 当前进展」「8. 发现的问题」）、"
             "交接包 .harness/handoffs/ 或直接写在回复里；中间结果放 /tmp。")

    # 2. locks.txt append-only
    if rel == ".harness/locks.txt":
        old_file = (root_r / rel).read_text(encoding="utf-8") if (root_r / rel).exists() else ""
        tool = data.get("tool_name")
        if tool == "Write" and ti.get("content", "").startswith(old_file):
            return
        if tool == "Edit" and ti.get("new_string", "").startswith(ti.get("old_string", "\0")) \
                and not ti.get("replace_all"):
            return
        deny("`.harness/locks.txt` 只允许追加新行（Edit 时 new_string 必须以 old_string 开头）。"
             "要移除冻结请开 /human-gate unlock。")

    # 3. backlog single writer
    if rel == ".harness/backlog.md" and H.is_linked_worktree(cwd):
        deny("backlog 只由主仓库的控制塔会话修改（单写者）。把需要新增/更新的条目写进交接包「遗留问题」。")

    branch = H.current_branch(cwd)
    tid = H.task_id_for(root_r, branch)
    fm = {}
    card = H.task_card_path(root_r, tid) if tid else None
    if card:
        fm = H.read_frontmatter(card)
    unlock = fm.get("unlock") or []
    unlock_ok = bool(tid and H.approved_gate(root_r, tid, "unlock"))

    # 4. frozen paths
    for pat, why in H.read_locks(root_r):
        if H.glob_to_regex(H._norm(pat)).match(rel):
            if H.matches_any(rel, unlock) and unlock_ok:
                return
            deny(f"`{rel}` 已被冻结（locks.txt: {pat} {why}）。如必须修改：在任务卡 unlock: 加上该路径，"
                 "并通过 /human-gate unlock 获得批准。")
    hit = H.matches_any(rel, fm.get("locked_paths") or [])
    if hit and not (H.matches_any(rel, unlock) and unlock_ok):
        deny(f"`{rel}` 在任务 {tid} 的 locked_paths（{hit}）中。")

    # 5. scope
    if H.matches_any(rel, BOOKKEEPING_OK):
        return

    # 6. new dependencies need a human: manifests are implicitly frozen (unlock gate to change)
    if tid and H.matches_any(rel, DEP_MANIFESTS) and not (H.matches_any(rel, unlock) and unlock_ok):
        deny(f"`{rel}` 是依赖清单：新增或升级依赖需要你确认。请 /human-gate unlock 说明要加的包、版本、许可证、"
             "为什么现有依赖不够；批准后在任务卡 unlock: 写上这个路径再改。")

    # 7. tester / builder split: only the `tester` subagent writes tests; it writes nothing else
    if tid and (fm.get("test_owner") or "tester") == "tester":
        is_test = bool(H.matches_any(rel, test_globs(root_r)))
        agent = (data.get("agent_type") or "").lower()
        if agent == "tester" and not is_test:
            deny(f"tester 只写测试，不改源码：`{rel}`。把需要的实现写进任务卡「7. 当前进展」交给 builder。")
        if agent != "tester" and is_test:
            deny(f"`{rel}` 是测试文件：测试只由 tester 子代理按验收标准编写，实现方不能改测试（防止改测试凑通过）。"
                 "需要新增或调整测试：调用 tester 子代理并说明原因；确实是测试本身写错，写进「7. 当前进展」由 tester 修。")
    allowed = fm.get("allowed_paths") or []
    if allowed and not H.matches_any(rel, allowed):
        deny(f"`{rel}` 不在任务 {tid} 的 allowed_paths 内 {allowed}。如确需修改：先在任务卡「9. 范围变更」"
             "写明原因并更新 allowed_paths；超过 3 个文件或跨模块请 /human-gate ambiguity。")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # never break the session because of a hook bug
        print(f"[harness] protect_paths error: {e}", file=sys.stderr)
        sys.exit(0)
