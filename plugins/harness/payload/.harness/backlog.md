# Backlog

> 单写者原则：只有「控制塔」对话（主仓库根目录的会话）或 `scripts/` 修改本文件；worktree 里的执行对话只改自己的任务卡。
>
> 行格式（脚本会解析，请保持）：
> `- T-xxx | <status> | <priority> | <标题> | deps: <T-a,T-b 或 ->| auto_ok: <yes|no> | owner: <会话/人 或 ->`
>
> status：proposed | ready | claimed | in_progress | waiting_human | blocked | review | done

## 人工任务（按优先级）
- T-001 | proposed | P1 | 示例：播放器倍速切换 | deps: - | auto_ok: no | owner: -

## AI 提议区（/backlog-groom 写入，需批准；auto_ok: yes 的可自动转 ready）

## 已完成
