# Ai 每日复盘在线看板

线上地址：<https://michaelmao0511.github.io/ai-daily-review-dashboard/>

`publish-dashboard.ps1` 读取本机 `ai-daily-review` skill 生成的静态 HTML，提交发生变化的看板，并验证 GitHub Pages 已显示相同的最新交易日。

手动发布：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\codex\网站迁移线上\publish-dashboard.ps1"
```
