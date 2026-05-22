import { config } from '../config.js';
import { calcTradeFee } from './fees.js';
import type { PaperAccount } from './types.js';
import { getTicker24hAll } from '../binance/public-client.js';

export function calcGrossPnl(
  side: 'long' | 'short',
  entry: number,
  exit: number,
  notional: number,
): { grossPnl: number; grossPnlPct: number } {
  const grossPnl =
    side === 'long'
      ? ((exit - entry) / entry) * notional
      : ((entry - exit) / entry) * notional;
  return { grossPnl, grossPnlPct: (grossPnl / notional) * 100 };
}

export async function computeAccountEquity(
  acc: PaperAccount,
): Promise<{ equity: number; unrealizedPnl: number }> {
  const tickers = await getTicker24hAll();
  const priceMap = new Map(tickers.map((t) => [t.symbol, t.lastPrice]));

  let unrealizedPnl = 0;
  for (const p of acc.openPositions) {
    const mark = priceMap.get(p.symbol) ?? p.entryPrice;
    const { grossPnl } = calcGrossPnl(
      p.side,
      p.entryPrice,
      mark,
      p.notional,
    );
    unrealizedPnl += grossPnl - p.openFee - calcTradeFee(p.quantity * mark);
  }

  const locked = acc.openPositions.reduce((s, p) => s + p.margin, 0);
  return {
    equity: acc.balance + locked + unrealizedPnl,
    unrealizedPnl,
  };
}
