import type { MarketReport } from '../services/market-summary-service.js';
import {
  pct,
  fmtPrice,
  fmtUsdCompact,
  nowLocal,
  escapeHtml,
  baseFromSymbol,
} from '../utils/format.js';

export function formatMarketReportHtml(report: MarketReport): string {
  const lines: string[] = [];

  lines.push('<b>📊 Binance 永续盘面快报</b>');
  lines.push(`时间：${nowLocal()}`);
  lines.push('模式：只读行情 / 模拟交易');
  lines.push('');

  lines.push('<b>一、大盘状态</b>');
  const m = report.majors;
  lines.push(
    `BTC：$${fmtPrice(m.btc.price)}，24h：${pct(m.btc.change24h)}，15m：${m.btc.trend15m}`,
  );
  lines.push(
    `ETH：$${fmtPrice(m.eth.price)}，24h：${pct(m.eth.change24h)}，15m：${m.eth.trend15m}`,
  );
  lines.push(
    `SOL：$${fmtPrice(m.sol.price)}，24h：${pct(m.sol.change24h)}，15m：${m.sol.trend15m}`,
  );
  lines.push('');
  lines.push(`市场情绪：${report.overview.sentiment}`);
  lines.push(`上涨币：${report.overview.upCount} 个`);
  lines.push(`下跌币：${report.overview.downCount} 个`);
  lines.push(`涨幅 &gt; 8%：${report.overview.upGt8} 个`);
  lines.push(`跌幅 &lt; -8%：${report.overview.downLt8} 个`);
  if (report.losers.length) {
    const weak = report.losers
      .map((l) => `${l.base} ${pct(l.change24h)}`)
      .join('，');
    lines.push(`弱势前列：${escapeHtml(weak)}`);
  }
  lines.push('');

  lines.push('<b>二、强势币 TOP 10</b>');
  report.gainers.forEach((g, i) => {
    const hot = g.overheated ? ' 过热' : '';
    lines.push(
      `${i + 1}. ${escapeHtml(g.base)} ${pct(g.change24h)}  量能：${g.vol15mStatus}  状态：${g.status}${hot}`,
    );
  });
  lines.push('');

  lines.push('<b>三、OI 异常 TOP 10</b>');
  report.oiAbnormal.forEach((o, i) => {
    const oiStr =
      o.oiChangePct != null ? pct(o.oiChangePct) : '基线中';
    lines.push(
      `${i + 1}. ${escapeHtml(o.base)}  价格：${pct(o.priceChangePct)}  OI：${oiStr}  ${escapeHtml(o.judgment)}`,
    );
  });
  lines.push('');

  lines.push('<b>四、候选信号</b>');
  if (!report.signals.length) {
    lines.push('（暂无评分达标信号）');
  } else {
    report.signals.slice(0, 8).forEach((s, i) => {
      const side = s.side === 'long' ? '做多' : '做空';
      lines.push(
        `${i + 1}. ${escapeHtml(baseFromSymbol(s.symbol))} / ${side} / 策略${s.strategyType} / 评分 ${s.score}`,
      );
      lines.push(`   观察：${escapeHtml(s.reasonNotEntered)}`);
      lines.push(`   止损：${fmtPrice(s.stopLoss)}  止盈：${fmtPrice(s.takeProfit1)}`);
    });
  }
  lines.push('');

  lines.push('<b>五、风险提示</b>');
  const r = report.risks;
  lines.push(`- BTC 15m：${r.btc15m}`);
  lines.push(`- ETH 15m：${r.eth15m}`);
  lines.push(`- 小币情绪：${r.altSentiment}`);
  if (r.marketWideDrop) lines.push('- 全市场：普跌风险');
  if (r.macroTodo) lines.push('- 宏观事件：TODO 待接入日历');
  lines.push(`- 建议：${r.suggestion}`);
  lines.push('');
  lines.push(`<b>结论</b>\n当前更适合：${report.conclusion}`);

  let text = lines.join('\n');
  if (text.length > 3500) {
    text = `${text.slice(0, 3480)}\n…（已截断）`;
  }
  return text;
}

export function formatTestMessage(): string {
  return 'Telegram 推送测试成功，当前为只读行情模式。';
}
