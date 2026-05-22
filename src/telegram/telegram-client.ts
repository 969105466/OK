import { config, telegramConfigured } from '../config.js';
import { postJson } from '../utils/http-json.js';

const MAX_CHUNK = 4000;

export class TelegramClient {
  private readonly token: string;
  private readonly chatId: string;
  private readonly parseMode: string;
  private readonly enabled: boolean;

  constructor() {
    this.enabled = config.telegram.enabled;
    this.token = config.telegram.botToken;
    this.chatId = config.telegram.chatId;
    this.parseMode = config.telegram.parseMode;
  }

  isReady(): boolean {
    return this.enabled && telegramConfigured();
  }

  async sendMessage(text: string): Promise<void> {
    if (!this.enabled) {
      console.warn('[telegram] TELEGRAM_ENABLED=false，跳过推送');
      return;
    }
    if (!telegramConfigured()) {
      console.warn(
        '[telegram] 缺少 TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID，跳过推送',
      );
      return;
    }

    const chunks = splitMessage(text, MAX_CHUNK);
    for (const chunk of chunks) {
      await this.postChunk(chunk);
    }
  }

  private async postChunk(text: string): Promise<void> {
    const url = `https://api.telegram.org/bot${this.token}/sendMessage`;
    try {
      await postJson(url, {
        chat_id: this.chatId,
        text,
        parse_mode: this.parseMode,
        disable_web_page_preview: true,
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[telegram] sendMessage failed:', msg);
      throw e;
    }
  }
}

function splitMessage(text: string, maxLen: number): string[] {
  if (text.length <= maxLen) return [text];
  const parts: string[] = [];
  let rest = text;
  while (rest.length > maxLen) {
    let cut = rest.lastIndexOf('\n', maxLen);
    if (cut < maxLen * 0.5) cut = maxLen;
    parts.push(rest.slice(0, cut));
    rest = rest.slice(cut).trimStart();
  }
  if (rest) parts.push(rest);
  return parts;
}
