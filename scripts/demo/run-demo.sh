#!/usr/bin/env bash
# 演示：在一个临时仓库里真实运行 harness 的脚本，走完「倍速 + 语音朗读」从提出到合并的全流程。
# Claude 与 GitHub 由脚本替身扮演（scripts/demo/fake-claude.sh、scripts/testdata/fake-gh.py），不会联网、不花额度。
# 用法：scripts/demo/run-demo.sh [输出目录，默认 /tmp/harness-demo]
set -u
HSRC="$(cd "$(dirname "$0")/../.." && pwd)"
SIM="${1:-/tmp/harness-demo}"; OUT=$SIM/out; R=$SIM/demo-app
rm -rf "$SIM"; mkdir -p $OUT $SIM/bin
cp "$HSRC/scripts/testdata/fake-gh.py" $SIM/bin/gh; cp "$HSRC/scripts/demo/fake-claude.sh" $SIM/bin/claude; chmod +x $SIM/bin/*
export PATH="$SIM/bin:$PATH" FAKEGH_DIR=$SIM/ghstate HARNESS_GATE_PUSH_ASSETS=1
rm -rf $FAKEGH_DIR; mkdir -p $FAKEGH_DIR
mkdir -p $R && cd $R
git init -q -b main && git config user.email me@example.com && git config user.name me
cp -R "$HSRC"/{CLAUDE.md,.claude,.harness,scripts} .; rm -rf .claude/worktrees .harness/logs
printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
mkdir -p src/player src/tts src/article tests && echo "export {}" > src/player/Player.tsx && echo "export {}" > src/player/events.ts
git add -A && git commit -qm "app + harness"
gs() { python3 - "$FAKEGH_DIR/state.json" "$1" <<'PY'
import json,sys; f=sys.argv[1]; s=json.load(open(f)); exec(sys.argv[2]); json.dump(s,open(f,"w"),ensure_ascii=False,indent=1)
PY
}
step() { echo "\$ $1" > "$OUT/$2.txt"; bash -c "$1" >> "$OUT/$2.txt" 2>&1; }

# 1 手机提需求
python3 -c 'import json; json.dump({"issues":[{"number":1,"title":"播放器加倍速，再加一个文章朗读按钮","body":"倍速 0.5–2x，要记住上次选的。朗读用中文女声或男声都行。","labels":["harness:request"],"state":"open","comments":[],"editor":None,"author":"me"}],"prs":{},"labels":[]},open("'$FAKEGH_DIR'/state.json","w"),ensure_ascii=False)'
step "scripts/gate-sync.sh --resume" 01-accept-request; sleep 2
python3 - > $OUT/02-issue-confirm.txt <<PY
import json; s=json.load(open("$FAKEGH_DIR/state.json")); i=s["issues"][1]; print("标题:", i["title"]); print("标签:", ", ".join(i["labels"])); print(); print(i["body"])
PY
# 2 手机勾选确认
gs 'for i in s["issues"][1:3]: i["body"]=i["body"].replace("- [ ] A（推荐）","- [x] A（推荐）"); i["editor"]="me"'
step "scripts/gate-sync.sh" 03-confirm-sync
git add .harness && git commit -qm "harness: T-001 T-002 ready" >/dev/null
step "python3 .claude/hooks/harness_lib.py board" 04-board
step "python3 .claude/hooks/harness_lib.py decide T-001; python3 .claude/hooks/harness_lib.py decide T-002 --after T-001" 05-decide
step "scripts/new-task.sh T-001 --print-only" 06-new-task-block
# 3 并行派发
step "scripts/harness-loop.sh --parallel 2 --max-tasks 2 --no-groom" 07-loop-parallel
step "scripts/gates.sh" 08-gates
python3 - > $OUT/09-issue-sensory.txt <<PY
import json; s=json.load(open("$FAKEGH_DIR/state.json")); i=[x for x in s["issues"] if "G-T002-2" in x["title"]][0]; print("Issue #%d  标题:"%i["number"], i["title"]); print("标签:", ", ".join(i["labels"])); print(); print(i["body"])
PY
# 4 邮件回复
gs 'i=[x for x in s["issues"] if "G-T002-2" in x["title"]][0]; i["comments"].append({"author":{"login":"me"},"body":"B 语速再慢一点\n\n—— 从手机邮件回复"})'
step "scripts/harness-loop.sh --max-tasks 1 --no-groom" 10-loop-resume
# 5 合并
gs 's["prs"].update({"1":"MERGED","2":"MERGED","task/T-001-playback-rate":"MERGED","task/T-002-read-aloud":"MERGED"})'
step "scripts/gate-sync.sh; python3 .claude/hooks/harness_lib.py sync-merged" 11-merged
git add .harness && git commit -qm "harness: merged" >/dev/null
# 6 清空 → 审核扩展 → 自动做低风险提议
step "scripts/harness-loop.sh --max-tasks 1" 12-loop-groom
step "python3 .claude/hooks/harness_lib.py board" 13-board-final
python3 - > $OUT/14-decisions.txt <<PY
print(open("$R/.claude/worktrees/T-002/.harness/decisions.md",encoding="utf-8").read())
PY
cat $R/.harness/backlog.md > $OUT/15-backlog.txt
echo "完成。每一步的输出在 $OUT/（01-…15-），演示仓库在 $R"
