import { config } from '../config.js';
import { TelegramClient } from '../telegram/telegram-client.js';
import {
  formatPaperOpenMessage,
  formatPaperCloseMessage,
} from '../telegram/paper-trade-messages.js';
import { loadPaperAccount } from './paper-store.js';
import type { PaperCycleResult } from './types.js';
import { logPush } from '../utils/push-logger.js';
import { formatPaperAccountOnlyMessage } from '../telegram/paper-trade-messages.js';

export async function pushPaperTradeAlerts(
  cycle: PaperCycleResult,
): Promise<void> {
  if (!config.paper.pushTrades || !config.paper.enabled) return;
  if (!config.telegram.enabled) return;

  const client = new TelegramClient();
  if (!client.isReady()) {
    console.warn('[paper-push] Telegram not configured, skip trade alerts');
    return;
  }

  const hasActivity = cycle.opened.length > 0 || cycle.closed.length > 0;
  if (!hasActivity) return;

  for (const pos of cycle.opened) {
    const acc = loadPaperAccount();
    const text = formatPaperOpenMessage(
      pos,
      acc,
      cycle.equity,
      cycle.unrealizedPnl,
    );
    try {
      await client.sendMessage(text);
      console.log(`[paper-push] open alert ${pos.symbol}`);
      logPush({
        time: new Date().toISOString(),
        success: true,
        message_type: 'paper_open',
        message_length: text.length,
        paper_equity: cycle.equity,
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[paper-push] open alert failed:`, msg);
      logPush({
        time: new Date().toISOString(),
        success: false,
        message_type: 'paper_open',
        message_length: text.length,
        error: msg,
      });
    }
  }

  for (const trade of cycle.closed) {
    const acc = loadPaperAccount();
    const text = formatPaperCloseMessage(
      trade,
      acc,
      cycle.equity,
      cycle.unrealizedPnl,
    );
    try {
      await client.sendMessage(text);
      console.log(
        `[paper-push] close alert ${trade.symbol} net=${trade.netPnl.toFixed(2)}`,
      );
      logPush({
        time: new Date().toISOString(),
        success: true,
        message_type: 'paper_close',
        message_length: text.length,
        paper_equity: cycle.equity,
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[paper-push] close alert failed:`, msg);
      logPush({
        time: new Date().toISOString(),
        success: false,
        message_type: 'paper_close',
        message_length: text.length,
        error: msg,
      });
    }
  }
}

/** 每轮扫描推送账户结果（无盘面分析） */
export async function pushPaperAccountStatus(
  cycle: PaperCycleResult,
): Promise<void> {
  if (!config.paper.enabled || !config.paper.pushStatusEveryCycle) return;
  if (!config.telegram.enabled) return;

  const client = new TelegramClient();
  if (!client.isReady()) return;

  const acc = loadPaperAccount();
  const text = formatPaperAccountOnlyMessage(
    acc,
    cycle.equity,
    cycle.unrealizedPnl,
  );

  try {
    await client.sendMessage(text);
    console.log('[paper-push] account status sent');
    logPush({
      time: new Date().toISOString(),
      success: true,
      message_type: 'paper_status',
      message_length: text.length,
      paper_equity: cycle.equity,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('[paper-push] account status failed:', msg);
    logPush({
      time: new Date().toISOString(),
      success: false,
      message_type: 'paper_status',
      message_length: text.length,
      error: msg,
    });
  }
}
