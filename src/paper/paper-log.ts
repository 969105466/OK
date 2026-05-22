import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const LOG_PATH = resolve(process.cwd(), 'logs', 'paper-trades.jsonl');

export function logPaperEvent(event: Record<string, unknown>): void {
  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    appendFileSync(
      LOG_PATH,
      `${JSON.stringify({ time: new Date().toISOString(), ...event })}\n`,
      'utf8',
    );
  } catch (e) {
    console.warn('[paper-log]', e instanceof Error ? e.message : e);
  }
}
