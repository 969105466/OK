import { config } from '../config.js';
import {
  getTicker24hAll,
  getUsdtPerpetualSymbols,
  getKlines,
  getOpenInterest,
  getPremiumIndex,
  mapPool,
  type Ticker24h,
  type Kline,
} from '../binance/public-client.js';
import { scanSymbols, type StrategySignal } from '../strategy/strategy-engine.js';
import type { StrategyInput } from '../strategy/strategy-engine.js';
import {
  loadOiSnapshot,
  saveOiSnapshot,
  oiChangePct,
  classifyOiPrice,
  type OiSnapshot,
} from './oi-cache.js';
import { baseFromSymbol } from '../utils/format.js';

export type Trend15m = '上涨' | '震荡' | '下跌';

export interface MajorCoin {
  symbol: string;
  price: number;
  change24h: number;
  trend15m: Trend15m;
}

export interface GainerRow {
  symbol: string;
  base: string;
  change24h: number;
  price: number;
  quoteVolume: number;
  vol15mStatus: '放大' | '正常' | '萎缩';
  status: '突破' | '高位' | '回踩' | '震荡';
  near15mHigh: boolean;
  overheated: boolean;
}

export interface LoserRow {
  symbol: string;
  base: string;
  change24h: number;
  price: number;
  quoteVolume: number;
}

export interface OiAbnormalRow {
  symbol: string;
  base: string;
  oi: number;
  oiChangePct: number | null;
  priceChangePct: number;
  judgment: string;
}

export interface RiskHints {
  btc15m: '正常' | '跳水风险';
  eth15m: '正常' | '跳水风险';
  altSentiment: '正常' | '过热';
  suggestion: '观察' | '可轻仓' | '暂停开仓';
  marketWideDrop: boolean;
  macroTodo: boolean;
}

export type MarketSentiment = '偏多' | '偏空' | '震荡' | '混乱';

export interface MarketReport {
  generatedAt: string;
  majors: { btc: MajorCoin; eth: MajorCoin; sol: MajorCoin };
  overview: {
    totalContracts: number;
    upCount: number;
    downCount: number;
    upGt8: number;
    downLt8: number;
    topVolume: Array<{ symbol: string; quoteVolume: number }>;
    sentiment: MarketSentiment;
  };
  gainers: GainerRow[];
  losers: LoserRow[];
  oiAbnormal: OiAbnormalRow[];
  signals: StrategySignal[];
  risks: RiskHints;
  conclusion: string;
}

function trend15m(klines: Kline[]): Trend15m {
  if (klines.length < 5) return '震荡';
  const c = klines.map((k) => k.close);
  const ch3 = ((c.at(-1)! - c.at(-4)!) / c.at(-4)!) * 100;
  if (ch3 > 0.35) return '上涨';
  if (ch3 < -0.35) return '下跌';
  return '震荡';
}

function fastDumpRisk(klines: Kline[]): boolean {
  if (klines.length < 4) return false;
  const c = klines.map((k) => k.close);
  const ch3 = ((c.at(-1)! - c.at(-4)!) / c.at(-4)!) * 100;
  const lastBar = ((c.at(-1)! - c.at(-2)!) / c.at(-2)!) * 100;
  return ch3 < -1.2 || lastBar < -0.8;
}

function vol15mStatus(klines: Kline[]): '放大' | '正常' | '萎缩' {
  const vols = klines.map((k) => k.quoteVolume);
  if (vols.length < 8) return '正常';
  const recent = avg(vols.slice(-4));
  const prev = avg(vols.slice(-8, -4));
  if (prev <= 0) return '正常';
  const r = recent / prev;
  if (r >= 1.35) return '放大';
  if (r <= 0.75) return '萎缩';
  return '正常';
}

function gainerStatus(
  klines: Kline[],
  change24h: number,
  nearHigh: boolean,
): GainerRow['status'] {
  if (nearHigh && change24h > 15) return '高位';
  if (nearHigh) return '突破';
  const c = klines.map((k) => k.close);
  const ma = avg(c.slice(-8));
  if (c.at(-1)! < ma * 1.005 && change24h > 5) return '回踩';
  return '震荡';
}

function avg(arr: number[]): number {
  return arr.reduce((a, b) => a + b, 0) / (arr.length || 1);
}

function computeSentiment(
  up: number,
  down: number,
  upGt8: number,
  downLt8: number,
  btcChg: number,
): MarketSentiment {
  const total = up + down || 1;
  const upRatio = up / total;
  if (upGt8 >= 25 && downLt8 >= 25) return '混乱';
  if (upRatio > 0.58 && btcChg > 0) return '偏多';
  if (upRatio < 0.42 || btcChg < -2) return '偏空';
  return '震荡';
}

