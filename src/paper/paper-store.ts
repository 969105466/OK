import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { config } from '../config.js';
import { calcTradeFee } from './fees.js';
import type { PaperAccount, PaperPosition, ClosedTrade } from './types.js';

const STORE_PATH = resolve(process.cwd(), 'data', 'paper-account.json');

export function loadPaperAccount(): PaperAccount {
  if (!existsSync(STORE_PATH)) {
    return createDefaultAccount();
  }
  try {
    const raw = JSON.parse(readFileSync(STORE_PATH, 'utf8')) as PaperAccount;
    return normalizeAccount(raw);
  } catch {
    return createDefaultAccount();
  }
}

export function savePaperAccount(acc: PaperAccount): void {
  acc.updatedAt = new Date().toISOString();
  mkdirSync(dirname(STORE_PATH), { recursive: true });
  writeFileSync(STORE_PATH, JSON.stringify(acc, null, 2), 'utf8');
}

export function resetPaperAccount(): PaperAccount {
  const acc = createDefaultAccount();
  savePaperAccount(acc);
  return acc;
}

function createDefaultAccount(): PaperAccount {
  const p = config.paper;
  return {
    version: 1,
    initialBalance: p.initialBalance,
    balance: p.initialBalance,
    leverage: p.leverage,
    marginPctPerTrade: p.marginPctPerTrade,
    maxPositions: p.maxPositions,
    openPositions: [],
    closedTrades: [],
    updatedAt: new Date().toISOString(),
  };
}

function normalizePosition(p: PaperPosition): PaperPosition {
  const openFee = p.openFee ?? calcTradeFee(p.notional ?? 0);
  return { ...p, openFee };
}

function normalizeClosed(t: ClosedTrade): ClosedTrade {
  const grossPnl = t.grossPnl ?? t.pnl ?? 0;
  const openFee = t.openFee ?? calcTradeFee(t.notional ?? 0);
  const closeFee = t.closeFee ?? 0;
  const totalFees = t.totalFees ?? openFee + closeFee;
  const netPnl = t.netPnl ?? grossPnl - totalFees;
  return {
    ...t,
    grossPnl,
    grossPnlPct: t.grossPnlPct ?? t.pnlPct ?? 0,
    openFee,
    closeFee,
    totalFees,
    netPnl,
    netPnlPct: t.netPnlPct ?? t.pnlPct ?? 0,
    pnl: netPnl,
    pnlPct: t.netPnlPct ?? t.pnlPct ?? 0,
    exitNotional: t.exitNotional ?? (t.notional ?? 0),
  };
}

function normalizeAccount(raw: Partial<PaperAccount>): PaperAccount {
  const def = createDefaultAccount();
  return {
    version: 1,
    initialBalance: raw.initialBalance ?? def.initialBalance,
    balance: raw.balance ?? def.balance,
    leverage: raw.leverage ?? def.leverage,
    marginPctPerTrade: raw.marginPctPerTrade ?? def.marginPctPerTrade,
    maxPositions: raw.maxPositions ?? def.maxPositions,
    openPositions: (raw.openPositions ?? []).map(normalizePosition),
    closedTrades: (raw.closedTrades ?? []).map(normalizeClosed),
    updatedAt: raw.updatedAt ?? new Date().toISOString(),
  };
}
