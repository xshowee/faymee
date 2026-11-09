## 提交规范

遵循 Angular Commit 规范：

```
<type>(<scope>): <summary>

<body>

<footer>
```

- **type**（必填）：`feat`、`fix`、`docs`、`style`、`refactor`、`perf`、`test`、`build`、`ci`、`chore`、`revert`
- **scope**（可选）：受影响的模块或区域
- **summary**（必填）：中文，50 字以内，结尾不加句号
- **body**（除 `docs` 类型外必填）：说明改了什么、为什么改，每行不超过 100 字符
- **footer**（可选）：
  - 破坏性变更：`BREAKING CHANGE: <简短说明>`，空一行后写详细描述和迁移方法
  - 废弃：`DEPRECATED: <简短说明>`，空一行后写详细描述和推荐的替代用法
