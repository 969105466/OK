import { TelegramClient } from '../telegram/telegram-client.js';
import { formatTestMessage } from '../telegram/message-templates.js';
import { logPush } from '../utils/push-logger.js';

async function main(): Promise<void> {
  const text = formatTestMessage();
  const client = new TelegramClient();

  if (!client.isReady()) {
    console.warn(
      '[push:test] 请在 .env 中配置 TELEGRAM_BOT_TOKEN 与 TELEGRAM_CHAT_ID',
    );
    process.exitCode = 1;
    return;
  }

  try {
    await client.sendMessage(text);
    console.log('[push:test] OK — 请检查 Telegram 是否收到消息');
    logPush({
      time: new Date().toISOString(),
      success: true,
      message_type: 'test',
      message_length: text.length,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('[push:test] failed:', msg);
    logPush({
      time: new Date().toISOString(),
      success: false,
      message_type: 'test',
      message_length: text.length,
      error: msg,
    });
    process.exitCode = 1;
  }
}

main();
