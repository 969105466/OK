import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

export interface PushLogEntry {
  time: string;
  success: boolean;
  message_type: string;
  message_length: number;
  error?: string;
  market_sentiment?: string;
  signal_count?: number;
  top_gainers?: string[];
  top_oi_symbols?: string[];
  paper_opened?: number;
  paper_closed?: number;
  paper_equity?: number;
}

const LOG_PATH = resolve(process.cwd(), 'logs', 'telegram-push.jsonl');

export function logPush(entry: PushLogEntry): void {
  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    appendFileSync(LOG_PATH, `${JSON.stringify(entry)}\n`, 'utf8');
  } catch (e) {
    console.warn('[push-log] failed to write:', e instanceof Error ? e.message : e);
  }
}
