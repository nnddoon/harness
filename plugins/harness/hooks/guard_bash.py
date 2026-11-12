#!/usr/bin/env python3
"""PreToolUse(Bash): block irreversible / out-of-process commands.

The command line is split with shlex into segments (on ; & | ( ) and newlines), so
`echo "git push origin main"` is not mistaken for a push, and `git -C dir push`,
`cd dir && git merge`, `npx vercel --prod` and `FOO=1 git push` are still caught.
(Segment parsing approach adapted from danyuchn/claude-work-mode's git-safe-commit-gate, MIT.)

- "never" commands (force push, reset --hard, clean -f, rm -rf of root-ish paths,
  dumping secrets, curl | sh): always deny with a suggestion.
- "gated" commands (merge to main, push main, publish, deploy, prod migrations):
  deny unless an approved `kind: irreversible` gate exists for the current task; then
  "ask" so the human confirms in the UI. Under HARNESS_UNATTENDED=1 nobody can answer an
  ask, so it becomes a deny that says how to carry on (record it, keep working).
- commit on a protected branch: only allowed when every change is under .harness/.
Extra deploy patterns: one regex per line in .harness/deploy-patterns.txt (matched per segment).
Set HARNESS_GUARD=off to disable. Any internal error fails open (exit 0, no output).
"""
import json
import os
import re
import shlex
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_lib as H  # noqa: E402

PROTECTED = r"(main|master|release(/\S*)?|production|prod)"

NEVER = [
    (r"^git push\b.*\s(--force|-f)(\s|$)", "禁止 force push；推自己的任务分支请用 --force-with-lease"),
    (r"^git push\b.*\s\+\S+", "禁止 +refspec 强推"),
    (r"^git reset\b.*\s--hard\b", "禁止 reset --hard；用 git stash 或新提交回退"),
    (r"^git clean\b.*\s-[a-zA-Z]*f", "禁止 git clean -f；列出要删的文件交给人确认"),
    (r"^git branch\b.*\s(-D|--delete\s+--force|--force\s+--delete)\b", "禁止强删分支"),
    (r"^git push\b.*\s(--delete|-d)(\s|$)|^git push\b.*\s:\S+", "禁止删除远端分支"),
    (r"^git checkout -- \.$|^git restore( --staged| --worktree)* \.$", "禁止整体丢弃工作区改动"),
    (r"^rm\s+(-\S+\s+)*-[a-zA-Z]*[rR][a-zA-Z]*\s+(-\S+\s+)*(/|~|\$HOME|\.\.?|\*|\.git)/?(\s|$)",
     "禁止删除根/家目录/仓库/通配全部"),
    (r"^(cat|less|more|head|tail|bat|grep|rg|sed|awk|scp|base64|xxd|strings)\b.*\s\S*\.env(\.(local|production|prod|staging))?(\s|$)",
     "禁止读取/复制密钥文件 .env"),
    (r"^(cat|less|more|head|tail|cp|scp|base64)\b.*\.(pem|key)(\s|$)", "禁止读取私钥"),
    (r"^(printenv|env|export -p|set)$", "禁止打印全部环境变量（可能含密钥）"),
    (r"^chmod\s+-R\s+777\b", "禁止 chmod -R 777"),
]
# checked on the whole command line (they span a pipe)
NEVER_RAW = [
    (r"\b(curl|wget)\b[^;&|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b", "禁止 curl | sh"),
    (r"(127\.\d{1,3}(\.\d{1,3}){0,2}|localhost|\[?::1\]?|0\.0\.0\.0)(:\d+)?/+answer\b",
     "看板上的答复只能由你本人点；Claude 不能替你答复门卡"),
    (r"^(?!\s*(grep|rg|git\s+grep)\b).*HARNESS_SERVE_TOKEN",
     "带令牌启动看板等于拿到答复权限，只能由你在自己的终端里做"),
    (r"^(?!.*--read-only).*(serve_cmd\.py|\bharness\s+serve\b)",
     "Claude 只能用 --read-only 启动看板（能答复门卡的看板只能由你在自己的终端里开）"),
    (r"harness_lib\.py\s+(apply-gate\b|trust\b[^;&|]*--apply)",
     "放权和采纳原则只能由你本人执行（在 GitHub 上批准门卡，或自己在终端跑这条命令）；Claude 不能给自己放权"),
]

