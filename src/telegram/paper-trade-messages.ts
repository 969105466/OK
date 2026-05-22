import type { PaperPosition, ClosedTrade, PaperAccount } from '../paper/types.js';
import { baseFromSymbol, fmtPrice, pct, nowLocal } from '../utils/format.js';
import { feePctLabel } from '../paper/fees.js';
import {
  tradesLast24h,
  sumNetPnl,
  sumFees,
  formatClosedAt,
} from '../paper/paper-history.js';

function sideLabel(side: 'long' | 'short'): string {
  return side === 'long' ? '做多' : '做空';
}

function exitLabel(reason: ClosedTrade['exitReason']): string {
  if (reason === 'tp1') return '止盈';
  if (reason === 'sl') return '止损';
  return reason;
}

function accountStats(
  acc: PaperAccount,
  equity: number,
  unrealizedPnl: number,
): string[] {
  const dayTrades = tradesLast24h(acc.closedTrades);
  const dayNet = sumNetPnl(dayTrades);
  const dayFees = sumFees(dayTrades);
  const dayWins = dayTrades.filter((t) => (t.netPnl ?? t.pnl) > 0).length;
  const dayLosses = dayTrades.filter((t) => (t.netPnl ?? t.pnl) <= 0).length;

  const netRealized = acc.closedTrades.reduce(
    (s, t) => s + (t.netPnl ?? t.pnl ?? 0),
    0,
  );
  const totalFees = acc.closedTrades.reduce(
    (s, t) => s + (t.totalFees ?? 0),
    0,
  );
  const totalPnl = equity - acc.initialBalance;

  return [
    '<b>账户</b>',
    `本金：${acc.initialBalance.toFixed(2)}U`,
    `权益：${equity.toFixed(2)}U | 可用：${acc.balance.toFixed(2)}U`,
    `总盈亏：${totalPnl >= 0 ? '+' : ''}${totalPnl.toFixed(2)}U（含浮盈 ${unrealizedPnl >= 0 ? '+' : ''}${unrealizedPnl.toFixed(2)}U）`,
    `今日已实现：${dayNet >= 0 ? '+' : ''}${dayNet.toFixed(2)}U（${dayTrades.length} 笔，胜${dayWins}/负${dayLosses}，费 ${dayFees.toFixed(2)}U）`,
    `累计已实现：${netRealized >= 0 ? '+' : ''}${netRealized.toFixed(2)}U | 累计手续费：${totalFees.toFixed(2)}U`,
  ];
}

function formatOpenPositions(acc: PaperAccount): string[] {
  if (!acc.openPositions.length) return ['当前持仓：无'];
  const lines = ['<b>当前持仓</b>'];
  for (const p of acc.openPositions) {
    lines.push(
      `· ${baseFromSymbol(p.symbol)} ${sideLabel(p.side)} 入@${fmtPrice(p.entryPrice)} SL${fmtPrice(p.stopLoss)} TP${fmtPrice(p.takeProfit1)}`,
    );
  }
  return lines;
}

/** 仅展示 24 小时内平仓 */
function formatTradeHistory24h(acc: PaperAccount): string[] {
  const dayTrades = tradesLast24h(acc.closedTrades);
  if (!dayTrades.length) {
    return ['<b>今日平仓（24小时内）</b>', '暂无'];
  }

  const dayNet = sumNetPnl(dayTrades);
  const lines = [
    `<b>今日平仓（24小时内 ${dayTrades.length} 笔，合计 ${dayNet >= 0 ? '+' : ''}${dayNet.toFixed(2)}U）</b>`,
  ];

  for (const t of dayTrades) {
    const net = t.netPnl ?? t.pnl;
    const tag = exitLabel(t.exitReason);
    lines.push(
      `· ${formatClosedAt(t.closedAt)} ${baseFromSymbol(t.symbol)} ${sideLabel(t.side)} ${tag} 入${fmtPrice(t.entryPrice)}→${fmtPrice(t.exitPrice)} 净利 ${net >= 0 ? '+' : ''}${net.toFixed(2)}U`,
    );
  }
  return lines;
}

export function formatPaperOpenMessage(
  pos: PaperPosition,
  acc: PaperAccount,
  equity: number,
  unrealizedPnl: number,
): string {
  const base = baseFromSymbol(pos.symbol);
  const lines = [
    '<b>🟢 模拟开仓</b>',
    `时间：${nowLocal()}`,
    `币种：<b>${base}</b> ${sideLabel(pos.side)}`,
    `策略 ${pos.strategyType} | 评分 ${pos.score}`,
    `入场：${fmtPrice(pos.entryPrice)}`,
    `保证金：${pos.margin.toFixed(2)}U | ${pos.leverage}x | 名义 ${pos.notional.toFixed(2)}U`,
    `止损：${fmtPrice(pos.stopLoss)} | 止盈：${fmtPrice(pos.takeProfit1)}`,
    `开仓手续费：${pos.openFee.toFixed(4)}U（${feePctLabel()}）`,
    '',
    ...accountStats(acc, equity, unrealizedPnl),
    '',
    ...formatOpenPositions(acc),
    '',
    ...formatTradeHistory24h(acc),
    '',
    '<i>纸面模拟，非真实下单</i>',
  ];
  return lines.join('\n');
}

export function formatPaperCloseMessage(
  trade: ClosedTrade,
  acc: PaperAccount,
  equity: number,
  unrealizedPnl: number,
): string {
  const base = baseFromSymbol(trade.symbol);
  const emoji = trade.netPnl >= 0 ? '🟢' : '🔴';
  const lines = [
    `<b>${emoji} 模拟平仓 · ${exitLabel(trade.exitReason)}</b>`,
    `时间：${nowLocal()}`,
    `币种：<b>${base}</b> ${sideLabel(trade.side)}`,
    `入场 ${fmtPrice(trade.entryPrice)} → 出场 ${fmtPrice(trade.exitPrice)}`,
    `毛利：${trade.grossPnl >= 0 ? '+' : ''}${trade.grossPnl.toFixed(2)}U`,
    `手续费：${trade.totalFees.toFixed(4)}U（开 ${trade.openFee.toFixed(4)} + 平 ${trade.closeFee.toFixed(4)}）`,
    `净利：<b>${trade.netPnl >= 0 ? '+' : ''}${trade.netPnl.toFixed(2)}U</b>（${pct(trade.netPnlPct)}）`,
    '',
    ...accountStats(acc, equity, unrealizedPnl),
    '',
    ...formatOpenPositions(acc),
    '',
    ...formatTradeHistory24h(acc),
    '',
    '<i>纸面模拟，非真实下单</i>',
  ];
  return lines.join('\n');
}

/** 仅账户 + 持仓 + 24h 平仓历史 */
export function formatPaperAccountOnlyMessage(
  acc: PaperAccount,
  equity: number,
  unrealizedPnl: number,
): string {
  return [
    '<b>📋 模拟合约账户</b>',
    `时间：${nowLocal()}`,
    '',
    ...accountStats(acc, equity, unrealizedPnl),
    '',
    ...formatOpenPositions(acc),
    '',
    ...formatTradeHistory24h(acc),
    '',
    '<i>纸面模拟，非真实下单</i>',
  ].join('\n');
}