function buildConclusion(
  sentiment: MarketSentiment,
  risks: RiskHints,
  signalCount: number,
): string {
  if (risks.suggestion === '暂停开仓') return '空仓观察';
  if (risks.btc15m === '跳水风险' || risks.eth15m === '跳水风险')
    return '防诱多 / 等回踩';
  if (sentiment === '偏多' && signalCount > 0) return '追强 / 等回踩';
  if (sentiment === '偏空') return '空仓观察';
  if (sentiment === '混乱') return '防诱多';
  return '等回踩';
}

export class MarketSummaryService {
  async buildReport(): Promise<MarketReport> {
    const cfg = config.marketPush;
    const allowed = new Set(await getUsdtPerpetualSymbols());
    const allTickers = (await getTicker24hAll()).filter((t) =>
      allowed.has(t.symbol),
    );

    const btcT = allTickers.find((t) => t.symbol === 'BTCUSDT')!;
    const ethT = allTickers.find((t) => t.symbol === 'ETHUSDT')!;
    const solT = allTickers.find((t) => t.symbol === 'SOLUSDT')!;

    const [btc15, eth15, sol15] = await Promise.all([
      getKlines('BTCUSDT', '15m', 12),
      getKlines('ETHUSDT', '15m', 12),
      getKlines('SOLUSDT', '15m', 12),
    ]);

    const upCount = allTickers.filter((t) => t.priceChangePercent > 0).length;
    const downCount = allTickers.filter((t) => t.priceChangePercent < 0).length;
    const upGt8 = allTickers.filter((t) => t.priceChangePercent > 8).length;
    const downLt8 = allTickers.filter((t) => t.priceChangePercent < -8).length;

    const topVolume = [...allTickers]
      .sort((a, b) => b.quoteVolume - a.quoteVolume)
      .slice(0, 10)
      .map((t) => ({ symbol: t.symbol, quoteVolume: t.quoteVolume }));

    const sentiment = computeSentiment(
      upCount,
      downCount,
      upGt8,
      downLt8,
      btcT.priceChangePercent,
    );

    const minVol = config.marketPush.minQuoteVolume;
    const liquid = allTickers.filter((t) => t.quoteVolume >= minVol);

    const gainersRaw = [...liquid]
      .sort((a, b) => b.priceChangePercent - a.priceChangePercent)
      .slice(0, cfg.topGainers);

    const losersRaw = [...liquid]
      .sort((a, b) => a.priceChangePercent - b.priceChangePercent)
      .slice(0, cfg.topLosers);

    console.log(
      `[market] scan pool: top ${gainersRaw.length} gainers + top ${losersRaw.length} losers (min vol ${(minVol / 1e6).toFixed(1)}M)`,
    );

    const candidateSet = new Set<string>([
      ...gainersRaw.map((t) => t.symbol),
      ...losersRaw.map((t) => t.symbol),
      'BTCUSDT',
      'ETHUSDT',
      'SOLUSDT',
    ]);

    const oiPrev = loadOiSnapshot();
    const oiNext: OiSnapshot = { ...oiPrev };

    const candidates = [...candidateSet].slice(
      0,
      config.marketPush.maxScanCandidates,
    );
    console.log(`[market] fetching klines for ${candidates.length} symbols...`);

    const detailMap = new Map<
      string,
      {
        m15: Kline[];
        daily: Kline[];
        h4: Kline[];
        oi: number;
        funding?: Awaited<ReturnType<typeof getPremiumIndex>>;
      }
    >();

    await mapPool(candidates, 5, async (symbol) => {
      try {
        const [m15, daily, h4, oi] = await Promise.all([
          getKlines(symbol, '15m', 24),
          getKlines(symbol, '1d', 30),
          getKlines(symbol, '4h', 20),
          getOpenInterest(symbol),
        ]);
        oiNext[symbol] = { oi, ts: Date.now() };
        detailMap.set(symbol, { m15, daily, h4, oi });
      } catch (e) {
        console.warn(`[market] skip ${symbol}:`, e instanceof Error ? e.message : e);
      }
    });

    saveOiSnapshot(oiNext);

    const fundingSymbols = gainersRaw.slice(0, 20).map((t) => t.symbol);
    const fundingMap = new Map<string, Awaited<ReturnType<typeof getPremiumIndex>>>();
    await mapPool(fundingSymbols, 3, async (sym) => {
      try {
        fundingMap.set(sym, await getPremiumIndex(sym));
      } catch {
        /* ignore */
      }
    });

    const gainers: GainerRow[] = gainersRaw.map((t) => {
      const d = detailMap.get(t.symbol);
      const m15 = d?.m15 ?? [];
      const high15 = m15.length
        ? Math.max(...m15.slice(-16).map((k) => k.high))
        : t.highPrice;
      const nearHigh = t.lastPrice >= high15 * 0.98;
      const fund = fundingMap.get(t.symbol);
      const overheated =
        t.priceChangePercent > 25 ||
        (fund != null && fund.lastFundingRate > 0.001);

      return {
        symbol: t.symbol,
        base: baseFromSymbol(t.symbol),
        change24h: t.priceChangePercent,
        price: t.lastPrice,
        quoteVolume: t.quoteVolume,
        vol15mStatus: vol15mStatus(m15),
        status: gainerStatus(m15, t.priceChangePercent, nearHigh),
        near15mHigh: nearHigh,
        overheated,
      };
    });

    const losers: LoserRow[] = losersRaw.map((t) => ({
      symbol: t.symbol,
      base: baseFromSymbol(t.symbol),
      change24h: t.priceChangePercent,
      price: t.lastPrice,
      quoteVolume: t.quoteVolume,
    }));

    const oiRows: OiAbnormalRow[] = [];
    for (const sym of candidates) {
      const t = allTickers.find((x) => x.symbol === sym);
      const cur = oiNext[sym]?.oi;
      if (!t || cur == null) continue;
      const prev = oiPrev[sym]?.oi;
      const chg = oiChangePct(prev, cur);
      oiRows.push({
        symbol: sym,
        base: baseFromSymbol(sym),
        oi: cur,
        oiChangePct: chg,
        priceChangePct: t.priceChangePercent,
        judgment: classifyOiPrice(t.priceChangePercent, chg),
      });
    }

    oiRows.sort((a, b) => {
      const av = Math.abs(a.oiChangePct ?? 0);
      const bv = Math.abs(b.oiChangePct ?? 0);
      return bv - av;
    });

    const strategyInputs: StrategyInput[] = [];
    for (const sym of candidates) {
      const t = allTickers.find((x) => x.symbol === sym);
      const d = detailMap.get(sym);
      if (!t || !d || d.daily.length < 20) continue;
      strategyInputs.push({
        symbol: sym,
        lastPrice: t.lastPrice,
        change24h: t.priceChangePercent,
        quoteVolume: t.quoteVolume,
        daily: d.daily,
        h4: d.h4,
        m15: d.m15,
        funding: fundingMap.get(sym),
      });
    }

    const signals = scanSymbols(strategyInputs, cfg.signalMinScore);

    const overheatedAlts = gainers.filter((g) => g.overheated).length;
    const marketWideDrop =
      downLt8 > 15 && btcT.priceChangePercent < -1 && ethT.priceChangePercent < -1;

    const risks: RiskHints = {
      btc15m: fastDumpRisk(btc15) ? '跳水风险' : '正常',
      eth15m: fastDumpRisk(eth15) ? '跳水风险' : '正常',
      altSentiment: overheatedAlts >= 3 ? '过热' : '正常',
      marketWideDrop,
      macroTodo: true,
      suggestion:
        marketWideDrop || fastDumpRisk(btc15)
          ? '暂停开仓'
          : overheatedAlts >= 4
            ? '观察'
            : sentiment === '偏多' && signals.length > 0
              ? '可轻仓'
              : '观察',
    };

    return {
      generatedAt: new Date().toISOString(),
      majors: {
        btc: {
          symbol: 'BTCUSDT',
          price: btcT.lastPrice,
          change24h: btcT.priceChangePercent,
          trend15m: trend15m(btc15),
        },
        eth: {
          symbol: 'ETHUSDT',
          price: ethT.lastPrice,
          change24h: ethT.priceChangePercent,
          trend15m: trend15m(eth15),
        },
        sol: {
          symbol: 'SOLUSDT',
          price: solT.lastPrice,
          change24h: solT.priceChangePercent,
          trend15m: trend15m(sol15),
        },
      },
      overview: {
        totalContracts: allTickers.length,
        upCount,
        downCount,
        upGt8,
        downLt8,
        topVolume,
        sentiment,
      },
      gainers,
      losers,
      oiAbnormal: oiRows.slice(0, cfg.topOiAbnormal),
      signals,
      risks,
      conclusion: buildConclusion(sentiment, risks, signals.length),
    };
  }
}
