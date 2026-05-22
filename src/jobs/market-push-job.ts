import { config } from '../config.js';
import { MarketSummaryService } from '../services/market-summary-service.js';
import { formatMarketReportHtml } from '../telegram/message-templates.js';
import { TelegramClient } from '../telegram/telegram-client.js';
import { runPaperTradingCycle } from '../paper/paper-trader.js';
import { logPush } from '../utils/push-logger.js';
import { baseFromSymbol } from '../utils/format.js';

let intervalHandle: ReturnType<typeof setInterval> | null = null;
let running = false;

export async function runMarketPushOnce(): Promise<void> {
  if (running) {
    console.warn('[market-push] previous run still in progress, skip');
    return;
  }
  running = true;
  const started = Date.now();

  try {
    console.log('[market-push] scan + paper trading (no market report by default)...');
    const report = await new MarketSummaryService().buildReport();
    const paperCycle = await runPaperTradingCycle(report);

    let success = false;
    let error: string | undefined;
    let messageLength = 0;

    if (config.telegram.marketReport && config.telegram.enabled) {
      const text = formatMarketReportHtml(report);
      messageLength = text.length;
      const telegram = new TelegramClient();
      if (telegram.isReady()) {
        try {
          await telegram.sendMessage(text);
          success = true;
          console.log('[market-push] market report sent to Telegram');
        } catch (e) {
          error = e instanceof Error ? e.message : String(e);
          console.error('[market-push] market report error:', error);
        }
      }
    } else {
      success = true;
      const opened = paperCycle?.opened.length ?? 0;
      const closed = paperCycle?.closed.length ?? 0;
      if (opened || closed) {
        console.log(`[market-push] trades: opened=${opened} closed=${closed}`);
      } else {
        console.log('[market-push] no new trades; account status pushed if enabled');
      }
    }

    logPush({
      time: new Date().toISOString(),
      success,
      message_type: config.telegram.marketReport ? 'market_report' : 'paper_cycle',
      message_length: messageLength,
      error,
      market_sentiment: report.overview.sentiment,
      signal_count: report.signals.length,
      top_gainers: report.gainers.slice(0, 5).map((g) => g.base),
      top_oi_symbols: report.oiAbnormal
        .slice(0, 5)
        .map((o) => baseFromSymbol(o.symbol)),
      paper_opened: paperCycle?.opened.length ?? 0,
      paper_closed: paperCycle?.closed.length ?? 0,
      paper_equity: paperCycle?.equity,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('[market-push] failed:', msg);
    logPush({
      time: new Date().toISOString(),
      success: false,
      message_type: 'paper_cycle',
      message_length: 0,
      error: msg,
    });
  } finally {
    running = false;
    console.log(`[market-push] done in ${Date.now() - started}ms`);
  }
}

export function startMarketWatch(): void {
  if (!config.marketPush.enabled) {
    console.warn('[market-push] MARKET_PUSH_ENABLED=false，不启动定时任务');
    return;
  }

  const minutes = config.telegram.pushIntervalMinutes;
  const ms = minutes * 60 * 1000;

  console.log(
    `[market-push] watch started — scan every ${minutes} min, Telegram: trades only (no market report)`,
  );

  void runMarketPushOnce();

  if (intervalHandle) clearInterval(intervalHandle);
  intervalHandle = setInterval(() => {
    void runMarketPushOnce();
  }, ms);
}

export function stopMarketWatch(): void {
  if (intervalHandle) {
    clearInterval(intervalHandle);
    intervalHandle = null;
  }
}
