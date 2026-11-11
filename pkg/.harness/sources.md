# 原始数据来源（/backlog-groom 会按这里去读，而不是只看代码）
# 每行一个来源：类型 | 位置或命令 | 说明。没有就留空，groom 只看代码和交接包。
# 例：
# 日志     | logs/app-*.log                          | 服务端错误日志，找高频报错
# Issue    | gh issue list --label bug --state open  | 用户回报的问题
# 崩溃     | crash-reports/                           | 客户端崩溃
# 反馈     | docs/feedback/*.md                        | 用户访谈、客服记录
