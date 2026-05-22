import { config as loadDotenv } from 'dotenv';
import { resolve } from 'node:path';

loadDotenv({ path: resolve(process.cwd(), '.env') });

function envStr(key: string, fallback = ''): string {
  return (process.env[key] ?? fallback).trim();
}

function envBool(key: string, fallback: boolean): boolean {
  const v = envStr(key);
  if (!v) return fallback;
  return v === '1' || v.toLowerCase() === 'true' || v.toLowerCase() === 'yes';
}

function envInt(key: string, fallback: number): number {
  const n = parseInt(envStr(key), 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function envFloat(key: string, fallback: number): number {
  const n = parseFloat(envStr(key));
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

export const config = {
  telegram: {
    enabled: envBool('TELEGRAM_ENABLED', true),
    botToken: envStr('TELEGRAM_BOT_TOKEN'),
    chatId: envStr('TELEGRAM_CHAT_ID'),
    pushIntervalMinutes: envInt('TELEGRAM_PUSH_INTERVAL_MINUTES', 10),
    parseMode: envStr('TELEGRAM_PARSE_MODE', 'HTML') || 'HTML',
    /** false = 只推开平仓，不发盘面快报 */
    marketReport: envBool('TELEGRAM_MARKET_REPORT', false),
  },
  marketPush: {
    enabled: envBool('MARKET_PUSH_ENABLED', true),
    topGainers: envInt('MARKET_PUSH_TOP_GAINERS', 60),
    topLosers: envInt('MARKET_PUSH_TOP_LOSERS', 30),
    topOiAbnormal: envInt('MARKET_PUSH_TOP_OI_ABNORMAL', 10),
    signalMinScore: envInt('MARKET_PUSH_SIGNAL_MIN_SCORE', 75),
    /** 扫描池最小 24h 成交额 (USDT)，过滤极低流动性 */
    minQuoteVolume: envFloat('MARKET_MIN_QUOTE_VOLUME', 500_000),
    maxScanCandidates: envInt('MARKET_SCAN_MAX_CANDIDATES', 95),
  },
  binance: {
    baseUrl: envBool('BINANCE_USE_TESTNET', false)
      ? 'https://testnet.binancefuture.com'
      : 'https://fapi.binance.com',
  },
  paper: {
    enabled: envBool('PAPER_TRADING_ENABLED', true),
    autoTrade: envBool('PAPER_AUTO_TRADE', true),
    initialBalance: envFloat('PAPER_INITIAL_BALANCE', 1000),
    leverage: envInt('PAPER_LEVERAGE', 3),
    marginPctPerTrade: envFloat('PAPER_MARGIN_PCT', 10),
    maxPositions: envInt('PAPER_MAX_POSITIONS', 3),
    openMinScore: envInt('PAPER_OPEN_MIN_SCORE', 75),
    /** 评分达标即可开仓（不要求 entryReady），便于纸面测试 */
    openOnWatchlist: envBool('PAPER_OPEN_ON_SIGNAL', true),
    /** Taker 0.04% = 0.0004 */
    takerFeeRate: envFloat('PAPER_TAKER_FEE_RATE', 0.0004),
    pushTrades: envBool('PAPER_PUSH_TRADES', true),
    /** 每轮扫描推送账户结果（持仓/盈亏），无开平仓也发 */
    pushStatusEveryCycle: envBool('PAPER_PUSH_STATUS_EVERY_CYCLE', true),
  },
} as const;

export function telegramConfigured(): boolean {
  return Boolean(config.telegram.botToken && config.telegram.chatId);
}