GATED = [
    (r"^git push\b.*\s(\S+:)?" + PROTECTED + r"(\s|$)", "push 到受保护分支"),
    (r"^git push\b.*\s--tags\b", "推送 tag（发版）"),
    (r"^gh pr merge\b", "合并 PR"),
    (r"^gh release create\b", "发版"),
    (r"^(npm|pnpm|yarn|bun) publish\b", "发布包"),
    (r"^(cargo|twine|gem|poetry) (publish|upload|push)\b", "发布包"),
    (r"^docker (image )?push\b", "推送镜像"),
    (r"^vercel\b.*\s--prod\b", "部署生产"),
    (r"^netlify deploy\b.*\s--prod\b", "部署生产"),
    (r"^fly(ctl)? deploy\b", "部署"),
    (r"^gcloud\b.*\bdeploy\b", "部署"),
    (r"^aws\b.*\b(deploy|update-function-code|s3 sync)\b", "部署"),
    (r"^(serverless|sls) deploy\b", "部署"),
    (r"^kubectl (apply|delete|replace|rollout|scale|patch|edit)\b", "改集群"),
    (r"^helm (install|upgrade|uninstall|rollback)\b", "改集群"),
    (r"^terraform (apply|destroy|import)\b", "改基础设施"),
    (r"^pulumi (up|destroy)\b", "改基础设施"),
    (r"^prisma migrate deploy\b", "生产数据迁移"),
    (r"^(npm|pnpm|yarn|bun) (add|install|i)\s+(?!-)\S", "新增依赖"),
    (r"^(pip|pip3|uv pip) install\s+(?!-r\b|-e\s+\.|\.)(?!-)\S", "新增依赖"),
    (r"^(poetry|uv|cargo) add\b", "新增依赖"),
    (r"^go get\b", "新增依赖"),
    (r"^(alembic upgrade|flyway migrate|knex migrate:latest|rails db:migrate|python manage\.py migrate)\b.*(prod|production)", "生产数据迁移"),
]
PROD_ENV = re.compile(r"^(DATABASE_URL|DB_URL|[A-Z_]*DATABASE[A-Z_]*)=\S*(prod|production)", re.I)

WRAPPERS = {"command", "env", "sudo", "time", "nice", "nohup", "exec"}
RUNNERS1 = {"npx", "pnpx", "bunx"}
RUNNERS2 = {("pnpm", "exec"), ("pnpm", "dlx"), ("yarn", "dlx"), ("npm", "exec"), ("bun", "x")}
GIT_GLOBAL_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}


def out(decision: str, reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": "[harness] " + reason,
    }}, ensure_ascii=False))
    sys.exit(0)


def segments(cmd: str) -> list:
    """Split a shell line into argv lists; redirections and their targets are dropped."""
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()<>\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:  # unbalanced quotes: fall back to a plain split, still checked
        return [cmd.split()]
    segs, cur, k = [], [], 0
    while k < len(tokens):
        t = tokens[k]
        if t and any(c in "<>" for c in t) and all(c in "<>&|" for c in t):
            if cur and cur[-1].isdigit():
                cur.pop()
            k += 2
            continue
        if t and all(c in ";&|()\n" for c in t):
            if cur:
                segs.append(cur)
            cur = []
        else:
            cur.append(t)
        k += 1
    if cur:
        segs.append(cur)
    return segs


def normalise(argv: list, base: str):
    """-> (kind, text, repo_dir, env_words). kind is 'git', 'cd' or 'other'."""
    env_words = []
    if argv in (["env"], ["printenv"], ["set"], ["export", "-p"]):
        return "other", " ".join(argv), base, env_words
    i = 0
    while i < len(argv) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[i]) or argv[i] in WRAPPERS):
        if "=" in argv[i]:
            env_words.append(argv[i])
        i += 1
    argv = argv[i:]
    if not argv:
        return "other", "", base, env_words
    if argv[0] in ("cd", "pushd"):
        target = argv[1] if len(argv) > 1 else os.path.expanduser("~")
        return "cd", "", os.path.join(base, os.path.expanduser(target)), env_words
    if argv[0] in RUNNERS1:
        argv = argv[1:]
        while argv and argv[0].startswith("-"):
            argv = argv[1:]
    elif len(argv) > 1 and (argv[0], argv[1]) in RUNNERS2:
        argv = argv[2:]
    if not argv:
        return "other", "", base, env_words
    if os.path.basename(argv[0]) == "git":
        repo, j = base, 1
        while j < len(argv) and argv[j].startswith("-"):
            if argv[j] in GIT_GLOBAL_VALUE and j + 1 < len(argv):
                if argv[j] == "-C":
                    repo = os.path.join(repo, os.path.expanduser(argv[j + 1]))
                j += 2
            else:
                j += 1
        return "git", " ".join(["git"] + argv[j:]), repo, env_words
    return "other", " ".join([os.path.basename(argv[0])] + argv[1:]), base, env_words


