import { randomUUID } from 'node:crypto';
import { config } from '../config.js';
import type { MarketReport } from '../services/market-summary-service.js';
import type { StrategySignal } from '../strategy/strategy-engine.js';
import { getTicker24hAll } from '../binance/public-client.js';
import { baseFromSymbol, fmtPrice, pct } from '../utils/format.js';
import { calcTradeFee, feePctLabel } from './fees.js';
import { loadPaperAccount, savePaperAccount } from './paper-store.js';
import { logPaperEvent } from './paper-log.js';
import {
  pushPaperTradeAlerts,
  pushPaperAccountStatus,
} from './paper-trade-push.js';
import type {
  ClosedTrade,
  ExitReason,
  PaperAccount,
  PaperCycleResult,
  PaperPosition,
} from './types.js';

function calcGrossPnl(
  side: 'long' | 'short',
  entry: number,
  exit: number,
  notional: number,
): { grossPnl: number; grossPnlPct: number } {
  const grossPnl =
    side === 'long'
      ? ((exit - entry) / entry) * notional
      : ((entry - exit) / entry) * notional;
  const grossPnlPct = (grossPnl / notional) * 100;
  return { grossPnl, grossPnlPct };
}

function unrealizedNet(pos: PaperPosition, mark: number): number {
  const { grossPnl } = calcGrossPnl(
    pos.side,
    pos.entryPrice,
    mark,
    pos.notional,
  );
  const estCloseFee = calcTradeFee(pos.quantity * mark);
  return grossPnl - pos.openFee - estCloseFee;
}

function shouldClose(
  pos: PaperPosition,
  mark: number,
): { close: boolean; reason?: ExitReason } {
  const sl = pos.stopLoss;
  const tp = pos.takeProfit1;
  if (!Number.isFinite(sl) || !Number.isFinite(tp)) return { close: false };

  if (pos.side === 'long') {
    if (mark <= sl) return { close: true, reason: 'sl' };
    if (mark >= tp) return { close: true, reason: 'tp1' };
  } else {
    if (mark >= sl) return { close: true, reason: 'sl' };
    if (mark <= tp) return { close: true, reason: 'tp1' };
  }
  return { close: false };
}

function marginForTrade(acc: PaperAccount): number {
  return (acc.initialBalance * acc.marginPctPerTrade) / 100;
}

export async function runPaperTradingCycle(
  report: MarketReport,
): Promise<PaperCycleResult | null> {
  if (!config.paper.enabled) return null;

  const acc = loadPaperAccount();
  const priceMap = await buildPriceMap(acc, report);

  const closed: ClosedTrade[] = [];
  const stillOpen: PaperPosition[] = [];

  for (const pos of acc.openPositions) {
    const mark = priceMap.get(pos.symbol);
    if (mark == null) {
      stillOpen.push(pos);
      continue;
    }
    const chk = shouldClose(pos, mark);
    if (chk.close && chk.reason) {
      const trade = closePosition(acc, pos, mark, chk.reason);
      closed.push(trade);
      logPaperEvent({
        action: 'close',
        symbol: pos.symbol,
        reason: chk.reason,
        grossPnl: trade.grossPnl,
        netPnl: trade.netPnl,
        fees: trade.totalFees,
        exitPrice: mark,
      });
    } else {
      stillOpen.push(pos);
    }
  }

  acc.openPositions = stillOpen;

  const opened: PaperPosition[] = [];
  let skippedReason: string | undefined;

  const canOpen =
    report.risks.suggestion !== '暂停开仓' &&
    acc.openPositions.length < acc.maxPositions;

  if (!canOpen) {
    skippedReason =
      report.risks.suggestion === '暂停开仓'
        ? 'risk_pause'
        : 'max_positions';
    if (skippedReason === 'risk_pause') {
      console.warn('[paper] skip new opens: risk pause');
    }
  } else if (config.paper.autoTrade) {
    for (const sig of report.signals) {
      if (acc.openPositions.length >= acc.maxPositions) break;
      if (acc.openPositions.some((p) => p.symbol === sig.symbol)) continue;
      if (sig.score < config.marketPush.signalMinScore) continue;
      if (
        !sig.entryReady &&
        sig.score < config.paper.openMinScore &&
        !config.paper.openOnWatchlist
      ) {
        continue;
      }

      const mark = priceMap.get(sig.symbol) ?? sig.price;
      const pos = tryOpen(acc, sig, mark);
      if (pos) {
        opened.push(pos);
        logPaperEvent({
          action: 'open',
          symbol: pos.symbol,
          side: pos.side,
          strategy: pos.strategyType,
          entry: pos.entryPrice,
          stopLoss: pos.stopLoss,
          takeProfit1: pos.takeProfit1,
          margin: pos.margin,
          openFee: pos.openFee,
        });
      }
    }
  }

  savePaperAccount(acc);

  let unrealizedPnl = 0;
  for (const p of acc.openPositions) {
    const m = priceMap.get(p.symbol) ?? p.entryPrice;
    unrealizedPnl += unrealizedNet(p, m);
  }

  const lockedMargin = acc.openPositions.reduce((s, p) => s + p.margin, 0);
  const equityFull = acc.balance + lockedMargin + unrealizedPnl;

  const cycle: PaperCycleResult = {
    opened,
    closed,
    equity: equityFull,
    unrealizedPnl,
    available: acc.balance,
    skippedReason,
  };

  await pushPaperTradeAlerts(cycle);
  await pushPaperAccountStatus(cycle);

  return cycle;
}

