import { config } from '../config.js';
import { startMarketWatch } from '../jobs/market-push-job.js';

if (!config.marketPush.enabled) {
  console.warn('[market:watch] MARKET_PUSH_ENABLED=false');
  process.exit(0);
}

startMarketWatch();

process.on('SIGINT', () => {
  console.log('\n[market:watch] stopped');
  process.exit(0);
});
