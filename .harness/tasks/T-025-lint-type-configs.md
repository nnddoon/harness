---
id: T-025
title: 0.2.2：Python 与 Vue 的 lint / 类型检查配置算验证入口
status: review
priority: P0
risk: medium
size: S
source: human
spec: S-003
test_owner: tester
branch: task/T-025-lint-type-configs
worktree: .claude/worktrees/T-025
session: auto
depends_on: [T-023]
context_files: [docs/feedback/s003-review-r1.md, docs/feedback/r1-hotfix-scope.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/tests/test_lint_configs.sh, pkg/plugin/RELEASED.json, pkg/README.md, plugins/harness/**, docs/feedback/r1-hotfix-scope.md]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-025 0.2.2：Python 与 Vue 的 lint / 类型检查配置算验证入口

## 1. 背景与目标
项目文档 `R-1-hotfix-scope.md`（存档为 `docs/feedback/r1-hotfix-scope.md`）在 v0.2.1 上实测：用户的项目以 Python 和 Vue 为主，verify.sh 里的 lint / 类型检查 / 格式检查读的配置都没锁（`tsconfig*.json`、`eslint.config.*`、`.prettierrc*`、`mypy.ini`、`ruff.toml`、`.flake8`、`.coveragerc`；`uv run`、`poetry run` 前缀也没剥）。T-023 只补了 JS 测试运行器。T-024 的范围检查会从结果一侧兜底，但 strict 的 denyWrite 与 doctor 仍靠这张入口表；Mac 复测第 5 项也按这张表验收。

## 2. 范围
**做：**
- 在 T-023 的 `_JsScan` 运行器表里加：eslint（`eslint.config.*`、`.eslintrc*`、`.eslintignore`）、prettier（`.prettierrc*`、`prettier.config.*`、`.prettierignore`）、tsc / vue-tsc（`tsconfig*.json`，含 `tsconfig.app.json`、`tsconfig.vitest.json` 等）、vite（`vite.config.*`）、stylelint（`.stylelintrc*`、`stylelint.config.*`）。保守分支 JS_ALL 同步扩充。
- Python：verify 层与 package.json script 里都识别 ruff（`ruff.toml`、`.ruff.toml`，pyproject 已锁）、mypy（`mypy.ini`、`.mypy.ini`）、flake8（`.flake8`）、coverage / pytest-cov（`.coveragerc`）、pylint（`.pylintrc`、`pylintrc`）、black / isort（pyproject 已锁）。
- 前缀剥离：`uv run X`、`poetry run X`、`pipenv run X`、`hatch run X`、`pdm run X`、`python -m X` 先剥前缀再按 X 识别（现有 `python -m` 规则保留）。
- lock 文件不算验证入口（依赖门管）。
- doctor 表外运行器提示不变。

**不做（明确排除）：**
- 不读 tsconfig 的 `references` / `extends` 指向的文件（`tsconfig*.json` glob 已覆盖同目录；跨目录 → S-004）。
- 不改 T-024 范围检查。

## 接口约定（tester 写，builder 照此实现；测试在 `pkg/tests/test_lint_configs.sh`）

全部改动在 `pkg/.claude/hooks/harness_lib.py`；函数签名不变（`verify_entry_paths(root)`、`control_diff(root, base, branch, task="")`、`strict_settings`），T-023 / T-018 的已有断言全部保持（尤其「`d/package.json` 不存在 → 只有 `NPM_ENTRY`」「`make` → `MAKE_ENTRY`」「`cargo` / `go` 精确集合」「`python3 -m unittest` → PY_ENTRY + `unittest.py` + `unittest/**`」）。glob 都相对命令所在目录 `d`（`cd` / `-C` / `--prefix` 照旧）。

**J. JS 侧：新表 `JS_TOOL_ENTRY`（lint / 类型检查 / 构建工具）**
| 命令词 | glob |
|---|---|
| eslint | `eslint.config.*` `.eslintrc*` `.eslintignore` |
| prettier | `.prettierrc*` `prettier.config.*` `.prettierignore` |
| tsc、vue-tsc | `tsconfig*.json` |
| vite | `vite.config.*` |
| stylelint | `.stylelintrc*` `stylelint.config.*` `.stylelintignore` |
- 识别方式与 T-023 运行器完全相同（同一套命令词逻辑）：跳过 `VAR=值` / `env` / `cross-env` / `dotenv … --`，跳过包装器 `npx [选项]` / `npm exec` / `pnpm exec|dlx` / `yarn dlx|exec` / `bunx`，取 basename（`node_modules/.bin/eslint` = eslint）；`yarn eslint .` / `pnpm vue-tsc`（不是 script 名时）同样识别。出现在 package.json script 里、verify.sh / quick-check.sh / 被跟进的脚本里（`_js_direct`）都算。只认命令位置：`echo eslint` 不算。
- 命中 → 该工具 glob + `JS_BABEL`（verify 层直接调用时另加 `package.json`，eslint / prettier / stylelint 读 package.json 里的配置键）。
- **这些工具不算「识别到运行器」（不置 `found`）**：它们会顺带读（import / include / references）项目里其他配置，枚举不全。所以一次 npm 类调用若只跑了 lint / 类型检查 / 构建工具，仍按 T-023 v2 D1 加 `JS_ALL`；verify 层直接调用（`eslint .`、`npx vue-tsc --build`）同样再加 `JS_ALL`。同一次调用里识别到测试运行器（如 vitest）时不保守，工具 glob 精确加上。
- `JS_ALL` = 全部 `JS_RUNNER_ENTRY` ∪ 全部 `JS_TOOL_ENTRY` ∪ `JS_BABEL` ∪ `JS_BUN`（D9 的 `**/` 版本随之扩充）。
- 文件参数沿用 T-023（`--config X`、`-c X`、以 `.json` 等结尾的字面词）；另把 `--ignore-path X` / `--ignore-path=X` 的值当文件锁（eslint / prettier / stylelint）。`tsc -p tsconfig.build.json` 由已有的 `.json` 词规则锁住。

**P. Python 侧：新表 `PY_TOOL_ENTRY`**
| 命令词（剥前缀后） | glob（另加 `PY_ENTRY`） |
|---|---|
| ruff | `ruff.toml` `.ruff.toml` |
| mypy、dmypy | `mypy.ini` `.mypy.ini` |
| flake8 | `.flake8` |
| pylint | `.pylintrc` `pylintrc` `.pylintrc.toml` `pylintrc.toml` |
| coverage | `.coveragerc` |
| black | （只有 `PY_ENTRY`） |
| isort | `.isort.cfg` |
- `PY_ALL` = `PY_ENTRY` ∪ 全部 `PY_TOOL_ENTRY` glob。
- **pytest / py.test / tox / nox（命令词）→ `PY_ALL`**：pytest 的插件（pytest-cov、pytest-mypy、pytest-ruff、pytest-flake8、pytest-pylint、pytest-isort）可由 pyproject / pytest.ini 的 `addopts` 打开，tox / nox 跑任意环境，都会读这些配置。因此 `pytest --cov` 必有 `.coveragerc`；`uv run pytest -q && make lint` 里 Makefile 配方虽不读（T-023 §8 N2），`ruff.toml` 仍经 pytest 锁住。
- 现有 `py` 正则规则不动（任意位置的 `pytest|tox|nox` 或 `python -m` → `PY_ENTRY`，`python -m X` → `X.py` `X/**`），新增的只是按命令词追加上表。
- 识别位置：放在 `_rule_entries` 里，因此 verify.sh / quick-check.sh / 被跟进的脚本 / package.json script 的段都生效。命令词逻辑同 J（跳过 `VAR=值`、`env`、`_LEAD`；basename：`.venv/bin/ruff` = ruff）。`echo ruff` 不算。
- **前缀剥离**（可叠加，如 `uv run python -m pytest`）：
  - `uv run [选项] X`、`poetry run X`、`pipenv run X`、`hatch run [ENV:]X`、`pdm run [选项] X`、`python[0-9.]* [选项] -m X` → 按 X 识别。
  - 选项：以 `-` 开头的词跳过；`--` 结束选项；取值选项（不带 `=` 时再跳一个词）：uv 的 `--with` `--with-editable` `--with-requirements` `--extra` `--group` `--only-group` `--no-group` `--package` `--python`/`-p` `--env-file` `--index` `--directory` `--project`；pdm 的 `-p`/`--project` `--venv`；python 的 `-W` `-X`。例：`uv run --frozen --extra dev mypy src` → mypy。
  - `uv run --directory X …` / `uv run --project X …` / `pdm run -p X …` → 目录换成 X（字面、仓库内；否则留在原目录）。
  - 前缀本身：任何一个前缀出现 → 至少 `PY_ENTRY`；`pipenv` 另加 `Pipfile`（`[scripts]` 在里面），`hatch` 另加 `hatch.toml`。
  - 剥前缀后 X 不是已知 Python 工具（如 `pipenv run test`、`hatch run lint:all`、`uv run ./tools/check`）→ 保守 `PY_ALL`。X 是 `python -m Y` → 继续剥。
  - `coverage run [选项] -m X …` / `coverage run X.py` 与 nyc 一样：`.coveragerc` 之外继续识别 X（`coverage run -m pytest` → `PY_ALL`）。
- 配置路径参数（字面、仓库内才锁；值含 `=` 或空格（如 ruff 的内联 `--config "lint.select=[]"`）不锁）：`--config` `--config-file` `--rcfile` `--cov-config` `--settings-path`（含 `=` 形式）。例：`mypy --config-file ci/mypy.ini src` → `ci/mypy.ini`。
- **`make` 不变**：只有 `make` 的 verify → 仍只是 `MAKE_ENTRY`，不加任何 Python / JS glob（配方不读，T-024 兜底）。

**L. lock 文件不是验证入口**：`uv.lock` `poetry.lock` `Pipfile.lock` `pdm.lock` `package-lock.json` `npm-shrinkwrap.json` `pnpm-lock.yaml` `yarn.lock` `bun.lockb` `bun.lock` 不出现在 `verify_entry_paths` 里；任务分支只改它们 → control-diff 不命中（依赖门管）。

**D. doctor**：不改；「## 验证入口文件」自然列出新 glob；`UNKNOWN_RUNNERS` 不变。

**发版**：VERSION 保持 `0.2.2`（T-023 已升），重建插件与 `RELEASED.json`；README 的 `### 0.2.2` 一节加一行「Python / Vue 的 lint、类型检查、覆盖率配置算验证入口；`uv run` 等前缀会剥」。

## 接口约定 v2（第 2 轮，独立审查 FAIL 后；测试在 `pkg/tests/test_lint_configs.sh`「v2」一节；与上面冲突处以 v2 为准）

原则：一个工具若**按文件就近查找配置**（层叠配置），在子目录**新建**一份配置就能让它对那部分文件放宽，所以要锁 `**/` 版本（相对命令所在目录 `d`，`cd api && ruff` → `api/**/ruff.toml`）。上面 v1 表里的根目录字面项**全部保留**（已有断言 `ruff.toml`、`.prettierrc*` 等仍按字面出现），`**/` 项是追加。`PY_ALL`、`JS_ALL` 仍是各自所有表的并集，因此自动带上这些 `**/` 项（pytest / tox / nox、前缀后不认识的命令、只跑 lint 工具的 npm 调用都会锁子目录配置）。

- **D1 ruff（必修）**：ruff 按文件取最近的 `ruff.toml` / `.ruff.toml` / 含 `[tool.ruff]` 的 `pyproject.toml`。`PY_TOOL_ENTRY["ruff"]` = `ruff.toml` `.ruff.toml` `**/ruff.toml` `**/.ruff.toml` `**/pyproject.toml`。例：`ruff check .` 时任务分支新建 `src/ruff.toml` 或 `src/pyproject.toml` → control-diff 命中；仓库里已有的 `lib/ruff.toml`、`lib/pyproject.toml` 进 strict denyWrite。其余 Python 工具（mypy / flake8 / pylint / black / isort / coverage）不按文件层叠，表不变（`mypy src` 不出现 `**/ruff.toml`）。
- **D1b JS 层叠配置**（决定：flat `eslint.config.*` 也锁 `**/`——ESLint 10 起默认按文件就近查找，v9 也有该开关；拿不准就多锁）：
  | 命令词 | 追加的 glob |
  |---|---|
  | eslint | `**/eslint.config.*` `**/.eslintrc*` `**/.eslintignore` `**/package.json`（旧式 `eslintConfig` 键） |
  | prettier | `**/.prettierrc*` `**/prettier.config.*` `**/.prettierignore` `.editorconfig` `**/.editorconfig` `**/package.json`（`prettier` 键） |
  | stylelint | `**/.stylelintrc*` `**/stylelint.config.*` `**/package.json`（`stylelint` 键） |
  `tsc` / `vue-tsc` / `vite` 不变（不层叠；`extends` / `-p dir` 见 §8）。`**/package.json` 只因这三个工具（或经 `JS_ALL` 保守）出现；T-023 的「无选择器、识别到运行器 → 没有 `**/` glob」与「`d/package.json` 不存在 → 只有 `NPM_ENTRY`」不变。
- **D2 一次性运行器前缀**：`uvx [选项] X`、`uv tool run [选项] X`、`pipx run [选项] X` 与 `uv run` 一样剥前缀、按 X 识别；前缀本身加 `PY_ENTRY`；X 不认识 → `PY_ALL`。取值选项：uvx / uv tool run 的 `--from` `--with` `--with-editable` `--with-requirements` `--python`/`-p` `--index`；pipx 的 `--spec` `--python` `--index-url`。X 带版本时去掉版本：`ruff@0.6.0`、`ruff==0.6.0` → ruff。
- **D3 pre-commit**：命令词 `pre-commit`（任何子命令；也认 `uv run pre-commit`、`uvx pre-commit`、`python -m pre_commit`、package.json script 里的 `pre-commit run`）→ `.pre-commit-config.yaml` `.pre-commit-config.yml` `.pre-commit-hooks.yaml` + `PY_ALL` + `JS_ALL`（钩子能跑任何工具，保守），都相对 `d`；`-c X` / `--config X` / `--config=X` 的字面值锁上。放在 `_rule_entries` 一侧（verify 层、被跟进脚本、package.json script 段都生效）。`echo pre-commit` 不算。
- 对照组不变：`src/App.vue`、`src/components/*.vue`、`src/app.py`、`tests/test_app.py`、lock 文件只改它们 → 不命中，不进 denyWrite。

## 3. 需求对齐与影响分析
| 问题 | 结论 | 来源 |
|---|---|---|
| 放进 0.2.2 | 是，用户的主要技术栈 | 项目文档 R-1-hotfix-scope.md；用户 2026-11-15 决定 R-1 做 0.2.2 热修 |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester — 结果：写了「接口约定」（J 表 / P 表 / 前缀剥离 / lock 文件 / make 不变）与 `pkg/tests/test_lint_configs.sh`（154 项，当前 62 通过 / 92 失败；通过的是精确性、对照组、lock 文件与 make 不变的守卫，以及 T-023 已锁的 vite/vitest/playwright 配置）；`bash -n` 通过；test-harness 344/344，pkg/tests 其余 20 个套件全部 N/N。
- [x] 2. 实现 — 结果：`harness_lib.py` 加 `JS_TOOL_ENTRY`（eslint / prettier / tsc / vue-tsc / vite / stylelint，并入 `JS_ALL`，`_JsScan.tool` 不置 found；`_is_cmd` / `_js_direct` 同用 T-023 命令词逻辑；`--ignore-path` 进 `_JS_CFG_OPTS`）与 `PY_TOOL_ENTRY` / `PY_ALL`（`_rule_entries` 末尾调 `_py_entries`：剥 uv/poetry/pipenv/hatch/pdm run、python -m、coverage run 前缀，pytest/py.test/tox/nox 与前缀后表外命令 → `PY_ALL`，配置路径参数锁字面值）；test_lint_configs 154/154，test-harness 344/344，pkg/tests 其余 20 个套件 N/N；插件 v0.2.2 重建，README 0.2.2 加一行。
- [x] 2b. tester 第 2 轮 — 结果：写「接口约定 v2」（D1 ruff 层叠、D1b eslint/prettier/stylelint 层叠、D2 uvx/uv tool run/pipx run、D3 pre-commit），§8 记 D4–D6（S-004），§9 记需求变更；test_lint_configs.sh 加 v2 一节（共 251 项：v1 154/154 仍过；v2 97 项中 65 失败，32 项是精确性 / 对照组 / lock 文件守卫已过）；`bash -n` 通过；test-harness 344/344，其余 20 套件全部 N/N。
- [x] 2c. 实现第 2 轮 — 结果：`PY_TOOL_ENTRY["ruff"]` 加 `**/ruff.toml` `**/.ruff.toml` `**/pyproject.toml`；`JS_TOOL_ENTRY` 的 eslint / prettier / stylelint 加 `**/` 层叠 glob、`**/package.json`（prettier 另加 `.editorconfig` `**/.editorconfig`），`JS_ALL` / `PY_ALL` 随之扩充，D9 的 `**/` 版本不再叠成 `**/**/`；`_py_prefix` 统一识别 uv run / uvx / uv tool run / pipx run / poetry / pipenv / hatch / pdm run，uvx / pipx 去版本号（`@`、`==` 等）；`pre-commit` / `python -m pre_commit` → `PRE_COMMIT_ENTRY` + `PY_ALL` + `JS_ALL`，锁 `-c` / `--config` 字面值。test_lint_configs 251/251，test-harness 344/344，其余 20 套件 N/N；插件 v0.2.2 重建。
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [x] A1. 文档表里每个「未锁」文件：任务分支只改它 → control-diff 命中，strict denyWrite 有它（Vue 脚手架、pytest+ruff+mypy、uv/make 三组） — 证据：见 §10 verifier 结论
- [x] A2. 对照组：只改源码或测试文件不命中 — 证据：见 §10 verifier 结论
- [x] A3. `uv run` / `poetry run` / `python -m` 前缀剥离后识别 — 证据：见 §10 verifier 结论
- [x] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：见 §10 verifier 结论
- [x] A5. 仅修改了 allowed_paths 内的文件 — 证据：见 §10 verifier 结论**B. 人工验收（→ 人工门）**
- （无；Mac 复测第 5 项覆盖真机）

## 6. Guardrails（本任务特有）
- 宁可多锁；不确定走保守分支（沿用 T-023）。

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
第 1 轮独立审查（ecd883b）确认、不在 0.2.2 修（→ S-004），复现见 `/tmp/t025-review/`：
- D4 `vue-tsc -p <目录>` / `tsc -p <目录>` 指向的目录里的 `tsconfig*.json`，以及 tsconfig `extends` / `references` 指到 glob 之外（跨目录、`node_modules/@vue/tsconfig`）的文件不算入口。
- D5（tester 补记）`cd sub && ruff|prettier|eslint|mypy` 时这些工具也向上查找父目录的配置（同 T-023 §8 D6 mocha），父目录配置不算入口；v1 断言「`cd api && ruff` 不锁根 `ruff.toml`」保留，等 S-004 一起改。
- D6（tester 补记）pre-commit 配置里 `repo: local` 钩子的 `entry:` 指向的仓库脚本不跟进（`scripts/**` 本身已是控制路径）。

- 复验第 2 轮：`**/pyproject.toml` 在用 ruff / pytest / tox / nox 时整体锁定，monorepo 成员的 pyproject 修改需要门卡；收窄到含 `[tool.ruff]` / `[tool.pytest]` 的文件 → S-004。

## 9. 范围变更 / 依赖变更
- 2026-11-16 第 2 轮（独立审查 FAIL 后，协调者转来）：需求在「接口约定 v2」里扩充——D1 ruff 锁 `**/ruff.toml` `**/.ruff.toml` `**/pyproject.toml`；D1b eslint / prettier / stylelint 的层叠配置锁 `**/`（含 `.editorconfig`、`**/package.json`）；D2 `uvx` / `uv tool run` / `pipx run` 剥前缀；D3 `pre-commit` → 其配置 + `PY_ALL` + `JS_ALL`。D4 转 S-004（§8）。allowed_paths 不变。

## 10. Verifier 结论
- 结论：PASS
- 说明：第 2 轮独立复验 PASS（2c55e2d）：R-1-hotfix-scope 三组技术栈 13/13 命中、strict denyWrite 覆盖；子目录 ruff.toml / pyproject.toml、prettier / 旧版 eslint / stylelint 级联配置、uvx / uv tool run / pipx run、pre-commit 全部命中；对照组（源码、测试、lock 文件）不命中；T-023 workspace 覆盖未削弱（旧入口集是新集子集）。全部 21 个 test_*.sh N/N（lint_configs 251/251），test-harness 344/344，verify.sh rc=0；改动在 allowed_paths 内；版本 0.2.2 三处一致；无测试行删除。

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 工具与运行器共用 `_JsScan.cmd` 的命令词识别、只差 found；Python 命令词放 `_rule_entries` 后 verify 层与 script 段同时生效 | 加 `JS_TOOL_ENTRY` / `PY_TOOL_ENTRY` / `PY_ALL`、`_JsScan.tool`、`_py_entries`、`_py_cfg_args` | test_lint_configs 62→154/154，一次通过；其余套件未回退 |
| 2 | 接口约定未明说 `python -m <表外模块>`（如 unittest）算不算「前缀后表外命令」 | 按「不确定走保守」→ `PY_ALL`（另保留 `X.py` `X/**`）；`uv run --project` / `pdm run -p` 新旧目录都锁（`--directory` 只锁新目录）；`coverage run X.py` 锁脚本 + `PY_ALL` | 已有 unittest 断言（存在性）仍过 |
| 3 | v2 的层叠项只是表里追加 `**/` glob（`_glob_files` 已跳过 node_modules）；一次性运行器与 `uv run` 同一套剥前缀循环，只差取值选项表 | 见 §4 2c | test_lint_configs 186→251/251，一次通过；其余套件未回退 |

## 12. 教训

## 13. 对抗审查
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
| 1 | 5 | 5 | 4 修 + 1 转 S-004 | D1 ruff 就近配置（必修）、D1b 级联配置、D2 uvx、D3 pre-commit 修在第 2 轮；D4 vue-tsc -p 目录 / tsconfig extends 转 S-004 |
| 2 | 0 | 0 | - | PASS；记一条可接受的多锁（**/pyproject.toml） |