function tryOpen(
  acc: PaperAccount,
  sig: StrategySignal,
  mark: number,
): PaperPosition | null {
  const margin = marginForTrade(acc);
  const notional = margin * acc.leverage;
  const openFee = calcTradeFee(notional);
  const totalCost = margin + openFee;

  if (margin <= 0 || acc.balance < totalCost) return null;

  let stopLoss = sig.stopLoss;
  let takeProfit1 = sig.takeProfit1;
  if (!Number.isFinite(stopLoss)) {
    stopLoss = sig.side === 'long' ? mark * 0.96 : mark * 1.04;
  }
  if (!Number.isFinite(takeProfit1)) {
    takeProfit1 = sig.side === 'long' ? mark * 1.08 : mark * 0.92;
  }
  if (sig.side === 'long' && mark <= stopLoss * 1.002) return null;
  if (sig.side === 'short' && mark >= stopLoss * 0.998) return null;

  const quantity = notional / mark;

  const pos: PaperPosition = {
    id: randomUUID().slice(0, 8),
    symbol: sig.symbol,
    side: sig.side,
    strategyType: sig.strategyType,
    score: sig.score,
    entryPrice: mark,
    margin,
    leverage: acc.leverage,
    notional,
    quantity,
    openFee,
    stopLoss,
    takeProfit1,
    openedAt: new Date().toISOString(),
    watchLevel: sig.watchLevel,
    reason: sig.reasonNotEntered,
  };

  acc.balance -= totalCost;
  acc.openPositions.push(pos);
  return pos;
}

function closePosition(
  acc: PaperAccount,
  pos: PaperPosition,
  exitPrice: number,
  reason: ExitReason,
): ClosedTrade {
  const exitNotional = pos.quantity * exitPrice;
  const closeFee = calcTradeFee(exitNotional);
  const { grossPnl, grossPnlPct } = calcGrossPnl(
    pos.side,
    pos.entryPrice,
    exitPrice,
    pos.notional,
  );
  const totalFees = pos.openFee + closeFee;
  const netPnl = grossPnl - totalFees;
  const netPnlPct = (netPnl / pos.margin) * 100;

  acc.balance += pos.margin + grossPnl - closeFee;

  const trade: ClosedTrade = {
    id: pos.id,
    symbol: pos.symbol,
    side: pos.side,
    strategyType: pos.strategyType,
    score: pos.score,
    entryPrice: pos.entryPrice,
    exitPrice,
    exitReason: reason,
    margin: pos.margin,
    leverage: pos.leverage,
    notional: pos.notional,
    exitNotional,
    openFee: pos.openFee,
    closeFee,
    totalFees,
    grossPnl,
    grossPnlPct,
    netPnl,
    netPnlPct,
    pnl: netPnl,
    pnlPct: netPnlPct,
    stopLoss: pos.stopLoss,
    takeProfit1: pos.takeProfit1,
    openedAt: pos.openedAt,
    closedAt: new Date().toISOString(),
  };

  acc.closedTrades.unshift(trade);
  if (acc.closedTrades.length > 200) {
    acc.closedTrades = acc.closedTrades.slice(0, 200);
  }

  return trade;
}

