/** 手动推送：账户本金、盈利、持仓、历史（无盘面分析） */
import { TelegramClient } from '../telegram/telegram-client.js';
import { formatPaperAccountOnlyMessage } from '../telegram/paper-trade-messages.js';
import { loadPaperAccount } from '../paper/paper-store.js';
import { computeAccountEquity } from '../paper/paper-equity.js';

async function main(): Promise<void> {
  const acc = loadPaperAccount();
  const { equity, unrealizedPnl: unrealized } = await computeAccountEquity(acc);

  const text = formatPaperAccountOnlyMessage(acc, equity, unrealized);
  const client = new TelegramClient();
  if (!client.isReady()) {
    console.warn('Configure TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env');
    process.exitCode = 1;
    return;
  }

  await client.sendMessage(text);
  console.log('Account summary sent to Telegram.');
}

main();
