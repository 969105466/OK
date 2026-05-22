import type { Side, StrategyType } from '../strategy/strategy-engine.js';

export type ExitReason = 'tp1' | 'tp2' | 'sl' | 'manual' | 'signal_exit';

export interface PaperPosition {
  id: string;
  symbol: string;
  side: Side;
  strategyType: StrategyType;
  score: number;
  entryPrice: number;
  margin: number;
  leverage: number;
  notional: number;
  quantity: number;
  openFee: number;
  stopLoss: number;
  takeProfit1: number;
  takeProfit2?: number;
  openedAt: string;
  watchLevel: number;
  reason: string;
}

export interface ClosedTrade {
  id: string;
  symbol: string;
  side: Side;
  strategyType: StrategyType;
  score: number;
  entryPrice: number;
  exitPrice: number;
  exitReason: ExitReason;
  margin: number;
  leverage: number;
  notional: number;
  exitNotional: number;
  openFee: number;
  closeFee: number;
  totalFees: number;
  grossPnl: number;
  grossPnlPct: number;
  /** 扣费后净盈亏 */
  netPnl: number;
  netPnlPct: number;
  /** @deprecated 同 netPnl，兼容旧数据 */
  pnl: number;
  pnlPct: number;
  stopLoss: number;
  takeProfit1: number;
  openedAt: string;
  closedAt: string;
}

export interface PaperAccount {
  version: 1;
  initialBalance: number;
  balance: number;
  leverage: number;
  marginPctPerTrade: number;
  maxPositions: number;
  openPositions: PaperPosition[];
  closedTrades: ClosedTrade[];
  updatedAt: string;
}

export interface PaperCycleResult {
  opened: PaperPosition[];
  closed: ClosedTrade[];
  equity: number;
  unrealizedPnl: number;
  available: number;
  skippedReason?: string;
}
