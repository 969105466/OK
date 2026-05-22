import type { ClosedTrade } from './types.js';

export const HOURS_24_MS = 24 * 60 * 60 * 1000;

export function tradesWithinMs(
  trades: ClosedTrade[],
  windowMs: number = HOURS_24_MS,
): ClosedTrade[] {
  const since = Date.now() - windowMs;
  return trades.filter((t) => new Date(t.closedAt).getTime() >= since);
}

export function tradesLast24h(trades: ClosedTrade[]): ClosedTrade[] {
  return tradesWithinMs(trades, HOURS_24_MS);
}

export function sumNetPnl(trades: ClosedTrade[]): number {
  return trades.reduce((s, t) => s + (t.netPnl ?? t.pnl ?? 0), 0);
}

export function sumFees(trades: ClosedTrade[]): number {
  return trades.reduce((s, t) => s + (t.totalFees ?? 0), 0);
}

export function formatClosedAt(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
