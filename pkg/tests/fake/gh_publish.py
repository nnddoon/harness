#!/usr/bin/env python3
"""假 gh（T-011）：有状态（$FAKEGH_DIR/state.json），把每次调用追加到 $FAKEGH_DIR/calls.jsonl：
{"argv", "cwd", "claude": $HARNESS_FAKE_CLAUDE, "strict": $HARNESS_STRICT, "write": 是否写调用}。
写调用 = 只读白名单（repo view、api user / graphql、issue list/view、pr view/list、label list、auth status）以外的一切。
pr create 返回 https://github.com/me/repo/pull/<101 起>；issue create 返回 …/issues/<1 起>。
v2：PR 记 author（GH_TOKEN 设了 = bot，否则 me；api user 同此）；同一 head 已有 OPEN 的 PR 时 pr create 失败；
pr view / pr list 支持 --json 与简单的 -q（.a、.a.b、.[0].a、.[].a）；pr list 支持 --head、--state（默认 open）。
$FAKEGH_FAIL="pr create,issue create"：这些子命令失败（退出 1，不改状态）；$FAKEGH_DELAY_ISSUE=<秒>：issue create 先睡一会（并发测试）。"""
import json, os, sys

D = os.environ["FAKEGH_DIR"]
F = os.path.join(D, "state.json")
a = sys.argv[1:]
READ = (a[:2] in (["repo", "view"], ["api", "user"], ["api", "graphql"], ["issue", "list"], ["issue", "view"],
                  ["pr", "view"], ["pr", "list"], ["label", "list"], ["auth", "status"]))
with open(os.path.join(D, "calls.jsonl"), "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"argv": a, "cwd": os.getcwd(), "claude": os.environ.get("HARNESS_FAKE_CLAUDE", ""),
                         "strict": os.environ.get("HARNESS_STRICT", ""), "write": not READ}, ensure_ascii=False) + "\n")
st = json.load(open(F)) if os.path.exists(F) else {"issues": [], "prs": [], "labels": []}
login = "bot" if os.environ.get("GH_TOKEN") else "me"
if " ".join(a[:2]) in [x.strip() for x in os.environ.get("FAKEGH_FAIL", "").split(",")]:
    sys.exit(f"fake gh: {' '.join(a[:2])} failed (FAKEGH_FAIL)")


def jq(obj, q):
    """.a / .a.b / .[0].a / .[].a -> lines"""
    vals = [obj]
    for part in [x for x in q.replace("[", ".[").split(".") if x]:
        nxt = []
        for v in vals:
            if part == "[]":
                nxt += list(v or [])
            elif part.startswith("[") and part.endswith("]"):
                i = int(part[1:-1])
                nxt += [v[i]] if isinstance(v, list) and -len(v) <= i < len(v) else []
            else:
                nxt += [v.get(part)] if isinstance(v, dict) else []
        vals = nxt
    return "\n".join("" if v is None else (json.dumps(v) if isinstance(v, (dict, list)) else str(v)) for v in vals)


def out(obj):
    q = opt("-q") or opt("--jq")
    print(jq(obj, q) if q else json.dumps(obj))


def pr_json(p):
    return {"number": p["number"], "state": p["state"], "headRefName": p["head"], "baseRefName": p["base"],
            "author": {"login": p.get("author", "me")}, "url": f"https://github.com/me/repo/pull/{p['number']}"}


def save():
    json.dump(st, open(F, "w"), ensure_ascii=False, indent=1)


def opt(name, default=None):
    return a[a.index(name) + 1] if name in a and a.index(name) + 1 < len(a) else default


def body():
    if opt("--body-file") == "-" or ("--body-file" not in a and "--body" not in a and not sys.stdin.isatty()):
        try:
            return sys.stdin.read()
        except Exception:
            return ""
    if opt("--body-file"):
        try:
            return open(opt("--body-file"), encoding="utf-8").read()
        except OSError:
            return ""
    return opt("--body", "")


