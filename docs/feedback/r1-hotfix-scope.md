# 0.2.2 热修范围参考：R-1 验证入口的覆盖范围（存档自项目文档 claude/R-1-hotfix-scope.md）

> 2026-11-15，在 main @ `1fafe7c`（v0.2.1）上实测。用户的项目以 **Python 和 Vue** 为主，所以这两种技术栈优先。
> 判断标准：只要 `.harness/verify.sh` 里有一条命令会读某个文件，而改这个文件能让这条命令变宽松、直接通过，这个文件就算验证入口，要进控制路径（control-diff 和 strict 的 denyWrite）。

## 实测：典型项目在 v0.2.1 下哪些锁了、哪些没锁

| 项目 | verify.sh | 已锁 | **未锁** |
|---|---|---|---|
| Vue（create-vue 脚手架） | `npm run lint` / `type-check` / `test:unit -- --run` / `build` | `package.json` | `vite.config.ts`、`vitest.config.ts`、`playwright.config.ts`、`tsconfig.json`、`tsconfig.app.json`、`tsconfig.vitest.json`、`eslint.config.js`、`.prettierrc.json` |
| Python（pytest + ruff + mypy） | `ruff check .` / `mypy src` / `pytest -q` | `pyproject.toml`、`conftest.py`、`tests/conftest.py`、`pytest.ini`、`setup.cfg`、`tox.ini` | `mypy.ini`、`ruff.toml`、`.flake8`、`.coveragerc` |
| Python（uv / make） | `uv run pytest -q` / `make lint` | `pyproject.toml`、`Makefile` | `ruff.toml`、`uv.lock` |

另外，任务分支只改 `jest.config.js` 时，control-diff 不会命中（R-1 的原始复现，见 `s003-review-r1.md`）。

## 建议的修法
1. **npm 要再追一层**：读 `package.json` 里对应的 scripts，按工具加配置文件：vitest（`vitest.config.*`、`vitest.workspace.*`、`vite.config.*`）、vite（`vite.config.*`）、jest（`jest.config.*`）、playwright（`playwright.config.*`）、cypress（`cypress.config.*`）、mocha（`.mocharc*`）、eslint（`eslint.config.*`、`.eslintrc*`、`.eslintignore`）、prettier（`.prettierrc*`、`prettier.config.*`、`.prettierignore`）、vue-tsc / tsc（`tsconfig*.json`）、nyc / c8（`.nycrc*`、`.c8rc*`）、babel（`babel.config.*`、`.babelrc*`）。scripts 里 `node <路径>` / `bash <路径>` 调用的仓库文件一并锁上。
2. **Python 补上 lint 和类型检查的配置**：ruff → `ruff.toml`、`.ruff.toml`；mypy → `mypy.ini`、`.mypy.ini`；flake8 → `.flake8`；覆盖率 → `.coveragerc`。`uv run X`、`poetry run X`、`python -m X` 先剥前缀再按 X 识别。
3. **lock 文件**（`uv.lock`、`poetry.lock`、`package-lock.json`、`pnpm-lock.yaml`）属于依赖变更，不算验证入口，由依赖门管。
4. **兜底**：verify.sh 里出现推导不了的命令时，`doctor` 列出来（沿用 `UNKNOWN_RUNNERS`）。

## 验收建议
- 上表每个「未锁」文件：任务分支只改它 → control-diff 命中，strict 的 denyWrite 里有它。每种技术栈各写一组测试。
- 对照组：只改源码或测试文件，control-diff 不命中。
- 回归：R-1 复现脚本在 0.2.2 上 `jest.config.js` 一行应输出命中。
