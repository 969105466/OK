import { resetPaperAccount } from '../paper/paper-store.js';

const acc = resetPaperAccount();
console.log(`Paper account reset: ${acc.initialBalance} USDT, 0 positions.`);