async function buildPriceMap(
  acc: PaperAccount,
  report: MarketReport,
): Promise<Map<string, number>> {
  const map = new Map<string, number>();
  map.set(report.majors.btc.symbol, report.majors.btc.price);
  map.set(report.majors.eth.symbol, report.majors.eth.price);
  map.set(report.majors.sol.symbol, report.majors.sol.price);

  for (const s of report.signals) map.set(s.symbol, s.price);
  for (const g of report.gainers) map.set(g.symbol, g.price);

  const need = acc.openPositions
    .map((p) => p.symbol)
    .filter((s) => !map.has(s));
  if (need.length) {
    const tickers = await getTicker24hAll();
    for (const t of tickers) {
      if (need.includes(t.symbol)) map.set(t.symbol, t.lastPrice);
    }
  }
  return map;
}

export function formatPaperTelegramSection(
  acc: PaperAccount,
  cycle: PaperCycleResult | null,
): string {
  if (!config.paper.enabled || !cycle) return '';

  const lines: string[] = [];
  lines.push('');
  lines.push('<b>七、模拟合约账户（纸面 1000U 测试）</b>');
  lines.push(
    `本金 ${acc.initialBalance}U | 权益 ${cycle.equity.toFixed(2)}U | 可用 ${cycle.available.toFixed(2)}U | 杠杆 ${acc.leverage}x`,
  );
  lines.push(
    `持仓 ${acc.openPositions.length}/${acc.maxPositions} | 浮盈(扣费) ${cycle.unrealizedPnl >= 0 ? '+' : ''}${cycle.unrealizedPnl.toFixed(2)}U`,
  );
  lines.push(`手续费率 taker ${feePctLabel()}（开+平各扣一次）`);

  const totalNet = acc.closedTrades.reduce(
    (s, t) => s + (t.netPnl ?? t.pnl ?? 0),
    0,
  );
  const totalFees = acc.closedTrades.reduce(
    (s, t) => s + (t.totalFees ?? 0),
    0,
  );
  const wins = acc.closedTrades.filter(
    (t) => (t.netPnl ?? t.pnl) > 0,
  ).length;
  const losses = acc.closedTrades.filter(
    (t) => (t.netPnl ?? t.pnl) <= 0,
  ).length;
  lines.push(
    `累计平仓 ${acc.closedTrades.length} 笔 | 胜 ${wins} 负 ${losses} | 净利 ${totalNet >= 0 ? '+' : ''}${totalNet.toFixed(2)}U | 手续费 ${totalFees.toFixed(2)}U`,
  );

  if (cycle.closed.length) {
    lines.push('<b>本轮平仓</b>');
    for (const t of cycle.closed.slice(0, 5)) {
      const tag =
        t.exitReason === 'tp1'
          ? '止盈'
          : t.exitReason === 'sl'
            ? '止损'
            : t.exitReason;
      const net = t.netPnl ?? t.pnl;
      lines.push(
        `${baseFromSymbol(t.symbol)} ${t.side === 'long' ? '多' : '空'} ${tag} 净利 ${net >= 0 ? '+' : ''}${net.toFixed(2)}U（费 ${(t.totalFees ?? 0).toFixed(2)}U）`,
      );
    }
  }

  if (cycle.opened.length) {
    lines.push('<b>本轮开仓</b>');
    for (const p of cycle.opened) {
      lines.push(
        `${baseFromSymbol(p.symbol)} ${p.side === 'long' ? '多' : '空'} 策略${p.strategyType} @${fmtPrice(p.entryPrice)} SL${fmtPrice(p.stopLoss)} TP${fmtPrice(p.takeProfit1)} 费${p.openFee.toFixed(2)}U`,
      );
    }
  }

  if (acc.openPositions.length) {
    lines.push('<b>当前持仓</b>');
    for (const p of acc.openPositions) {
      lines.push(
        `${baseFromSymbol(p.symbol)} ${p.side === 'long' ? '多' : '空'} 入@${fmtPrice(p.entryPrice)} SL${fmtPrice(p.stopLoss)} TP${fmtPrice(p.takeProfit1)}`,
      );
    }
  } else if (!cycle.opened.length && !cycle.closed.length) {
    lines.push('本轮无开平仓');
  }

  if (cycle.skippedReason === 'risk_pause') {
    lines.push('⚠️ 风控：暂停开新仓');
  }

  lines.push('<i>模拟盘，非 Binance 真实下单</i>');
  return lines.join('\n');
}
