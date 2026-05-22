import { config } from '../config.js';

/** USDT-M 默认 taker 0.04% */
export function feeRate(): number {
  return config.paper.takerFeeRate;
}

export function calcTradeFee(notional: number): number {
  return notional * feeRate();
}

export function feePctLabel(): string {
  return `${(feeRate() * 100).toFixed(3)}%`;
}