def load_extra(root) -> list:
    f = root / ".harness" / "deploy-patterns.txt" if root else None
    if f and f.exists():
        return [(l.strip(), "自定义部署命令") for l in f.read_text(encoding="utf-8").splitlines()
                if l.strip() and not l.startswith("#")]
    return []


def main() -> None:
    if os.environ.get("HARNESS_GUARD") == "off":
        return
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command", "")
    if not cmd:
        return
    cwd = data.get("cwd") or os.getcwd()
    flat = " ".join(cmd.split())

    try:
        dequoted = [" ".join(a) for a in segments(cmd)]  # --app""ly -> --apply
    except Exception:
        dequoted = []
    for pat, why in NEVER_RAW:
        if re.search(pat, flat) or any(re.search(pat, d) for d in dequoted):
            out("deny", f"{why}。命令：{flat[:120]}")

    root = H.repo_root(cwd)
    extra = load_extra(root)
    base = cwd
    gated_hit, gate_repo = None, cwd
    for argv in segments(cmd):
        kind, text, repo, env_words = normalise(argv, base)
        if kind == "cd":
            base = repo
            continue
        for pat, why in NEVER:
            if re.search(pat, text):
                out("deny", f"{why}。命令：{flat[:120]}")
        if gated_hit:
            continue
        if any(PROD_ENV.match(w) for w in env_words):
            gated_hit, gate_repo = "连接生产数据库", repo
            continue
        for pat, why in GATED + extra:
            if re.search(pat, text):
                gated_hit, gate_repo = why, repo
                break
        if gated_hit or kind != "git":
            continue
        branch = H.current_branch(repo) if os.path.isdir(repo) else ""
        on_protected = bool(re.fullmatch(PROTECTED, branch or "-"))
        sub = text.split()[1] if len(text.split()) > 1 else ""
        if on_protected and sub in ("merge", "rebase", "cherry-pick"):
            gated_hit, gate_repo = f"在 {branch} 上执行 git {sub}", repo
        elif on_protected and sub == "push" and not [a for a in text.split()[2:] if not a.startswith("-")]:
            gated_hit, gate_repo = f"在 {branch} 上 git push", repo
        elif on_protected and sub == "commit":
            staged = H._git(["diff", "--cached", "--name-only"], repo).splitlines()
            if re.search(r"\s-[a-zA-Z]*a|\s--all\b", text):
                staged += H._git(["diff", "--name-only"], repo).splitlines()
            bad = [f for f in staged if f and not f.startswith(".harness/")]
            if bad:
                out("deny", f"不允许在 {branch} 上直接提交代码（{', '.join(bad[:5])}）。"
                            "先创建任务分支：scripts/new-task.sh T-xxx 或 git switch -c task/T-xxx-<slug>。"
                            "只有 .harness/ 下的任务卡/backlog 可以提交到主干。")

    if gated_hit:
        groot = H.repo_root(gate_repo) if os.path.isdir(gate_repo) else root
        groot = groot or root
        tid = H.task_id_for(groot, H.current_branch(gate_repo)) if groot else None
        kind = "unlock" if gated_hit == "新增依赖" else "irreversible"
        g = H.approved_gate(groot, tid, kind) if (groot and tid) else None
        if g and os.environ.get("HARNESS_UNATTENDED") == "1":
            out("deny", f"{gated_hit}：人工门 {g.get('id')} 已批准，但当前无人值守，没人能确认这一步。不要停下等待："
                        "把这条命令原样写进任务卡「7. 当前进展」的「待人执行」列表，继续做其他工作；"
                        "人回到交互会话后再一次性执行。")
        if g:
            out("ask", f"{gated_hit}：已有批准的人工门 {g.get('id')}，请你在此确认执行。")
        if gated_hit == "新增依赖":
            out("deny", "新增依赖需要你确认：/human-gate unlock，写明包名、版本、许可证、维护状况、为什么现有依赖不够；"
                        "批准前先做不依赖它的部分。")
        out("deny", f"{gated_hit} 属于不可逆操作，需要人工门。请执行 /human-gate irreversible <问题>，"
                    "准备好 diff 摘要/测试结果/回滚方案；期间继续做其他工作，不要停下来等。")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        print(f"[harness] guard_bash error: {e}", file=sys.stderr)
        sys.exit(0)
