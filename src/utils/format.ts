export function pct(n: number, digits = 2): string {
  const sign = n >= 0 ? '+' : '';
  return `${sign}${n.toFixed(digits)}%`;
}

export function fmtPrice(price: number): string {
  if (!Number.isFinite(price)) return '-';
  if (price >= 1000) return price.toFixed(2);
  if (price >= 1) return price.toFixed(4);
  if (price >= 0.01) return price.toFixed(5);
  return price.toPrecision(4);
}

export function fmtUsdCompact(usd: number): string {
  if (usd >= 1e9) return `${(usd / 1e9).toFixed(2)}B`;
  if (usd >= 1e6) return `${(usd / 1e6).toFixed(2)}M`;
  if (usd >= 1e3) return `${(usd / 1e3).toFixed(1)}K`;
  return usd.toFixed(0);
}

export function nowLocal(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function baseFromSymbol(symbol: string): string {
  return symbol.endsWith('USDT') ? symbol.slice(0, -4) : symbol;
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
