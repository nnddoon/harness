#!/usr/bin/env python3
"""Stop hook: keep the "待你决定 / Decisions Needed" section of a reply honest.

Every top-level item in that section must either
  - reference a gate card (G-T013-2, G-GROOM-20261109 ...) — preferred: it persists, or
  - start with a gate-kind label:
      [design] [ui] [sensory] [irreversible] [external] [ambiguity] [unlock]
      [设计] [界面] [感官] [不可逆] [对外] [歧义] [解锁]   (traditional forms also accepted)
An item that fits none of them is work the model should just do, so the reply is blocked.

Content rules for items without a gate card (the card would carry this information):
  - ui / sensory: must say how to check — a command in backticks, a URL, or a file path.
  - design / ambiguity: must say what each option gains or costs (at least two merit words).

Adapted from danyuchn/claude-work-mode's decision-label-guard (MIT), mapped onto this
harness's gate kinds. Fail-open on any parse problem; the second pass (stop_hook_active)
always passes. HARNESS_DECISION_GUARD=off disables it.
"""
import json
import os
import re
import sys

KINDS = {
    "design": "design", "设计": "design", "設計": "design",
    "ui": "ui", "界面": "ui", "介面": "ui", "ux": "ui",
    "sensory": "sensory", "感官": "sensory",
    "irreversible": "irreversible", "不可逆": "irreversible",
    "external": "external", "对外": "external", "對外": "external",
    "ambiguity": "ambiguity", "歧义": "ambiguity", "歧義": "ambiguity",
    "unlock": "unlock", "解锁": "unlock", "解鎖": "unlock",
}
LABEL = re.compile(r"[\[【]\s*(" + "|".join(re.escape(k) for k in KINDS) + r")\s*[\]】]", re.I)
GATE_ID = re.compile(r"\bG-[A-Z0-9]+-\d+\b")
HEADING = re.compile(
    r"^\s*(?:#+\s*|\*\*)?\s*(?:还|還)?(?:待你决定|待你決定|需要你决定|需要你決定|要你决定|要你決定|待决事项|待決事項"
    r"|人工门|人工門|待确认|待確認|Decisions?\s+Needed|Needs?\s+Your\s+Decision|Pending\s+Decisions?|Human\s+Gates?)"
    r"(?P<tail>[^。？?！!\n]{0,24})$", re.I)
ITEM = re.compile(r"^(\d+[.)、]|[-*])\s+\S")
BREAK = re.compile(r"^\s*(#+\s|\*\*[^*]+\*\*\s*[:：]?\s*$)")
EMPTY = re.compile(
    r"^(?:\d+[.)、]|[-*])\s+(?:(?:目前|暂时|暫時)?(?:无|没有|無|沒有)(?:其他|任何|新的)?"
    r"(?:需要你?决定|需要你?決定|要你决定|要你決定|待决|待決)?(?:的)?(?:事|事项|事項|项目|項目)?了?"
    r"|none|nothing(?: pending| to decide)?|n/a|no pending decisions?)\s*[。.!！]?\s*$", re.I)
HOW = re.compile(r"`[^`\n]+`|https?://\S+|(?<![\w.])[\w~./-]*[\w-]\.[A-Za-z][A-Za-z0-9]{1,4}\b")
MERIT = re.compile(
    r"好处|好處|优点|優點|优势|優勢|代价|代價|缺点|缺點|风险|風險|好在|但会|但會|不过会|不過會|省下|换来|換來|失去"
    r"|\b(pros?|cons?|benefits?|upsides?|downsides?|gains?|costs?|risks?|trade-?offs?)\b", re.I)


def items(msg: str) -> list:
    text = re.sub(r"```.*?```", " ", msg, flags=re.S)
    lines, out, i = text.splitlines(), [], 0
    while i < len(lines):
        m = HEADING.match(lines[i].strip()[:200])
        if not m:
            i += 1
            continue
        tail = re.sub(r"^[^:：]*[:：]", "", m.group("tail")).strip(" *") if re.search(r"[:：]", m.group("tail")) else ""
        i += 1
        if tail and not re.match(r"^[\d一二两兩三四五六七八九十]+\s*(项|項|件|个|個|items?)?\s*[。.]?$", tail, re.I):
            if not EMPTY.match("- " + tail):
                out.append([tail])
        while i < len(lines):
            ln = lines[i]
            if not ITEM.match(ln) and (BREAK.match(ln) or (ln.strip() and not ln[0].isspace())):
                break
            if ITEM.match(ln):
                if not EMPTY.match(ln.strip()):
                    out.append([ln])
            elif out and ln.strip():
                out[-1].append(ln)
            i += 1
    return out


def check(msg: str):
    unlabeled, no_how, one_sided = [], [], []
    for block in items(msg):
        head, whole = block[0], "\n".join(block)
        if GATE_ID.search(whole):
            continue
        m = LABEL.search(head)
        if not m:
            unlabeled.append(head.strip()[:70])
            continue
        kind = KINDS.get(m.group(1).lower(), "")
        body = LABEL.sub(" ", whole)
        if kind in ("ui", "sensory") and not HOW.search(body):
            no_how.append(head.strip()[:70])
        if kind in ("design", "ambiguity") and len(MERIT.findall(body)) < 2:
            one_sided.append(head.strip()[:70])
    return unlabeled, no_how, one_sided


def reason(unlabeled, no_how, one_sided) -> str:
    parts = []
    if unlabeled:
        parts.append("「待你决定」里这些项目既没有引用门卡（G-xxx），也没有类别标签：\n  " + "\n  ".join(unlabeled) +
                     "\n真正需要人判断的：先 /human-gate 建门卡并在这里引用编号，或在开头标 [design] [ui] [sensory] "
                     "[irreversible] [external] [ambiguity] [unlock] 之一。套不进任何类别的是本地可回退的事，"
                     "直接做掉并列为已完成，不要停下来问。")
    if no_how:
        parts.append("这些 [ui]/[sensory] 项目没写怎么检查：\n  " + "\n  ".join(no_how) +
                     "\n写清楚检查方式（反引号包住的命令、URL 或文件路径）和要看/听什么；机器能测的先测完。"
                     "或者直接 /human-gate 建卡并引用编号。")
    if one_sided:
        parts.append("这些 [design]/[ambiguity] 项目没讲两边各自的得失：\n  " + "\n  ".join(one_sided) +
                     "\n写明每个选项的好处/代价（例如「A 好在…但会…；B 则…」）。讲不出来说明只有一条路合理，"
                     "直接按推荐做并记录到 .harness/decisions.md。")
    return "[harness] DECISION GUARD：" + "\n".join(parts)


def main() -> None:
    if os.environ.get("HARNESS_DECISION_GUARD") == "off":
        return
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(data, dict) or data.get("stop_hook_active"):
        return
    msg = data.get("last_assistant_message") or ""
    if not isinstance(msg, str) or not msg:
        return
    u, h, o = check(msg)
    if u or h or o:
        print(json.dumps({"decision": "block", "reason": reason(u, h, o)}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # fail open
        print(f"[harness] decision_guard error: {e}", file=sys.stderr)
    sys.exit(0)
