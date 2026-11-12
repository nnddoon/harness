# 交接包 T-000 <标题>

- 分支 / PR：`task/T-000-slug` / <PR 链接或「未开」>
- 最终状态：review | done | blocked
- 完成时间：

## 1. 变更摘要（给下一个人/会话看的 5 行以内）
- 

## 2. 对外契约（下游会依赖的东西）
| 契约 | 位置 | 说明 |
|---|---|---|
| 例：事件 `onRateChange(rate: number)` | `apps/web/src/player/events.ts` | 统计模块订阅，勿改签名 |

## 3. 冻结清单（已追加到 `.harness/locks.txt`）
```
apps/web/src/player/events.ts   # T-000 对外事件契约
```

## 4. 如何验证
```bash
<命令 1>
<命令 2>
```

## 5. 遗留问题 / 技术债
- 

## 6. 给下一个任务的提示
- 下一个建议任务：T-xxx（理由）
- 接手前必读：
- 容易踩的坑：

## 7. 新对话启动块（复制粘贴即可）
```text
cd <worktree 路径>          # 分支：<branch>
claude

> 你在接续 T-xxx。先读：.harness/tasks/T-xxx.md、.harness/handoffs/T-000.md。
> 不许修改：<冻结清单>。完成标准见任务卡第 5 节。
> 读完后用 3 行复述目标、范围、验收，然后 /harness:task-run T-xxx。
```
