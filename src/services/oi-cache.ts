import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const CACHE_PATH = resolve(process.cwd(), 'data', 'oi-snapshot.json');

export type OiSnapshot = Record<string, { oi: number; ts: number }>;

export function loadOiSnapshot(): OiSnapshot {
  try {
    if (!existsSync(CACHE_PATH)) return {};
    return JSON.parse(readFileSync(CACHE_PATH, 'utf8')) as OiSnapshot;
  } catch {
    return {};
  }
}

export function saveOiSnapshot(snapshot: OiSnapshot): void {
  mkdirSync(dirname(CACHE_PATH), { recursive: true });
  writeFileSync(CACHE_PATH, JSON.stringify(snapshot, null, 0), 'utf8');
}

export function oiChangePct(
  prev: number | undefined,
  current: number,
): number | null {
  if (prev == null || prev <= 0) return null;
  return ((current - prev) / prev) * 100;
}

export function classifyOiPrice(
  priceChgPct: number,
  oiChgPct: number | null,
): string {
  if (oiChgPct == null) return 'OI 基线记录中';
  const oiUp = oiChgPct > 1;
  const oiDn = oiChgPct < -1;
  const pxUp = priceChgPct > 0.5;
  const pxDn = priceChgPct < -0.5;
  if (pxUp && oiUp) return '趋势多头 / 也可能诱多';
  if (pxDn && oiUp) return '空头增强 / 多头被套';
  if (pxUp && oiDn) return '空头回补 / 拉盘不稳';
  if (pxDn && oiDn) return '多空离场 / 趋势衰减';
  return 'OI 变化温和';
}
