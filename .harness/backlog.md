# Backlog

> 单写者原则：只有「控制塔」对话（主仓库根目录的会话）或 `scripts/` 修改本文件；worktree 里的执行对话只改自己的任务卡。
>
> 行格式（脚本会解析，请保持）：
> `- T-xxx | <status> | <priority> | <标题> | deps: <T-a,T-b 或 ->| auto_ok: <yes|no> | owner: <会话/人 或 ->`
>
> status：proposed | ready | claimed | in_progress | waiting_human | blocked | review | done

## 人工任务（按优先级）
- T-001 | done | P1 | harness init：识别技术栈并生成配置 | deps: - | auto_ok: no | owner: root@vm
- T-002 | done | P1 | harness serve：只读看板三屏 | deps: - | auto_ok: no | owner: root@vm
- T-006 | done | P1 | 三个指标自动计算 | deps: - | auto_ok: no | owner: root@vm
- T-003 | done | P1 | 在看板上答复门卡 | deps: T-002 | auto_ok: no | owner: root@vm
- T-004 | done | P1 | 需求页：每句需求的状态与证据 | deps: T-002 | auto_ok: no | owner: root@vm
- T-005 | done | P2 | 打包成 Claude Code 插件 | deps: T-001 | auto_ok: no | owner: root@vm
- T-007 | done | P1 | 插件一行安装：marketplace + /harness:setup + init --plugin | deps: T-005 | auto_ok: no | owner: root@vm
- T-008 | ready | P0 | 统一启动器与 strict 配置 | deps: - | auto_ok: no | owner: -
- T-009 | ready | P0 | 控制路径守门与沙箱内验证 | deps: T-008 | auto_ok: no | owner: -
- T-010 | ready | P0 | 答案库与门卡语义 | deps: T-008 | auto_ok: no | owner: -
- T-011 | ready | P1 | 发布与推送移到控制面 | deps: T-009,T-010 | auto_ok: no | owner: -
- T-012 | ready | P2 | 审计日志与审计页 | deps: T-008,T-010 | auto_ok: no | owner: -
- T-013 | ready | P2 | doctor / down / 定时任务到期 | deps: T-008 | auto_ok: no | owner: -
- T-014 | ready | P2 | 分支保护向导 | deps: T-009 | auto_ok: no | owner: -
- T-015 | ready | P2 | 对话内选项卡 | deps: T-010 | auto_ok: no | owner: -
- T-016 | ready | P2 | Telegram 收件箱 | deps: T-010,T-013 | auto_ok: no | owner: -
- T-017 | ready | P3 | 文档、教程与打包 | deps: T-011,T-015,T-016 | auto_ok: no | owner: -

## AI 提议区（/backlog-groom 写入，需批准；auto_ok: yes 的可自动转 ready）
- 提议：带任务卡的灰区动作审查（S-002 非目标）。触发条件：第 3 批后 standard 模式每天弹窗 > 5 次。

## 已完成