def find_pr(key, open_only=False):
    for p in reversed(st["prs"]):
        if (str(p["number"]) == str(key) or p["head"] == key) and (p["state"] == "OPEN" or not open_only):
            return p
    return None


if a[:2] == ["auth", "status"]:
    print("Logged in to github.com account me")
elif a[:2] == ["repo", "view"]:
    print("me/repo" if ("-q" in a or "--jq" in a) else json.dumps({"nameWithOwner": "me/repo"}))
elif a[:2] == ["api", "user"]:
    print(login)
elif a[:2] == ["label", "create"]:
    st["labels"] = sorted(set(st["labels"]) | {a[2]}); save()
elif a[:2] == ["issue", "create"]:
    if os.environ.get("FAKEGH_DELAY_ISSUE"):
        import time
        b0 = body()
        time.sleep(float(os.environ["FAKEGH_DELAY_ISSUE"]))
        st = json.load(open(F)) if os.path.exists(F) else st
        body = lambda: b0
    n = len(st["issues"]) + 1
    labels = [a[i + 1] for i, x in enumerate(a) if x == "--label"]
    st["issues"].append({"number": n, "title": opt("--title"), "body": body(), "labels": labels,
                         "state": "open", "comments": [], "editor": None, "author": login})
    save(); print(f"https://github.com/me/repo/issues/{n}")
elif a[:2] == ["issue", "list"]:
    lab = opt("--label")
    print(json.dumps([{"number": i["number"], "title": i["title"], "body": i["body"], "comments": i["comments"],
                       "author": {"login": i["author"]}, "labels": [{"name": l} for l in i["labels"]]}
                      for i in st["issues"] if i["state"] == "open" and lab in i["labels"]]))
elif a[:2] == ["issue", "edit"]:
    i = st["issues"][int(a[2]) - 1]
    i["labels"] += [a[k + 1] for k, x in enumerate(a) if x == "--add-label"]; save()
elif a[:2] == ["issue", "comment"]:
    st["issues"][int(a[2]) - 1]["comments"].append({"author": {"login": login}, "body": body()}); save()
elif a[:2] == ["issue", "close"]:
    i = st["issues"][int(a[2]) - 1]; i["state"] = "closed"
    if opt("--comment"):
        i["comments"].append({"author": {"login": login}, "body": opt("--comment")})
    save()
elif a[:2] == ["api", "graphql"]:
    n = int([x for x in a if x.startswith("i=")][0][2:])
    ed = st["issues"][n - 1]["editor"]
    print(json.dumps({"data": {"repository": {"issue": {"editor": {"login": ed} if ed else None,
                                                          "userContentEdits": {"nodes": []}}}}}))
elif a[:2] == ["pr", "create"]:
    head = opt("--head") or ""
    if find_pr(head, open_only=True):
        sys.exit(f"a pull request for branch \"{head}\" into branch \"main\" already exists")
    n = 101 + len(st["prs"])
    st["prs"].append({"number": n, "head": head, "base": opt("--base") or "", "title": opt("--title") or "",
                      "body": body(), "state": "OPEN", "comments": [], "labels": [], "author": login})
    save(); print(f"https://github.com/me/repo/pull/{n}")
elif a[:2] == ["pr", "view"]:
    p = find_pr(a[2] if len(a) > 2 and not a[2].startswith("-") else "")
    if not p:
        sys.exit("no pull requests found")
    out(pr_json(p))
elif a[:2] == ["pr", "list"]:
    state, head = (opt("--state") or "open").upper(), opt("--head")
    out([pr_json(p) for p in st["prs"] if (state == "ALL" or p["state"] == state) and (head is None or p["head"] == head)])
elif a[:2] == ["pr", "edit"]:
    p = find_pr(a[2])
    if p:
        p["labels"] += [a[k + 1] for k, x in enumerate(a) if x == "--add-label"]; save()
elif a[:2] == ["pr", "comment"]:
    p = find_pr(a[2])
    if p:
        p["comments"].append(body()); save()
# 其他写调用：照样「成功」，由日志断言抓出来
sys.exit(0)
