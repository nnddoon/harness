# S-003 独立审查 R-1（摘录，原文在项目文档 claude/S-003-review.md）

审查对象 `integration/S-003` @ `bc46b8b`。2026-11-15 在 main `1fafe7c` 上复现仍成立。

## R-1 JS 测试运行器的配置文件不算验证入口
- 现象：verify.sh 跑 `npm run test`，`package.json` 写 `"test": "jest"`。任务分支只改 `jest.config.js`（例如 `testMatch: []` 再加 `passWithNoTests: true`），control-diff 不会命中，strict 的 denyWrite 也没有它，验证永远通过然后被合并。vitest、mocha、playwright 同理。
- 对照：只改 `package.json` 两道关都能拦下；pytest 的 `conftest.py`、`pytest.ini` 已锁。
- 原因：`VERIFY_ENTRY_RULES` 识别到 npm 之后只锁 `NPM_ENTRY`，没有继续读 test 脚本用的运行器。
- 建议修法（用户选了这条，做 0.2.2）：读出 verify 调用到的 `package.json` scripts，按运行器加配置文件，例如 `jest.config.*`、`vitest.config.*`、`vite.config.*`、`.mocharc*`、`playwright.config.*`、`karma.conf.*`、`cypress.config.*`、`ava.config.*`、`.nycrc*`、`.c8rc*`、`babel.config.*`、`.babelrc*`；scripts 里用 `node <路径>` 调用的仓库文件也锁上。

## 复现
```python
# python3 -I probe_ctl.py <仓库>/pkg/.claude/hooks
import json, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import harness_lib as H
G = ["git", "-c", "user.name=t", "-c", "user.email=t@t"]
d = Path(tempfile.mkdtemp())
run = lambda *a: subprocess.run(list(a), cwd=d, check=True, capture_output=True, text=True)
run("git", "init", "-q", "-b", "main")
(d / ".harness").mkdir()
(d / ".harness" / "verify.sh").write_text("#!/usr/bin/env bash\nset -e\nnpm run test\n")
(d / "package.json").write_text(json.dumps({"scripts": {"test": "jest"}}))
(d / "jest.config.js").write_text("module.exports = {}\n")
run(*G, "add", "-A"); run(*G, "commit", "-qm", "init")
for f, body in (("jest.config.js", "module.exports = { testMatch: [], passWithNoTests: true }\n"),
                ("package.json", json.dumps({"scripts": {"test": "jest --passWithNoTests"}}))):
    br = "t-" + f.replace(".", "-")
    run("git", "checkout", "-q", "-b", br, "main")
    (d / f).write_text(body)
    run(*G, "commit", "-qam", "weaken")
    print(f, "->", H.control_diff(d, "main", br) or "none (would merge)")
    run("git", "checkout", "-q", "main")
```
修复前输出：`jest.config.js -> none (would merge)`；`package.json -> ['package.json']`。
