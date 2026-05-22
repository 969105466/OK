# BN — Binance USDT-M 合约

PowerShell 扫描脚本 + **Node/TypeScript 只读盘面推送**（模拟策略，不真实下单）。

## 环境

- Windows + PowerShell 5.1+（脚本）
- Node.js **18+**（Telegram 推送）
- 盘面推送 **仅需 Binance 公开行情**，无需 API Key

## Telegram 盘面推送（TypeScript）

### 1. 创建 Telegram Bot

1. 在 Telegram 搜索 **@BotFather**
2. 发送 `/newbot`，按提示创建机器人
3. 保存返回的 **Bot Token**（形如 `123456:ABC-DEF...`）

### 2. 获取 Chat ID

**推荐（自动）：**

1. 把 `TELEGRAM_BOT_TOKEN` 写入 `.env`（见下方第 3 步）
2. 在 Telegram 里打开你的机器人，点 **Start** 或发一条 `hi`
3. 在项目目录执行：
   ```powershell
   npm run telegram:chat-id
   ```
4. 终端会打印 `TELEGRAM_CHAT_ID=123456789`，复制到 `.env`

**手动：** 浏览器打开 `https://api.telegram.org/bot你的TOKEN/getUpdates`，在 JSON 里找 `message.chat.id`（个人号多为正数，群组为负数）。

### 3. 配置 .env

```powershell
cd D:\code\BN
copy .env.example .env
# 编辑 .env，填入 TELEGRAM_BOT_TOKEN、TELEGRAM_CHAT_ID
npm install
```

`.env` 主要项见 `.env.example`（`TELEGRAM_*`、`MARKET_PUSH_*`）。

### 4. 测试推送

```powershell
npm run push:test
```

成功时 Telegram 收到：**「Telegram 推送测试成功，当前为只读行情模式。」**

### 5. 立即推送一次盘面快报

```powershell
npm run market:push
```

### 6. 启动每 10 分钟自动推送

```powershell
npm run market:watch
```

**Windows 后台常驻：**

```powershell
.\start-market-watch.ps1   # 启动（每 10 分钟：扫描 + 策略信号 + Telegram）
.\stop-market-watch.ps1    # 停止
```

间隔由 `TELEGRAM_PUSH_INTERVAL_MINUTES` 控制（默认 10）。启动后**立即推送一次**，之后按间隔循环。

推送日志：`logs/telegram-push.jsonl`

### 安全说明

| 项 | 说明 |
|----|------|
| Binance | **仅**调用公开 REST（ticker、K 线、OI、资金费率等） |
| API Key | 盘面推送**不需要**；PowerShell 账户检测可选 |
| 下单 | **无任何**真实下单、开仓、平仓接口 |
| Telegram | **仅出站推送**，不接收、不解析交易指令 |

---

## PowerShell：链接账户与扫描

```powershell
copy binance.env.example binance.env
.\test-account.ps1
.\pair-snap.ps1 -Bases BTC,ETH,SOL
.\swing-pick.ps1
```

## 项目结构（Node 部分）

| 路径 | 说明 |
|------|------|
| `src/telegram/telegram-client.ts` | Telegram 发送（POST sendMessage） |
| `src/telegram/message-templates.ts` | HTML 盘面快报模板 |
| `src/services/market-summary-service.ts` | 盘面汇总（公开行情） |
| `src/strategy/strategy-engine.ts` | 模拟策略 A/B/C 评分 |
| `src/jobs/market-push-job.ts` | 定时推送任务 |
| `src/binance/public-client.ts` | **仅公开** Binance API |

## 扫描范围

每轮策略扫描：**24h 涨幅榜前 60** + **跌幅榜前 30**（`.env` 中 `MARKET_PUSH_TOP_GAINERS` / `MARKET_PUSH_TOP_LOSERS`），默认最低成交额 50 万 USDT（`MARKET_MIN_QUOTE_VOLUME`）。

## 模拟合约（1000U 纸面测试）

**不会向 Binance 下真实单。** 每轮 `market:push` / `market:watch` 自动：

- 按策略信号模拟开仓（默认本金 1000U、3x 杠杆、每笔 10% 保证金）
- 记录止损 / 止盈价，价格触发则模拟平仓
- Telegram 快报末尾附带「模拟合约账户」
- 数据：`data/paper-account.json`，流水：`logs/paper-trades.jsonl`

```powershell
npm run paper:status   # 查看持仓与历史
npm run paper:reset    # 重置为 1000U
```

`.env`：`PAPER_TRADING_ENABLED`、`PAPER_INITIAL_BALANCE=1000`、`PAPER_LEVERAGE=3` 等见 `.env.example`。

**Telegram 默认只推开/平仓**（`TELEGRAM_MARKET_REPORT=false`），包含：入场、止盈止损、手续费、本金/权益/盈利、当前持仓、历史平仓。无盘面快报。

```powershell
npm run paper:summary   # 手动推送账户汇总（不发盘面）
```

手续费默认 **taker 0.04%**（`PAPER_TAKER_FEE_RATE=0.0004`）。若要恢复盘面快报：`.env` 设 `TELEGRAM_MARKET_REPORT=true`。

非投资建议。
