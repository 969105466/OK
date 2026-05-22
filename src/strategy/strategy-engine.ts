/**
 * Paper-only strategy engine — scores observation signals (no orders).
 * Strategy A: swing low-mid + room to run (long)
 * Strategy B: momentum breakout near 15m high (long)
 * Strategy C: oversold bounce / mean reversion (long) or weak breakdown (short)
 */

import type { Kline, PremiumIndex } from '../binance/public-client.js';

export type StrategyType = 'A' | 'B' | 'C';
export type Side = 'long' | 'short';

export interface StrategyInput {
  symbol: string;
  lastPrice: number;
  change24h: number;
  quoteVolume: number;
  daily: Kline[];
  h4: Kline[];
  m15: Kline[];
  funding?: PremiumIndex;
}

export interface StrategySignal {
  symbol: string;
  side: Side;
  strategyType: StrategyType;
  score: number;
  price: number;
  entryReady: boolean;
  watchLevel: number;
  stopLoss: number;
  takeProfit1: number;
  reasonNotEntered: string;
  tags: string[];
}

function rsi(closes: number[], period = 14): number {
  if (closes.length < period + 2) return 50;
  const slice = closes.slice(-(period + 30));
  let g = 0;
  let l = 0;
  for (let i = slice.length - period; i < slice.length; i++) {
    const d = slice[i] - slice[i - 1];
    if (d >= 0) g += d;
    else l -= d;
  }
  if (l === 0) return 100;
  return 100 - 100 / (1 + g / period / (l / period));
}

function toDisplayScore(internal: number): number {
  return Math.min(100, Math.max(0, Math.round(internal * 4.2 + 25)));
}

function evalSwingA(input: StrategyInput): StrategySignal | null {
  const { daily: d, lastPrice: last, change24h: chg24 } = input;
  if (d.length < 25) return null;

  const dCl = d.map((k) => k.close);
  const dLo = d.map((k) => k.low);
  const dHi = d.map((k) => k.high);
  const ma7 = avg(dCl.slice(-7));
  const ma20 = avg(dCl.slice(-20));
  const low20 = Math.min(...dLo.slice(-20));
  const high20 = Math.max(...dHi.slice(-20));
  const pos20 = ((last - low20) / (high20 - low20)) * 100;
  const roomH20 = ((high20 - last) / last) * 100;
  const rsiVal = rsi(dCl);

  let internal = 0;
  const tags: string[] = [];
  if (pos20 >= 15 && pos20 <= 45) {
    internal += 5;
    tags.push('low-mid');
  }
  if (roomH20 >= 12) {
    internal += 4;
    tags.push('room-up');
  }
  if (rsiVal >= 35 && rsiVal <= 55) {
    internal += 3;
    tags.push('rsi-ok');
  }
  if (last > ma7) {
    internal += 3;
    tags.push('above-ma7');
  }
  if (chg24 >= -8 && chg24 <= 8) internal += 2;
  if (chg24 > 25) internal -= 5;

  if (internal < 12) return null;

  const score = toDisplayScore(internal);
  const entryReady = last > ma7 && pos20 >= 20 && pos20 <= 50;
  const watch = ma7;
  const stop = low20 * 0.97;
  const tp1 = ma20;

  return {
    symbol: input.symbol,
    side: 'long',
    strategyType: 'A',
    score,
    price: last,
    entryReady,
    watchLevel: watch,
    stopLoss: stop,
    takeProfit1: tp1,
    reasonNotEntered: entryReady
      ? '模拟观察：结构满足，未自动开仓'
      : '等待回踩 MA7 或突破确认',
    tags,
  };
}

function evalMomentumB(input: StrategyInput): StrategySignal | null {
  const { m15, lastPrice: last, change24h: chg24 } = input;
  if (m15.length < 20) return null;

  const closes = m15.map((k) => k.close);
  const vols = m15.map((k) => k.quoteVolume);
  const high15 = Math.max(...m15.slice(-16).map((k) => k.high));
  const nearHigh = last >= high15 * 0.985;
  const volRecent = avg(vols.slice(-4));
  const volPrev = avg(vols.slice(-8, -4));
  const volExpand = volPrev > 0 && volRecent / volPrev >= 1.4;

  if (chg24 < 3 || !nearHigh) return null;

  let internal = 8;
  const tags: string[] = ['near-15m-high'];
  if (volExpand) {
    internal += 6;
    tags.push('vol-expand');
  }
  if (chg24 >= 8 && chg24 <= 35) {
    internal += 4;
    tags.push('momentum');
  }
  if (chg24 > 40) internal -= 4;

  const score = toDisplayScore(internal);
  const fundingHot =
    input.funding && input.funding.lastFundingRate > 0.0005;
  const entryReady = nearHigh && volExpand && chg24 < 30;

  return {
    symbol: input.symbol,
    side: 'long',
    strategyType: 'B',
    score,
    price: last,
    entryReady,
    watchLevel: high15 * 0.99,
    stopLoss: last * 0.96,
    takeProfit1: last * 1.08,
    reasonNotEntered: fundingHot
      ? '资金费率偏高，防诱多'
      : entryReady
        ? '模拟观察：突破量能配合'
        : '等待 15m 放量突破前高',
    tags,
  };
}

function evalReversionC(input: StrategyInput): StrategySignal | null {
  const { daily: d, lastPrice: last, change24h: chg24 } = input;
  if (d.length < 25) return null;

  const dCl = d.map((k) => k.close);
  const dLo = d.map((k) => k.low);
  const low20 = Math.min(...dLo.slice(-20));
  const rsiVal = rsi(dCl);
  const distLow = ((last - low20) / low20) * 100;

  if (rsiVal > 32 || distLow > 8) return null;

  let internal = 10;
  const tags: string[] = ['oversold'];
  if (rsiVal < 28) {
    internal += 4;
    tags.push('deep-rsi');
  }
  if (chg24 < -5) {
    internal += 3;
    tags.push('dip');
  }

  const score = toDisplayScore(internal);
  const entryReady = rsiVal < 30 && distLow < 5;

  return {
    symbol: input.symbol,
    side: 'long',
    strategyType: 'C',
    score,
    price: last,
    entryReady,
    watchLevel: low20 * 1.02,
    stopLoss: low20 * 0.96,
    takeProfit1: avg(dCl.slice(-20)),
    reasonNotEntered: entryReady
      ? '模拟观察：超卖区，等待企稳 K 线'
      : 'RSI 未充分超卖或离支撑仍远',
    tags,
  };
}

function avg(arr: number[]): number {
  if (!arr.length) return 0;
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

export function evaluateSymbol(input: StrategyInput): StrategySignal | null {
  const candidates = [
    evalSwingA(input),
    evalMomentumB(input),
    evalReversionC(input),
  ].filter((s): s is StrategySignal => s != null);

  if (!candidates.length) return null;
  candidates.sort((a, b) => b.score - a.score);
  return candidates[0];
}

export function scanSymbols(
  inputs: StrategyInput[],
  minScore: number,
): StrategySignal[] {
  const out: StrategySignal[] = [];
  for (const input of inputs) {
    const sig = evaluateSymbol(input);
    if (sig && sig.score >= minScore) out.push(sig);
  }
  out.sort((a, b) => b.score - a.score);
  return out.slice(0, 15);
}
