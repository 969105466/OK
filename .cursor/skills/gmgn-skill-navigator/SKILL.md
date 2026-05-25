---
name: gmgn-skill-navigator
description: >-
  Searches gmgn.ai/ai Meme/on-chain skill catalog (skills_zh-CN.json in this repo),
  recommends matching skills, and installs only after user confirmation. Use when the user
  needs on-chain trading, token lookup, market data, wallet analysis, smart money,
  KOL signals, token launch, GMGN skills, or asks to find/install a crypto agent skill.
---

# GMGN 技能导航

[gmgn.ai/ai](https://gmgn.ai/ai) 是链上 Meme 币交易 AI 技能导航站，收录 40+ 可信技能。

**本仓库数据与脚本（优先使用本地，勿依赖 ~/.cursor/skills）：**

| 文件 | 说明 |
|------|------|
| `D:\code\gmgn\skills_zh-CN.json` | 技能索引（主人已保存） |
| `D:\code\gmgn\scripts\search-skills.ps1` | 本地搜索脚本 |

## 核心原则

1. **先搜后装**：先在本仓库搜索并推荐，**经主人确认后再安装**。
2. **按需安装**：不要一次性安装所有技能。
3. **禁止擅自交易**：涉及 swap、私钥、下单时，须主人明确指令才执行写操作。

## JSON 结构

根对象含 `skills` 数组；每条为：

- 顶层：`id`、`slug`、`url`、`category`、`source`
- 嵌套 `skills`：`title`、`subtitle`、`installation`、`capabilities`、`prompts`

另有 `categories` 用于分类中文名映射。

## 搜索

```powershell
cd D:\code\gmgn

# 列出分类
.\scripts\search-skills.ps1 -ListCategories

# 关键词搜索
.\scripts\search-skills.ps1 -Query "聪明钱"
.\scripts\search-skills.ps1 -Query "代币" -Top 5

# 在线更新索引（403 时可浏览器另存为 skills_zh-CN.json）
.\scripts\search-skills.ps1 -Refresh
```

匹配字段：`title`、`subtitle`、`category`、`slug`、`source`、`capabilities`。

## 安装（主人确认后）

1. 打开选中技能的 `url`，获取 `SKILL.md`。
2. 按 `installation` 与 SKILL.md 执行（如 `npx skills add GMGNAI/gmgn-skills`、配置 `~/.config/gmgn/.env`）。
3. 安装到 `~/.cursor/skills/<skill-name>/`，**不要**写入 `~/.cursor/skills-cursor/`。

## 推荐回复模板

```markdown
## 技能推荐（GMGN 导航）

根据「{需求}」检索到：

### 1. {title} (`{slug}`)
- **分类**：{category}
- **能力**：{capabilities}
- **说明**：{subtitle}
- **详情**：{url}

请确认要安装哪一个。确认后我再按 installation / SKILL.md 完成安装。
```

## 分类速查

| 意图 | 关键词 |
|------|--------|
| 链上交易 | swap、限价、止盈止损、市价 |
| 代币查询 | token、安全、持有人、池子 |
| 市场行情 | market、K线、热门 |
| 钱包分析 | portfolio、盈亏 |
| 聪明钱 / KOL | track、KOL、跟单 |
| 发币 | cooking、发币、pump |
