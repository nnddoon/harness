#!/usr/bin/env bash
# T-012 验收：审计日志与审计页（S-002 #15）。按任务卡「接口约定」：
#   hook .claude/hooks/audit_log.py 注册在 PreToolUse 与 PostToolUse（matcher "*"），每个事件一行 JSON，
#   写到 state_dir(main)/audit/<YYYY-MM-DD>.jsonl（目录 0700，文件 0600）。
#   字段：ts、session_id、task（取自分支）、event（= hook_event_name）、tool、input（字符串摘要，≤ 1024 字节，
#   只有路径/命令，不含文件内容与 tool_response）、verdict（护栏判定，护栏经共享的 H.audit(...) 写入）、
#   via（门卡答复，由 record_answer 写入）。每行 ≤ 4096 字节；写失败不阻塞（exit 0，无输出）。
#   打码：ghp_/gho_/ghu_/ghs_/github_pat_、Telegram bot token、sk-…、AKIA…、xox[bpas]-…、Bearer <x>、PEM 私钥块、
#   ://user:pass@，以及 config_dir()/telegram.json 的 "token" 原文与启动器 SCRUB 清单命名的环境变量的值。
#   看板 /audit?task=T-xxx&day=YYYY-MM-DD 只在带令牌时可用（否则 403），无令牌时导航里也没有这一项。
# v2（第 2 轮）：规范化副本打码、heredoc 正文丢弃；写入不阻塞不跟随链接（FIFO/符号链接）；保留期、doctor 大小、read_audit 只读最后 2000 行。
# 夹具里的 token 都在运行时拼出来，不在文件里出现完整的 token 字面量。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-audit.XXXXXX")"; T="$(cd "$T" && pwd -P)"
PIDS=""; trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
unset HARNESS_GUARD HARNESS_UNATTENDED HARNESS_MODE HARNESS_SERVE_TOKEN HARNESS_STRICT
export XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config"
umask 022

# ---------------------------------------------------------------- fixture repo + two task worktrees
R="$T/repo"; mkdir -p "$R" && cd "$R" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" . && rm -f .harness/gates/G-*.md
rm -rf .claude/worktrees .harness/logs .harness/reports .harness/STATUS.md
printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
for tid in T-042 T-077; do
  sed -e "s/T-000/$tid/g" -e "s/^status: proposed /status: in_progress /" .harness/tasks/_TEMPLATE.md > ".harness/tasks/$tid-x.md"
done
gate() {  # gate <id> <task>
  printf -- '---\nid: %s\ntask: %s\nkind: sensory\nstatus: open\nurgency: normal\nrecommended: A\nreview_minutes: 3\nanswer:\n---\n\n# %s 选哪个？\n\n## 选项\n- **A（推荐）**：甲方案\n- **B**：乙方案\n' \
    "$1" "$2" "$1" > ".harness/gates/$1.md"
}
gate G-T042-1 T-042
gate G-T042-2 T-042
git add -A && git commit -qm fixture
W="$T/wt42";  git worktree add -q -b task/T-042-demo "$W"  >/dev/null 2>&1
W2="$T/wt77"; git worktree add -q -b task/T-077-other "$W2" >/dev/null 2>&1

AUD="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.state_dir(H.store_main(Path(sys.argv[2]))) / "audit")' "$R/.claude/hooks" "$R")"

