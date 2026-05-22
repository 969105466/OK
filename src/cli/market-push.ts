import { runMarketPushOnce } from '../jobs/market-push-job.js';

runMarketPushOnce().then(() => {
  process.exit(process.exitCode ?? 0);
});
