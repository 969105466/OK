/**
 * 读取 .env 中的 TELEGRAM_BOT_TOKEN，调用 getUpdates 列出 chat_id。
 * 使用前请先在 Telegram 里给你的机器人发一条消息（如 /start 或 hi）。
 */
import { config as loadDotenv } from 'dotenv';
import { resolve } from 'node:path';

loadDotenv({ path: resolve(process.cwd(), '.env') });

const token = (process.env.TELEGRAM_BOT_TOKEN ?? '').trim();

async function main(): Promise<void> {
  if (!token || token.includes('your_bot')) {
    console.log('请先把 TELEGRAM_BOT_TOKEN 写入 D:\\code\\BN\\.env（不要只改 .env.example）');
    process.exitCode = 1;
    return;
  }

  console.log('1. 在 Telegram 打开你的机器人，发送任意消息（例如 /start）');
  console.log('2. 然后本脚本会查询 getUpdates …\n');

  const url = `https://api.telegram.org/bot${token}/getUpdates`;
  let data: {
    ok: boolean;
    result: Array<{
      message?: { chat: { id: number; type: string; username?: string; first_name?: string } };
      my_chat_member?: { chat: { id: number; type: string } };
    }>;
    description?: string;
  };

  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    data = (await res.json()) as typeof data;
  } catch (e) {
    console.error('请求失败（需能访问 api.telegram.org）:', e instanceof Error ? e.message : e);
    process.exitCode = 1;
    return;
  }

  if (!data.ok) {
    console.error('Telegram 返回错误:', data.description ?? data);
    process.exitCode = 1;
    return;
  }

  const chats = new Map<number, string>();
  for (const u of data.result) {
    const chat = u.message?.chat ?? u.my_chat_member?.chat;
    if (!chat) continue;
    const label =
      chat.type === 'private'
        ? `私聊 ${(u.message?.chat as { first_name?: string })?.first_name ?? ''}`.trim()
        : `${chat.type} id=${chat.id}`;
    chats.set(chat.id, label);
  }

  if (chats.size === 0) {
    console.log('没有找到任何对话。');
    console.log('请先给机器人发一条消息，再重新运行: npm run telegram:chat-id');
    process.exitCode = 1;
    return;
  }

  console.log('在 .env 里填写 TELEGRAM_CHAT_ID（个人号一般是正数）：\n');
  for (const [id, label] of chats) {
    console.log(`  TELEGRAM_CHAT_ID=${id}   # ${label}`);
  }
}

main();
