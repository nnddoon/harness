"""harness launch：经启动器启动 Claude。

  harness launch [--strict] [--role task|plan] [--task T-xxx] [--root DIR] [--print-settings] -- <claude 参数…>

--strict（或环境 HARNESS_UNATTENDED=1）：Claude Code 沙箱必须可用；生成仓库外的 strict 配置并用 --settings 传入；
凭证从环境里清掉。不加时原样启动 claude（D-006：交互会话默认 standard）。
逻辑在 harness_lib.py，这里只是入口；优先用插件自带的库，不用仓库里的副本。
"""
import importlib.util
import sys
from pathlib import Path


def _lib(pkg: Path):
    for d in (pkg / ".claude" / "hooks", pkg / "hooks"):
        p = d / "harness_lib.py"
        if p.exists():
            spec = importlib.util.spec_from_file_location("harness_lib_launch", p)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise SystemExit("找不到 harness_lib.py：插件安装不完整？")


def main(argv: list, pkg_root: str) -> int:
    sys.dont_write_bytecode = True
    return int(_lib(Path(pkg_root)).cmd_launch(list(argv)) or 0)
