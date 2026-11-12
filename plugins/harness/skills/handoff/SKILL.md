---
name: handoff
description: 在任务中途需要换对话（上下文太重、卡住、换人、换机器）时，把当前进展写进任务卡并生成可直接粘贴的新对话启动块。用户说「交接」「换个对话继续」「上下文太长了」时使用。
argument-hint: <任务号；省略则从分支推断>
---

# /harness:handoff：中途交接

任务：$ARGUMENTS

1. 提交或 stash 当前改动（优先提交，信息 `T-xxx: wip <内容>`）。
2. 更新任务卡第 7 节「当前进展」：做到哪一步、下一步具体做什么（精确到文件/函数）、卡住的点和已排除的方案、需要注意的临时状态（本地服务、mock、测试数据）。
3. 修改过程里已完成的步骤确认都勾选并有证据。
4. 输出启动块（用户直接粘贴到新对话）：

```text
cd <当前 worktree 绝对路径>     # 分支 <branch>
claude

> 接续 T-xxx（中途交接）。先读 .harness/tasks/T-xxx-*.md 第 4、5、7 节和 context_files。
> 不要修改：<locked_paths + locks.txt 相关条目>。
> 读完用 3 行复述：目标、做到哪、下一步。然后 /harness:task-run T-xxx。
```

5. 提示用户：旧对话可以关闭；如果新对话在同一目录，也可以直接在本对话 `/clear` 后粘贴上面 `>` 后的内容。
