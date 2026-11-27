## Goal / 目标

<!-- Why this iteration? Which problem or requirement does it address? 为什么做这次迭代，解决什么问题？ -->

Related issue / 关联 issue: #
Requirement / ADR (optional): <!-- e.g. REQ-010, ADR-006 -->

## Changes / 改动

<!-- What changed? Keep it short; list notable design decisions. 改了什么，有哪些关键设计决定？ -->

## Testing / 验证

<!-- Which tests were written first? How else was it verified (real PR run, screenshots)? 先写了哪些测试？还做了哪些验证？ -->

Test-call-site changes (if any) / 对已有测试调用处的调整（如有，逐条列出）:

## Checklist

- [ ] Tests were written before the implementation / 测试先于实现编写
- [ ] `make coverage` passes locally and coverage did not drop / 本地 `make coverage` 通过，覆盖率未下降
- [ ] No existing test was deleted or weakened / 没有删除或削弱已有测试
- [ ] UI changes include screenshots (`make snapshots` or `--snapshot-dir`) / 界面改动附截图
- [ ] User-visible changes are noted in `pm/06-releases/CHANGELOG.md` under `[Unreleased]` / 已更新 CHANGELOG
- [ ] Changes to sandbox flags, subprocess environment, untrusted-input handling or GitHub write paths are called out below / 涉及沙箱参数、子进程环境变量、不可信输入处理或 GitHub 写入的改动已在下方说明
- [ ] No tokens, private repository names, local absolute paths or real session/workspace IDs in code, fixtures, screenshots or docs / 代码、测试数据、截图和文档中没有 token、私有仓库名、本机绝对路径或真实会话/工作区 ID

## Security-relevant changes / 安全相关改动

<!-- "None" if not applicable. 不涉及请填「无」。 -->
