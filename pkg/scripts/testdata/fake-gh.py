#!/usr/bin/env python3
"""Minimal stand-in for the `gh` CLI used by scripts/test-harness.sh (state in $FAKEGH_DIR/state.json)."""
import json, os, sys
D = os.environ["FAKEGH_DIR"]; F = os.path.join(D, "state.json")
st = json.load(open(F)) if os.path.exists(F) else {"issues": [], "prs": {}, "labels": []}
a = sys.argv[1:]
login = "bot" if os.environ.get("GH_TOKEN") else os.environ.get("FAKEGH_LOGIN", "me")
def save(): json.dump(st, open(F, "w"), ensure_ascii=False, indent=1)
def opt(name, default=None):
    return a[a.index(name) + 1] if name in a else default
if a[:2] == ["repo", "view"]: print("me/repo")
elif a[:2] == ["api", "user"]: print(os.environ.get("FAKEGH_LOGIN", "me"))
elif a[:2] == ["label", "create"]: st["labels"] = sorted(set(st["labels"]) | {a[2]}); save()
elif a[:2] == ["issue", "create"]:
    n = len(st["issues"]) + 1
    labels = [a[i + 1] for i, x in enumerate(a) if x == "--label"]
    st["issues"].append({"number": n, "title": opt("--title"), "body": sys.stdin.read(), "labels": labels,
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
    st["issues"][int(a[2]) - 1]["comments"].append({"author": {"login": login}, "body": opt("--body")}); save()
elif a[:2] == ["issue", "close"]:
    i = st["issues"][int(a[2]) - 1]; i["state"] = "closed"
    if opt("--comment"): i["comments"].append({"author": {"login": login}, "body": opt("--comment")})
    save()
elif a[:2] == ["api", "graphql"]:
    n = int([x for x in a if x.startswith("i=")][0][2:])
    ed = st["issues"][n - 1]["editor"]
    print(json.dumps({"data": {"repository": {"issue": {"editor": {"login": ed} if ed else None,
                                                          "userContentEdits": {"nodes": []}}}}}))
elif a[:2] == ["pr", "view"]: print(st["prs"].get(a[2], "OPEN"))
elif a[:2] in (["pr", "edit"], ["pr", "comment"]): sys.stdin.read() if "-" in a else None
else: sys.exit(f"fake gh: unsupported {a}")
