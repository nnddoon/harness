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
- T-007 | ready | P1 | 插件一行安装：marketplace + /harness:setup + init --plugin | deps: T-005 | auto_ok: no | owner: -

## AI 提议区（/backlog-groom 写入，需批准；auto_ok: yes 的可自动转 ready）

## 已完成