# ---------------------------------------------------------------- helpers
hookjson() {  # hookjson <event> <tool> <tool_input json> [session] [cwd] [tool_response json]
  python3 -B -c 'import json,sys
d = {"session_id": sys.argv[4], "transcript_path": "/tmp/t.jsonl", "cwd": sys.argv[5], "hook_event_name": sys.argv[1],
     "tool_name": sys.argv[2], "tool_input": json.loads(sys.argv[3])}
if sys.argv[6]: d["tool_response"] = json.loads(sys.argv[6])
print(json.dumps(d))' "$1" "$2" "$3" "${4:-sess-1}" "${5:-$W}" "${6:-}" 2>/dev/null
}
cmdin() { python3 -B -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
HOOKRC=0
audit() {  # audit <event> <tool> <tool_input json> [session] [cwd] [tool_response]  -> stdout of the hook; rc in $T/rc
  local cwd="${5:-$W}"
  hookjson "$@" | (cd "$cwd" && CLAUDE_PROJECT_DIR="$cwd" python3 -B "$cwd/.claude/hooks/audit_log.py"); echo $? > "$T/rc"
}
bashpre() { audit PreToolUse Bash "$(cmdin "$1")" "${2:-sess-1}" >/dev/null; }  # bashpre <command> [session]
q() {  # q '<python expr over d (dict) and line (raw text)>' -> number of matching lines in all audit files
  python3 -B - "$AUD" "$1" <<'PY'
import glob, json, os, sys
n = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    for line in open(f, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        try:
            d = json.loads(line)
        except Exception:
            continue
        try:
            if eval(sys.argv[2]):
                n += 1
        except Exception:
            pass
print(n)
PY
}
has() { [ "$(q "$1")" -ge 1 ] 2>/dev/null && echo yes || echo no; }
leaked() { grep -rqF -- "$1" "$AUD" 2>/dev/null && echo yes || echo no; }
masked() {  # masked <marker> <secret...>: the marker's line exists and no secret appears anywhere in the audit log
  [ "$(has "'$1' in line")" = yes ] || { echo "no-line"; return; }
  local s; for s in "${@:2}"; do [ "$(leaked "$s")" = no ] || { echo "leaked:$s"; return; }; done
  echo yes
}
rep() { python3 -B -c 'import sys; print(sys.argv[1] * int(sys.argv[2]), end="")' "$1" "$2"; }

# ---------------------------------------------------------------- registration (settings.json + plugin hooks.json)
reg() {  # reg <settings-or-hooks.json> <event> -> yes when a matcher "*" entry runs audit_log.py without onFailure:block
  python3 -B - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ok = False
for m in d.get("hooks", {}).get(sys.argv[2], []):
    for h in m.get("hooks", []):
        if "audit_log.py" in h.get("command", "") and m.get("matcher") == "*" and h.get("onFailure") != "block":
            ok = True
print("yes" if ok else "no")
PY
}
expect "settings: PreToolUse * runs audit_log.py (never blocking)" yes "$(reg "$SRC/.claude/settings.json" PreToolUse)"
expect "settings: PostToolUse * runs audit_log.py (never blocking)" yes "$(reg "$SRC/.claude/settings.json" PostToolUse)"
bash "$SRC/plugin/build.sh" "$T/plugin" >/dev/null 2>&1
expect "plugin hooks.json: PreToolUse audit_log.py" yes "$(reg "$T/plugin/hooks/hooks.json" PreToolUse)"
expect "plugin hooks.json: PostToolUse audit_log.py" yes "$(reg "$T/plugin/hooks/hooks.json" PostToolUse)"
expect "plugin hooks.json uses \${CLAUDE_PLUGIN_ROOT}/hooks/audit_log.py" yes "$(grep -qF '${CLAUDE_PLUGIN_ROOT}/hooks/audit_log.py' "$T/plugin/hooks/hooks.json" 2>/dev/null && echo yes || echo no)"
expect "plugin ships hooks/audit_log.py" yes "$([ -f "$T/plugin/hooks/audit_log.py" ] && echo yes || echo no)"

# ---------------------------------------------------------------- one line per event, fields, location, permissions
OUT="$(audit PreToolUse Bash "$(cmdin 'echo mkPRE hello')" sess-abc)"
expect "PreToolUse: exit 0" 0 "$(cat "$T/rc")"
expect "PreToolUse: prints nothing (never influences the decision)" "" "$OUT"
OUT="$(audit PostToolUse Bash "$(cmdin 'echo mkPOST hello')" sess-abc "$W" '{"stdout": "mkSTDOUTCONTENT", "stderr": ""}')"
expect "PostToolUse: exit 0" 0 "$(cat "$T/rc")"
expect "PostToolUse: prints nothing" "" "$OUT"
expect "log lives under state_dir(main)/audit (not in the worktree or repo)" yes "$([ -d "$AUD" ] && echo yes || echo no)"
FILES="$(ls "$AUD" 2>/dev/null)"
expect "exactly one day file" 1 "$(printf '%s\n' "$FILES" | grep -c .)"
DAYF="$(printf '%s\n' "$FILES" | head -1)"; DAY="${DAYF%.jsonl}"
expect "day file is today's <YYYY-MM-DD>.jsonl" yes "$( { [ "$DAYF" = "$(date +%F).jsonl" ] || [ "$DAYF" = "$(date -u +%F).jsonl" ]; } && echo yes || echo no)"
expect "audit dir is 0700" 700 "$(stat -c %a "$AUD" 2>/dev/null)"
expect "audit file is 0600" 600 "$(stat -c %a "$AUD/$DAYF" 2>/dev/null)"
expect "nothing written into the repo or worktree" "" "$(cd "$W" && git status --porcelain --ignored 2>/dev/null | grep -i audit; cd "$R" && git status --porcelain --ignored 2>/dev/null | grep -i audit)"
expect "one line for the PreToolUse event" 1 "$(q "'mkPRE' in line")"
expect "one line for the PostToolUse event" 1 "$(q "'mkPOST' in line")"
expect "every line is valid UTF-8 JSON" 0 "$(python3 -B -c 'import json,sys
bad = 0
for l in open(sys.argv[1], "rb"):
    try: json.loads(l.decode("utf-8"))
    except Exception: bad += 1
print(bad)' "$AUD/$DAYF" 2>/dev/null || echo missing)"
expect "fields: ts, session_id, event, tool" yes "$(has "'mkPRE' in line and d.get('session_id')=='sess-abc' and d.get('event')=='PreToolUse' and d.get('tool')=='Bash' and bool(d.get('ts'))")"
expect "ts is an ISO timestamp" yes "$(has "'mkPRE' in line and __import__('re').match(r'\d{4}-\d\d-\d\dT\d\d:\d\d', str(d.get('ts')))")"
expect "task comes from the branch (task/T-042-demo)" yes "$(has "'mkPRE' in line and d.get('task')=='T-042'")"
expect "PostToolUse event recorded as such" yes "$(has "'mkPOST' in line and d.get('event')=='PostToolUse'")"
expect "input is a string summary holding the command" yes "$(has "'mkPRE' in line and isinstance(d.get('input'), str) and 'echo mkPRE hello' in d['input']")"
expect "tool_response (output) is not logged" no "$(leaked mkSTDOUTCONTENT)"
bashpre 'echo mkOTHERTASK' sess-2 ; audit PreToolUse Bash "$(cmdin 'echo mkOTHERTASK2')" sess-2 "$W2" >/dev/null
expect "other worktree: task T-077, same audit dir" yes "$(has "'mkOTHERTASK2' in line and d.get('task')=='T-077'")"

# paths only, never file contents
audit PreToolUse Write '{"file_path": "src/mkWRITEPATH.txt", "content": "mkFILECONTENT body"}' >/dev/null
expect "Write: path logged" yes "$(has "'mkWRITEPATH' in line and d.get('tool')=='Write'")"
expect "Write: file content not logged" no "$(leaked mkFILECONTENT)"
audit PreToolUse Edit '{"file_path": "src/mkEDITPATH.py", "old_string": "mkOLDSTRING", "new_string": "mkNEWSTRING"}' >/dev/null
expect "Edit: path logged" yes "$(has "'mkEDITPATH' in line")"
expect "Edit: old/new strings not logged" no "$( { [ "$(leaked mkOLDSTRING)" = yes ] || [ "$(leaked mkNEWSTRING)" = yes ]; } && echo yes || echo no)"
audit PostToolUse Read '{"file_path": "src/mkREADPATH.md"}' sess-1 "$W" '{"file": {"content": "mkREADCONTENT"}}' >/dev/null
expect "Read: path logged, content of the response not" yes "$( [ "$(has "'mkREADPATH' in line")" = yes ] && [ "$(leaked mkREADCONTENT)" = no ] && echo yes || echo no)"

# ---------------------------------------------------------------- masking fixtures (S-002 #15)
A36="$(rep 'Zq8Xw7' 6)"                                     # 36 chars
GHP="gh""p_$A36"; GHO="gh""o_$A36"; GHU="gh""u_$A36"; GHS="gh""s_$A36"
PAT="github""_pat_11ABCDEFG0$(rep 'k3Lm' 5)_$(rep 'Pq7Rs9Tu' 7)"
TG="7012345678"":AAH$(rep 'x9Y-z_' 5)Q2"                       # \d{10}:[A-Za-z0-9_-]{35}
SK1="s""k-proj-$(rep 'aB3dE5' 7)"; SK2="s""k-ant-api03-$(rep 'Zz9_-y' 8)"
AKIA="AK""IA$(rep 'Q7W3' 4)"
XB="xo""xb-123456789012-1234567890123-$(rep 'AbCdEf' 4)"; XP="xo""xp-$(rep '98765' 3)-$(rep 'pQrS' 6)"
XA="xo""xa-2-$(rep 'tUvW' 6)"; XS="xo""xs-$(rep 'mNoP3' 5)"
BEARER="eyJhbGciOiJIUzI1NiJ9.mkBEARERpayload$(rep 'Jw' 10).sigX$(rep '9' 12)"
PEMBODY="MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC$(rep 'q' 20)"
OSSHBODY="b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ$(rep 'w' 20)"
URLPW="hunter2$(rep 'pw' 6)"

bashpre "curl -H 'Authorization: token $GHP' https://api.github.com mkGHP"
expect "mask ghp_" yes "$(masked mkGHP "$GHP" "$A36")"
bashpre "gh auth login --with-token <<< $GHO mkGHO"
expect "mask gho_" yes "$(masked mkGHO "$GHO" "$A36")"
bashpre "export X=$GHU mkGHU"
expect "mask ghu_" yes "$(masked mkGHU "$GHU" "$A36")"
bashpre "echo $GHS mkGHS"
expect "mask ghs_" yes "$(masked mkGHS "$GHS" "$A36")"
bashpre "GH_TOKEN=$PAT gh pr list mkPAT"
expect "mask github_pat_" yes "$(masked mkPAT "$PAT" "${PAT#github_pat_}")"
bashpre "curl https://api.telegram.org/bot$TG/getMe mkTG"
expect "mask Telegram bot token" yes "$(masked mkTG "$TG" "${TG#*:}")"
bashpre "OPENAI_API=$SK1 python x.py mkSK1"
expect "mask sk-… (openai)" yes "$(masked mkSK1 "$SK1" "${SK1#sk-}")"
bashpre "curl -H 'x-api-key: $SK2' https://api.anthropic.com mkSK2"
expect "mask sk-… (anthropic)" yes "$(masked mkSK2 "$SK2" "${SK2#sk-ant-api03-}")"
bashpre "aws configure set aws_access_key_id $AKIA mkAKIA"
expect "mask AKIA…" yes "$(masked mkAKIA "$AKIA" "${AKIA#AKIA}")"
bashpre "curl -d token=$XB slack.com mkXOXB"
expect "mask xoxb-" yes "$(masked mkXOXB "$XB" "${XB##*-}")"
bashpre "SLACK=$XP mkXOXP"
expect "mask xoxp-" yes "$(masked mkXOXP "$XP" "${XP##*-}")"
bashpre "SLACK=$XA mkXOXA"
expect "mask xoxa-" yes "$(masked mkXOXA "$XA" "${XA##*-}")"
bashpre "SLACK=$XS mkXOXS"
expect "mask xoxs-" yes "$(masked mkXOXS "$XS" "${XS##*-}")"
bashpre "curl -H 'Authorization: Bearer $BEARER' https://example.com/api mkBEARER"
expect "mask Bearer <x>" yes "$(masked mkBEARER "$BEARER" mkBEARERpayload)"
bashpre "printf '%s' '-----BEGIN PRIVATE KEY-----
$PEMBODY
-----END PRIVATE KEY-----' > k.pem; echo mkPEM"
expect "mask PEM private key block" yes "$(masked mkPEM "$PEMBODY" MIIEvQIBADANBgkq)"
bashpre "echo '-----BEGIN OPENSSH PRIVATE KEY-----
$OSSHBODY
-----END OPENSSH PRIVATE KEY-----' mkOSSH"
expect "mask OPENSSH private key block" yes "$(masked mkOSSH "$OSSHBODY" b3BlbnNzaC1rZXktdjEAAAAA)"
bashpre "echo mkPEMCUT '-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA$(rep 'Kx' 1500)"
expect "mask PEM block with no END (cut off by truncation)" yes "$(masked mkPEMCUT MIIEpAIBAAKCAQEA KxKxKxKxKxKxKxKx)"
bashpre "git clone https://alice:$URLPW@example.com/r.git mkURLPW"
expect "mask ://user:pass@" yes "$(masked mkURLPW "$URLPW")"
expect "://user:pass@: host still visible" yes "$(has "'mkURLPW' in line and 'example.com' in line")"

# literal values: control-plane config (telegram.json "token") and env vars named in the launcher SCRUB lists
mkdir -p "$XDG_CONFIG_HOME/harness"
TGLIT="tgLit.Val+ue(9)f8e7d6c5b4a"
printf '{"token": "%s", "chat_id": 4242, "paired_user": 777}\n' "$TGLIT" > "$XDG_CONFIG_HOME/harness/telegram.json"
chmod 600 "$XDG_CONFIG_HOME/harness/telegram.json"
bashpre "echo using $TGLIT now mkTGLIT"
expect "mask literal token from config_dir()/telegram.json" yes "$(masked mkTGLIT "$TGLIT" "tgLit.Val")"
hookjson PreToolUse Bash "$(cmdin 'curl --token=servelitVALUE77xyz localhost mkENV1')" | \
  (cd "$W" && HARNESS_SERVE_TOKEN=servelitVALUE77xyz CLAUDE_PROJECT_DIR="$W" python3 -B "$W/.claude/hooks/audit_log.py") >/dev/null
expect "mask literal value of a SCRUB_ENV variable (HARNESS_SERVE_TOKEN)" yes "$(masked mkENV1 servelitVALUE77xyz)"
hookjson PreToolUse Bash "$(cmdin 'mysql -ppwLiteralQQ55rrTT db mkENV2')" | \
  (cd "$W" && MYAPP_PASSWORD=pwLiteralQQ55rrTT CLAUDE_PROJECT_DIR="$W" python3 -B "$W/.claude/hooks/audit_log.py") >/dev/null
expect "mask literal value of a SCRUB_SUFFIXES variable (*_PASSWORD)" yes "$(masked mkENV2 pwLiteralQQ55rrTT)"
# no over-masking of ordinary words
bashpre "echo mkNEG /task-run desk-lamp risk-medium"
expect "ordinary words with 'sk-' are left alone" yes "$(has "'mkNEG' in line and '/task-run desk-lamp risk-medium' in line")"

# ---------------------------------------------------------------- size caps
bashpre "echo mkBIG $(rep 'x' 10000)"
expect "input summary ≤ 1024 bytes" yes "$(has "'mkBIG' in line and len(d.get('input','').encode())<=1024")"
expect "big command: line ≤ 4096 bytes" yes "$(has "'mkBIG' in line and len(line.encode())<=4096")"
bashpre "echo mkCJK $(rep '审计' 2000)"
expect "multibyte command cut on a character boundary, ≤ 1024 bytes" yes "$(has "'mkCJK' in line and len(d.get('input','').encode())<=1024 and '\ufffd' not in line")"
audit PreToolUse "mkLONGTOOL$(rep 'T' 5000)" "{\"file_path\": \"mkLONGPATH/$(rep 'p' 6000)\"}" "sess-$(rep 's' 6000)" >/dev/null
expect "long session/tool/path: line still written and ≤ 4096 bytes" yes "$(has "'mkLONGTOOL' in line and len(line.encode())<=4096")"
TOKCUT="gh""p_$(rep 'Rt5Yu6' 6)"
bashpre "echo mkCUT $(rep 'a' 990) $TOKCUT"
expect "token straddling the 1 KB cut is masked, not half-leaked" yes "$(masked mkCUT "${TOKCUT:0:14}" "Rt5Yu6Rt5Y")"
expect "no line in the whole log exceeds 4096 bytes" 0 "$(q "len(line.encode())>4096")"

# ---------------------------------------------------------------- failures never block
printf 'not json' | (cd "$W" && python3 -B "$W/.claude/hooks/audit_log.py") >"$T/o" 2>/dev/null; RC=$?
expect "garbage stdin: exit 0" 0 "$RC"
: > "$T/afile"
hookjson PreToolUse Bash "$(cmdin 'echo mkNOWRITE')" | \
  (cd "$W" && XDG_STATE_HOME="$T/afile" python3 -B "$W/.claude/hooks/audit_log.py") >"$T/o" 2>/dev/null; RC=$?
expect "unwritable state dir: exit 0" 0 "$RC"
expect "unwritable state dir: no stdout" "" "$(cat "$T/o")"
expect "audit_log.py exists (the above are not vacuous)" yes "$([ -f "$SRC/.claude/hooks/audit_log.py" ] && echo yes || echo no)"
mkdir -p "$T/ro/harness"; ROAUD="$(XDG_STATE_HOME="$T/ro" python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.state_dir(H.store_main(Path(sys.argv[2]))))' "$R/.claude/hooks" "$R")"
mkdir -p "$ROAUD"; : > "$ROAUD/audit"   # audit is a file, not a dir: mkdir fails even as root
hookjson PostToolUse Bash "$(cmdin 'echo mkNOWRITE2')" | \
  (cd "$W" && XDG_STATE_HOME="$T/ro" python3 -B "$W/.claude/hooks/audit_log.py") >"$T/o" 2>/dev/null; RC=$?
expect "audit path blocked by a file: exit 0, no stdout" "0:" "$RC:$(cat "$T/o")"

# ---------------------------------------------------------------- guard verdicts (via H.audit)
gb() { hookjson PreToolUse Bash "$(cmdin "$1")" | (cd "$W" && env CLAUDE_PROJECT_DIR="$W" XDG_STATE_HOME="${2:-$XDG_STATE_HOME}" python3 -B "$W/.claude/hooks/guard_bash.py"); }
OUT="$(gb 'git push --force origin mkGUARD')"
expect "guard_bash still denies force push" yes "$(printf '%s' "$OUT" | grep -q '"permissionDecision": "deny"' && echo yes || echo no)"
expect "guard_bash deny → audit line with verdict deny" yes "$(has "'mkGUARD' in line and d.get('verdict')=='deny'")"
expect "guard verdict line carries task and tool" yes "$(has "'mkGUARD' in line and d.get('verdict')=='deny' and d.get('task')=='T-042' and d.get('tool')=='Bash'")"
GPW="pw4guard$(rep 'Xy' 5)"
gb "git push --force https://bob:$GPW@example.com/mkGUARD2 main" >/dev/null
expect "guard verdict line is masked too" yes "$( [ "$(has "'mkGUARD2' in line and d.get('verdict')=='deny'")" = yes ] && [ "$(leaked "$GPW")" = no ] && echo yes || echo no)"
OUT="$(gb 'git push --force origin mkGUARD3' "$T/afile")"
expect "guard still denies when the audit log can't be written" yes "$(printf '%s' "$OUT" | grep -q '"permissionDecision": "deny"' && echo yes || echo no)"
OUT="$(hookjson PreToolUse Write "{\"file_path\": \"$R/mkPROTECT.txt\", \"content\": \"mkPROTECTBODY\"}" | (cd "$W" && CLAUDE_PROJECT_DIR="$W" python3 -B "$W/.claude/hooks/protect_paths.py"))"
expect "protect_paths still denies writing the main checkout from a worktree" yes "$(printf '%s' "$OUT" | grep -q '"permissionDecision": "deny"' && echo yes || echo no)"
expect "protect_paths deny → audit line with verdict deny and the path" yes "$(has "'mkPROTECT.txt' in line and d.get('verdict')=='deny'")"
expect "protect_paths verdict line has no file content" no "$(leaked mkPROTECTBODY)"

# ---------------------------------------------------------------- gate answers (via record_answer)
python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H
print(H.record_answer(Path(sys.argv[2]), "G-T042-1", "B", "备注 mkNOTE", via="终端"))' "$R/.claude/hooks" "$R" > "$T/o" 2>&1
expect "record_answer still succeeds" True "$(tail -1 "$T/o")"
expect "answer line with via=终端 and the gate id" yes "$(has "d.get('via')=='终端' and 'G-T042-1' in line")"

# ---------------------------------------------------------------- dashboard /audit
bashpre "echo mkROW '<script>alert(9)</script>'"
start() {  # start <outfile> [env...]
  env "${@:2}" python3 "$SRC/cli/serve_cmd.py" --repo "$R" --port 0 "${EXTRA[@]}" > "$1" 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 50); do grep -q '^http://' "$1" 2>/dev/null && break; sleep 0.1; done
  grep -m1 '^http://' "$1" | sed 's#/?.*##; s#/$##'
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
EXTRA=(); U="$(start "$T/s1.out" HARNESS_SERVE_TOKEN=s3cretTok)"
JAR="$T/jar"; curl -s -o /dev/null -c "$JAR" "$U/?t=s3cretTok"
AU="$U/audit?task=T-042&day=$DAY"
expect "/audit without the token: 403" 403 "$(code "$AU")"
expect "/audit without the token: no rows leak" no "$(curl -s "$AU" | grep -q mkROW && echo yes || echo no)"
expect "/audit with a wrong cookie: 403" 403 "$(code -b 'harness_t=wrong' "$AU")"
expect "nav without the token has no audit tab" no "$(curl -s "$U/" | grep -q 'href="/audit' && echo yes || echo no)"
expect "nav with the token shows the audit tab" yes "$(curl -s -b "$JAR" "$U/" | grep -q 'href="/audit' && echo yes || echo no)"
expect "/audit with the token: 200" 200 "$(code -b "$JAR" "$AU")"
PAGE="$(curl -s -b "$JAR" "$AU")"
expect "/audit rows for the task" yes "$(printf '%s' "$PAGE" | grep -q mkROW && printf '%s' "$PAGE" | grep -q mkGUARD && echo yes || echo no)"
expect "/audit filters by task (T-077 rows absent)" no "$(printf '%s' "$PAGE" | grep -q mkOTHERTASK2 && echo yes || echo no)"
expect "/audit shows the guard verdict" yes "$(printf '%s' "$PAGE" | grep -q deny && echo yes || echo no)"
expect "/audit escapes logged text" yes "$(printf '%s' "$PAGE" | grep -q '&lt;script&gt;alert(9)&lt;/script&gt;' && echo yes || echo no)"
expect "/audit: no raw script" no "$(printf '%s' "$PAGE" | grep -q '<script>alert(9)' && echo yes || echo no)"
expect "/audit page carries no secrets" no "$(printf '%s' "$PAGE" | grep -qF -e "$GHP" -e "$TGLIT" -e "$URLPW" && echo yes || echo no)"
P77="$(curl -s -b "$JAR" "$U/audit?task=T-077&day=$DAY")"
expect "/audit?task=T-077 shows that task's rows" yes "$(printf '%s' "$P77" | grep -q mkOTHERTASK2 && echo yes || echo no)"
expect "/audit?task=T-077 excludes T-042 rows" no "$(printf '%s' "$P77" | grep -q mkROW && echo yes || echo no)"
expect "/audit other day: no rows" no "$(curl -s -b "$JAR" "$U/audit?task=T-042&day=1999-01-01" | grep -q mkROW && echo yes || echo no)"
TRAV="$(curl -s -b "$JAR" -w '\n%{http_code}' "$U/audit?task=T-042&day=../../../../etc/passwd")"
expect "/audit day traversal: no foreign file, no 500" yes "$(printf '%s' "$TRAV" | grep -q 'root:' || [ "$(printf '%s' "$TRAV" | tail -1)" = 500 ] && echo no || echo yes)"
# POST answer from the dashboard → answer line with via=看板
curl -s -o /dev/null -b "$JAR" -H "Origin: $U" --data-urlencode "gate=G-T042-2" --data-urlencode "letter=A" --data-urlencode "note=" "$U/answer"
expect "dashboard answer → audit line with via=看板" yes "$(has "d.get('via')=='看板' and 'G-T042-2' in line")"
EXTRA=(--read-only); U2="$(start "$T/s2.out" HARNESS_SERVE_TOKEN=s3cretTok)"
expect "read-only board: /audit 403" 403 "$(code "$U2/audit?task=T-042&day=$DAY")"
expect "read-only board: no audit tab" no "$(curl -s "$U2/" | grep -q 'href="/audit' && echo yes || echo no)"

# ================================================================ 接口约定 v2（第 2 轮）
# ---------------------------------------------------------------- (1) masking on a normalised copy
B36="$(rep 'Bq4Nn2' 6)"; C18a="$(rep 'Cw5' 6)"; C18b="$(rep 'Cv6' 6)"; D36="$(rep 'Dk7Mm1' 6)"
E35="AAE$(rep 'e7F-g_' 5)Z9"; F36="$(rep 'Fu8Hh3' 6)"; G36="$(rep 'Gr2Jj9' 6)"
bashpre "echo \"gh\"\"p_$B36\" mkQSPLIT"
expect "v2 mask: quote-split ghp_ (\"gh\"\"p_…\")" yes "$(masked mkQSPLIT "$B36")"
bashpre "echo gh'p_'$B36 mkQSPLIT2"
expect "v2 mask: quote-split ghp_ (gh'p_'…)" yes "$(masked mkQSPLIT2 "$B36")"
bashpre "echo ghp_$C18a\\
$C18b mkBSNL"
expect "v2 mask: backslash-newline split ghp_ (both halves gone)" yes "$(masked mkBSNL "$C18a" "$C18b")"
bashpre "curl \"https://e.example/?q=ghp%5F$D36\" mkPCT1"
expect "v2 mask: %5F-encoded ghp_" yes "$(masked mkPCT1 "$D36")"
bashpre "curl \"https://api.telegram.org/bot7012345678%3A$E35/getMe\" mkPCT2"
expect "v2 mask: %3A-encoded Telegram token" yes "$(masked mkPCT2 "$E35")"
bashpre "printf '\\u0067\\u0068p_$F36' mkUESC"
expect "v2 mask: literal \\uXXXX escapes spelling ghp_" yes "$(masked mkUESC "$F36")"
bashpre "curl -H 'Authorization: token opaqueAuthTok8f7e6d' https://api.github.com mkAUTHTOK"
expect "v2 mask: Authorization: token <x>" yes "$(masked mkAUTHTOK opaqueAuthTok8f7e6d)"
bashpre "git clone https://x-access-token:opaqueInstTok987654@github.com/o/r.git mkXAT1"
expect "v2 mask: https://x-access-token:<tok>@" yes "$(masked mkXAT1 opaqueInstTok987654)"
bashpre "git clone https://opaqueUserTok12345:x-access-token@github.com/o/r.git mkXAT2"
expect "v2 mask: token as the user part next to x-access-token" yes "$(masked mkXAT2 opaqueUserTok12345)"
bashpre "curl 'https://api.example.com/v1/me?access_token=opaqueQueryTok55555&x=1' mkACCQ"
expect "v2 mask: ?access_token=" yes "$(masked mkACCQ opaqueQueryTok55555)"
bashpre "DB_PASSWORD=plainpw77xq ./run.sh mkPASSEQ"
expect "v2 mask: *PASS*=value" yes "$(masked mkPASSEQ plainpw77xq)"
bashpre "export STRIPE_SECRET_KEY=opaqueStripe4455 mkSECRETEQ"
expect "v2 mask: *SECRET*/*KEY*=value" yes "$(masked mkSECRETEQ opaqueStripe4455)"
bashpre "MY_TOKEN=abc12345tokx make deploy mkTOKENEQ"
expect "v2 mask: *TOKEN*=value" yes "$(masked mkTOKENEQ abc12345tokx)"
bashpre "cat > .env <<'EOF' # mkHEREDOC
DB_PASSWORD=hunter9secretX
mkHEREBODY plain line
EOF"
expect "v2 heredoc: body with DB_PASSWORD= dropped" yes "$(masked mkHEREDOC hunter9secretX mkHEREBODY)"
expect "v2 heredoc: first line kept" yes "$(has "'mkHEREDOC' in line and 'cat > .env' in d.get('input','')")"
bashpre "echo mkNEG2 token-bucket KEYBOARD layout --pretty=%H"
expect "v2 no over-masking: ordinary words kept" yes "$(has "'mkNEG2' in line and 'token-bucket KEYBOARD layout --pretty=%H' in d.get('input','')")"
bashpre "curl 'https://e.example/a%20b' mkPCTKEEP"
expect "v2: only the copy is normalised (original %20 kept)" yes "$(has "'mkPCTKEEP' in line and 'a%20b' in d.get('input','')")"
gb "git push --force \"https://gh\"\"p_$G36@github.com/o/r\" mkGQS" >/dev/null
expect "v2 guard verdict line: quote-split token masked" yes "$( [ "$(has "'mkGQS' in line and d.get('verdict')=='deny'")" = yes ] && [ "$(leaked "$G36")" = no ] && echo yes || echo no)"

# ---------------------------------------------------------------- (2) writes never block, never follow links
statedir() { XDG_STATE_HOME="$1" python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(H.state_dir(H.store_main(Path(sys.argv[2]))))' "$R/.claude/hooks" "$R"; }
DAYS2="$(date +%F) $(date -u +%F)"
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
# runh <state> <script> <stdin-json> -> "<rc>:<ms>"; stdout in $T/ro.out
runh() { local s0; s0=$(date +%s%N); printf '%s' "$3" | (cd "$W" && env XDG_STATE_HOME="$1" CLAUDE_PROJECT_DIR="$W" timeout 5 python3 -B "$W/.claude/hooks/$2") > "$T/ro.out" 2>/dev/null; echo "$?:$(ms "$s0")"; }
fast() { local rc="${1%%:*}" t="${1##*:}"; [ "$rc" = 0 ] && [ "$t" -lt 2000 ] && echo yes || echo "no($1)"; }
denied() { grep -q '"permissionDecision": "deny"' "$T/ro.out" && echo yes || echo no; }

S2="$T/st-fifo"; A2="$(statedir "$S2")/audit"; mkdir -p "$A2"; chmod 700 "$(dirname "$A2")" "$A2"
for dd in $DAYS2; do [ -e "$A2/$dd.jsonl" ] || mkfifo "$A2/$dd.jsonl"; done
expect "v2 FIFO at the day file: audit hook exits 0 within 2s" yes "$(fast "$(runh "$S2" audit_log.py "$(hookjson PreToolUse Bash "$(cmdin 'echo mkFIFO')")")")"
expect "v2 FIFO: guard_bash returns within 2s" yes "$(fast "$(runh "$S2" guard_bash.py "$(hookjson PreToolUse Bash "$(cmdin 'git push --force origin mkFIFOG')")")")"
expect "v2 FIFO: guard_bash still denies" yes "$(denied)"
expect "v2 FIFO: protect_paths returns within 2s" yes "$(fast "$(runh "$S2" protect_paths.py "$(hookjson PreToolUse Write "{\"file_path\": \"$R/mkFIFOP.txt\", \"content\": \"x\"}")")")"
expect "v2 FIFO: protect_paths still denies" yes "$(denied)"
expect "v2 FIFO is left a FIFO (not replaced)" yes "$(for dd in $DAYS2; do [ -p "$A2/$dd.jsonl" ] || echo bad; done | grep -q bad && echo no || echo yes)"
RA0=$(date +%s%N); RAOUT="$(XDG_STATE_HOME="$S2" timeout 5 python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; print(len(H.read_audit(Path(sys.argv[2]), sys.argv[3])))' "$R/.claude/hooks" "$R" "$(date +%F)" 2>/dev/null; echo "rc=$?")"
expect "v2 FIFO: read_audit returns [] within 2s" yes "$(printf '%s' "$RAOUT" | grep -q '^0' && [ "$(ms "$RA0")" -lt 2000 ] && echo yes || echo "no($RAOUT)")"

S3="$T/st-link"; A3="$(statedir "$S3")/audit"; mkdir -p "$A3"; chmod 700 "$(dirname "$A3")" "$A3"
: > "$T/victim"; chmod 600 "$T/victim"
for dd in $DAYS2; do ln -sfn "$T/victim" "$A3/$dd.jsonl"; done
expect "v2 day file is a symlink: hook exits 0" yes "$(fast "$(runh "$S3" audit_log.py "$(hookjson PreToolUse Bash "$(cmdin 'echo mkVICTIM')")")")"
expect "v2 day file is a symlink: nothing written through it" 0 "$(wc -c < "$T/victim" | tr -d ' ')"
S3b="$T/st-dangle"; A3b="$(statedir "$S3b")/audit"; mkdir -p "$A3b"; chmod 700 "$(dirname "$A3b")" "$A3b"
for dd in $DAYS2; do ln -sfn "$T/created-via-link-$dd" "$A3b/$dd.jsonl"; done
runh "$S3b" audit_log.py "$(hookjson PreToolUse Bash "$(cmdin 'echo mkDANGLE')")" >/dev/null
expect "v2 dangling day-file symlink: target not created" no "$(ls "$T" | grep -q created-via-link && echo yes || echo no)"

S4="$T/st-dirlink"; SD4="$(statedir "$S4")"; mkdir -p "$SD4" "$T/elsewhere"; chmod 700 "$SD4"
ln -s "$T/elsewhere" "$SD4/audit"
expect "v2 audit dir is a symlink: hook exits 0" yes "$(fast "$(runh "$S4" audit_log.py "$(hookjson PreToolUse Bash "$(cmdin 'echo mkDIRLINK')")")")"
runh "$S4" guard_bash.py "$(hookjson PreToolUse Bash "$(cmdin 'git push --force origin mkDIRLINKG')")" >/dev/null
expect "v2 audit dir is a symlink: guard still denies" yes "$(denied)"
expect "v2 audit dir is a symlink: nothing written through it" "" "$(ls -A "$T/elsewhere")"

# ---------------------------------------------------------------- (3) retention
d_ago() { date -d "-$1 days" +%F; }
S6="$T/st-keep"; A6="$(statedir "$S6")/audit"; mkdir -p "$A6"; chmod 700 "$(dirname "$A6")" "$A6"
OLD40="$(d_ago 40)"; OLD10="$(d_ago 10)"
for f in "$OLD40" "$OLD10" 2000-01-01; do echo '{"ts":"x","task":"T-042"}' > "$A6/$f.jsonl"; chmod 600 "$A6/$f.jsonl"; done
touch -d "-40 days" "$A6/$OLD40.jsonl" "$A6/2000-01-01.jsonl"; touch -d "-10 days" "$A6/$OLD10.jsonl"
echo keep > "$A6/notes.txt"; touch -d "-400 days" "$A6/notes.txt"
echo keep > "$T/keepme"; ln -s "$T/keepme" "$A6/2000-01-02.jsonl"
runh "$S6" audit_log.py "$(hookjson PreToolUse Bash "$(cmdin 'echo mkPRUNE')")" >/dev/null
expect "v2 prune on write: file 40 days old removed (default 30)" no "$([ -e "$A6/$OLD40.jsonl" ] && echo yes || echo no)"
expect "v2 prune on write: 2000-01-01 removed" no "$([ -e "$A6/2000-01-01.jsonl" ] && echo yes || echo no)"
expect "v2 prune on write: file 10 days old kept" yes "$([ -e "$A6/$OLD10.jsonl" ] && echo yes || echo no)"
expect "v2 prune on write: other names untouched" yes "$([ -e "$A6/notes.txt" ] && echo yes || echo no)"
expect "v2 prune never follows a symlink to its target" keep "$(cat "$T/keepme" 2>/dev/null)"
expect "v2 prune on write: today's line still written" yes "$(grep -rqs mkPRUNE "$A6" && echo yes || echo no)"
printf '%s' "$(hookjson PreToolUse Bash "$(cmdin 'echo mkPRUNE5')")" | (cd "$W" && env XDG_STATE_HOME="$S6" HARNESS_AUDIT_DAYS=5 timeout 5 python3 -B "$W/.claude/hooks/audit_log.py") >/dev/null 2>&1
expect "v2 HARNESS_AUDIT_DAYS=5: file 10 days old removed" no "$([ -e "$A6/$OLD10.jsonl" ] && echo yes || echo no)"

S7="$T/st-down"; A7="$(statedir "$S7")/audit"; mkdir -p "$A7"; chmod 700 "$(dirname "$A7")" "$A7"
for f in "$OLD40" "$OLD10" "$(date +%F)"; do printf '{"ts":"x","task":"T-042","pad":"%s"}\n' "$(rep p 500)" > "$A7/$f.jsonl"; chmod 600 "$A7/$f.jsonl"; done
touch -d "-40 days" "$A7/$OLD40.jsonl"; touch -d "-10 days" "$A7/$OLD10.jsonl"
mkdir -p "$T/cbin" "$T/trapbin"
printf '#!/bin/sh\n[ "$1" = -l ] && exit 1\ncat >/dev/null\n' > "$T/cbin/fake-crontab"
printf '#!/bin/sh\necho "$*" >> "%s/real-crontab-called"\nexit 1\n' "$T" > "$T/trapbin/crontab"
chmod +x "$T/cbin/fake-crontab" "$T/trapbin/crontab"
hn() { (cd / && env XDG_STATE_HOME="$S7" HARNESS_CRONTAB="$T/cbin/fake-crontab" HARNESS_GATE_CHANNEL=off PATH="$T/trapbin:$PATH" \
        timeout 30 python3 -B "$SRC/bin/harness" "$@"); }
hn doctor --repo "$R" > "$T/doctor.out" 2>&1
AUDSEC="$(awk '$0=="## 审计日志"{p=1;next} /^## /{p=0} p' "$T/doctor.out")"
expect "v2 doctor: has a '## 审计日志' section" yes "$(grep -qx '## 审计日志' "$T/doctor.out" && echo yes || echo no)"
expect "v2 doctor: reports the audit log size" yes "$(printf '%s' "$AUDSEC" | grep -qE '[0-9]+(\.[0-9]+)? ?(B|KB|MB|GB|KiB|MiB|GiB|字节)' && echo yes || echo no)"
hn down --repo "$R" --prune-audit > "$T/down.out" 2>&1; RC=$?
expect "v2 harness down --prune-audit: exit 0" 0 "$RC"
expect "v2 down --prune-audit: file 40 days old removed" no "$([ -e "$A7/$OLD40.jsonl" ] && echo yes || echo no)"
expect "v2 down --prune-audit: recent files kept" yes "$([ -e "$A7/$OLD10.jsonl" ] && [ -e "$A7/$(date +%F).jsonl" ] && echo yes || echo no)"
expect "v2 doctor/down never ran the real crontab" no "$([ -e "$T/real-crontab-called" ] && echo yes || echo no)"

S8="$T/st-read"; A8="$(statedir "$S8")/audit"; mkdir -p "$A8"; chmod 700 "$(dirname "$A8")" "$A8"
python3 -B - "$A8/2026-01-15.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for i in range(2500):
        f.write(json.dumps({"ts": "2026-01-15T00:00:00", "task": "T-042" if i < 100 else "T-077", "n": i}) + "\n")
PY
RD="$(XDG_STATE_HOME="$S8" timeout 5 python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H
a = H.read_audit(Path(sys.argv[2]), "2026-01-15"); b = H.read_audit(Path(sys.argv[2]), "2026-01-15", "T-042")
print(len(a), a[-1].get("n") if a else -1, len(b))' "$R/.claude/hooks" "$R" 2>/dev/null)"
expect "v2 read_audit: at most the last 2000 lines, newest included" "2000 2499" "$(printf '%s' "$RD" | cut -d' ' -f1,2)"
expect "v2 read_audit: lines older than the last 2000 are not read (task filter)" 0 "$(printf '%s' "$RD" | cut -d' ' -f3)"

expect "audit_log.py stdlib only" "" "$(grep -E '^(import|from) ' "$SRC/.claude/hooks/audit_log.py" 2>/dev/null | grep -vE '^(import|from) (datetime|glob|hashlib|harness_lib|io|json|os|pathlib|re|stat|sys|time|typing|__future__)\b|^import harness_lib as H' ; [ -f "$SRC/.claude/hooks/audit_log.py" ] || echo missing)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
