import { loadPaperAccount } from '../paper/paper-store.js';
import { baseFromSymbol, fmtPrice } from '../utils/format.js';
import { feePctLabel } from '../paper/fees.js';
import {
  tradesLast24h,
  sumNetPnl,
  sumFees,
  formatClosedAt,
} from '../paper/paper-history.js';

const acc = loadPaperAccount();
const dayTrades = tradesLast24h(acc.closedTrades);

console.log('=== Paper Futures Account (simulated) ===');
console.log(`Initial: ${acc.initialBalance} USDT`);
console.log(`Cash available: ${acc.balance.toFixed(2)} USDT`);
console.log(`Leverage: ${acc.leverage}x | Margin/trade: ${acc.marginPctPerTrade}%`);
console.log(`Fee: taker ${feePctLabel()} per side`);
console.log(`Open: ${acc.openPositions.length} / ${acc.maxPositions}`);

if (acc.openPositions.length) {
  console.log('\n-- Positions --');
  for (const p of acc.openPositions) {
    console.log(
      `${baseFromSymbol(p.symbol)} ${p.side} strat${p.strategyType} entry=${fmtPrice(p.entryPrice)} SL=${fmtPrice(p.stopLoss)} TP=${fmtPrice(p.takeProfit1)} margin=${p.margin}U`,
    );
  }
}

const dayNet = sumNetPnl(dayTrades);
const dayFees = sumFees(dayTrades);
console.log(
  `\nToday (24h) closed: ${dayTrades.length} | Net: ${dayNet >= 0 ? '+' : ''}${dayNet.toFixed(2)} U | Fees: ${dayFees.toFixed(2)} U`,
);

if (dayTrades.length) {
  console.log('\n-- Closed today (24h) --');
  for (const t of dayTrades) {
    const net = t.netPnl ?? t.pnl;
    console.log(
      `${formatClosedAt(t.closedAt)} ${baseFromSymbol(t.symbol)} ${t.side} ${t.exitReason} net ${net >= 0 ? '+' : ''}${net.toFixed(2)}U`,
    );
  }
} else {
  console.log('\n-- Closed today (24h) -- none');
}

const realizedNet = acc.closedTrades.reduce(
  (s, t) => s + (t.netPnl ?? t.pnl ?? 0),
  0,
);
console.log(
  `\nAll-time closed: ${acc.closedTrades.length} | Net PnL: ${realizedNet >= 0 ? '+' : ''}${realizedNet.toFixed(2)} U`,
);

console.log(`\nData: data/paper-account.json`);
console.log(`Log:  logs/paper-trades.jsonl`);
