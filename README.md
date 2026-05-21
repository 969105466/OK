# OK — OKX 小币合约扫描 + 模拟盘

15m 主信号、5m 辅助确认与模拟平仓，Telegram 推送。

## 环境

- PowerShell 7+（macOS 可用 `~/.local/powershell/pwsh`）
- [Telegram Bot](https://core.telegram.org/bots) Token 与 Chat ID

## 配置

```bash
cp telegram.env.example telegram.env
# 编辑 telegram.env：TELEGRAM_BOT_TOKEN、TELEGRAM_CHAT_ID
```

## 拉盘扫描（每 10 分钟）

```bash
./pump-scanner.ps1 -Once           # 测一轮
./start-pump-scanner.sh            # macOS/Linux 后台
./stop-pump-scanner.sh             # 停止
```

Windows 也可用 `.\start-pump-scanner.ps1` / `.\stop-pump-scanner.ps1`。

## 复盘

```bash
./pump-review.ps1                  # 累计复盘并推送 Telegram
./pump-review.ps1 -Days 1          # 仅今日
```

扫描器默认每 **6 小时** 自动复盘（参数 `-ReviewEveryHours 0` 可关闭）。

## 模拟盘（1000 USDT）

```bash
./reset-trading.ps1                # 清空信号历史 + 模拟盘重置
./pump-paper.ps1 -Report           # 查看/推送账户
./pump-scanner.ps1 -Once           # 扫描并自动模拟开平仓
```

本地测试（mock 5m K 线，不调 OKX）：

```bash
./test-paper.ps1 -Case LongTp      # 多单止盈
./test-paper.ps1 -Case LongSl      # 多单止损
./test-paper.ps1 -Case ShortTp     # 空单止盈
./test-paper.ps1 -Case ShortSl     # 空单止损
./test-paper.ps1 -Case Both        # 同根 5m 双触发 → 止损
./test-paper.ps1 -Case FailKeep    # 5m 失败保留持仓
./test-5m-filter.ps1               # 空单 5m 确认过滤
```

规则：本金 1000 U；**3x** 杠杆；单笔风险约 **2%** 净值；手续费 **0.05%**/边；滑点 **0.08%**；开仓盈亏比 ≥ **1.35**；最多 **5** 仓。

## 核心文件

| 文件 | 说明 |
|------|------|
| `pump-scanner.ps1` | 主扫描器（15m 信号 + 5m 过滤） |
| `pump-5m.ps1` | 5m K 线与辅助评分 |
| `pump-paper.ps1` | 模拟盘（5m 止盈止损） |
| `pump-history.ps1` | 信号历史与触发跟踪 |
| `pump-review.ps1` | 复盘推送 |
| `pump-i18n.json` / `pump-review-i18n.json` | 文案 |
| `hype-telegram.ps1` | Telegram 发送 |
| `start-pump-scanner.sh` / `stop-pump-scanner.sh` | 启停（macOS/Linux） |

## 策略要点（v2）

- **15m 主信号**：多空条件、盈亏比、评分门槛不变。
- **5m 辅助**：过滤追多/假摔空；模拟盘用 5m 已收盘 K 线判断 TP/SL。
- 同币止损后 **8h** 冷却；不接实盘。

非投资建议。
