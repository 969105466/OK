/**
 * Binance USDT-M Futures — PUBLIC endpoints only.
 * No signed requests, no order/trade/account write APIs.
 */

import { config } from '../config.js';
import { getJson } from '../utils/http-json.js';

const BASE = config.binance.baseUrl;

export type Kline = {
  openTime: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
  quoteVolume: number;
};

export type Ticker24h = {
  symbol: string;
  lastPrice: number;
  priceChangePercent: number;
  quoteVolume: number;
  highPrice: number;
  lowPrice: number;
};

export type PremiumIndex = {
  symbol: string;
  lastFundingRate: number;
  markPrice: number;
};

let symbolsCache: string[] | null = null;
let symbolsCacheAt = 0;

async function binanceGet<T>(path: string): Promise<T> {
  try {
    return await getJson<T>(`${BASE}${path}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    throw new Error(`Binance ${path}: ${msg}`);
  }
}

function parseKline(row: (string | number)[]): Kline {
  return {
    openTime: Number(row[0]),
    open: Number(row[1]),
    high: Number(row[2]),
    low: Number(row[3]),
    close: Number(row[4]),
    volume: Number(row[5]),
    quoteVolume: Number(row[7]),
  };
}

export async function getUsdtPerpetualSymbols(): Promise<string[]> {
  const now = Date.now();
  if (symbolsCache && now - symbolsCacheAt < 3600_000) return symbolsCache;

  type ExInfo = {
    symbols: Array<{
      symbol: string;
      status: string;
      contractType: string;
      quoteAsset: string;
    }>;
  };
  const info = await binanceGet<ExInfo>('/fapi/v1/exchangeInfo');
  symbolsCache = info.symbols
    .filter(
      (s) =>
        s.status === 'TRADING' &&
        s.contractType === 'PERPETUAL' &&
        s.quoteAsset === 'USDT',
    )
    .map((s) => s.symbol);
  symbolsCacheAt = now;
  return symbolsCache;
}

export async function getTicker24hAll(): Promise<Ticker24h[]> {
  const rows = await binanceGet<
    Array<{
      symbol: string;
      lastPrice: string;
      priceChangePercent: string;
      quoteVolume: string;
      highPrice: string;
      lowPrice: string;
    }>
  >('/fapi/v1/ticker/24hr');

  return rows.map((t) => ({
    symbol: t.symbol,
    lastPrice: Number(t.lastPrice),
    priceChangePercent: Number(t.priceChangePercent),
    quoteVolume: Number(t.quoteVolume),
    highPrice: Number(t.highPrice),
    lowPrice: Number(t.lowPrice),
  }));
}

export async function getKlines(
  symbol: string,
  interval: string,
  limit: number,
): Promise<Kline[]> {
  const rows = await binanceGet<(string | number)[][]>(
    `/fapi/v1/klines?symbol=${symbol}&interval=${interval}&limit=${limit}`,
  );
  return rows.map(parseKline);
}

export async function getOpenInterest(symbol: string): Promise<number> {
  const r = await binanceGet<{ openInterest: string }>(
    `/fapi/v1/openInterest?symbol=${symbol}`,
  );
  return Number(r.openInterest);
}

export async function getPremiumIndex(symbol: string): Promise<PremiumIndex> {
  const r = await binanceGet<{
    symbol: string;
    lastFundingRate: string;
    markPrice: string;
  }>(`/fapi/v1/premiumIndex?symbol=${symbol}`);
  return {
    symbol: r.symbol,
    lastFundingRate: Number(r.lastFundingRate),
    markPrice: Number(r.markPrice),
  };
}

/** Rate-limited parallel map */
export async function mapPool<T, R>(
  items: T[],
  concurrency: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let idx = 0;

  async function worker(): Promise<void> {
    while (idx < items.length) {
      const i = idx++;
      results[i] = await fn(items[i]);
      await sleep(80);
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, () => worker()),
  );
  return results;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
