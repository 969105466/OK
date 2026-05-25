# GMGN 技能导航（本地）

链上 Meme / 交易相关 Agent 技能的本地索引与搜索工具。

## 文件

- `skills_zh-CN.json` — 来自 [gmgn.ai](https://gmgn.ai/static/opstatic/skills_zh-CN.json) 的技能列表
- `scripts/search-skills.ps1` — 按关键词搜索技能
- `.cursor/skills/gmgn-skill-navigator/SKILL.md` — Cursor Agent 使用说明

## 用法

```powershell
cd D:\code\gmgn
.\scripts\search-skills.ps1 -ListCategories
.\scripts\search-skills.ps1 -Query "限价买入"
```

更新索引：浏览器下载 JSON 覆盖 `skills_zh-CN.json`，或 `.\scripts\search-skills.ps1 -Refresh`（需能访问 gmgn.ai）。
