// 用系统 Chrome 截取 UI 复刻的各个状态（不下载 Chromium）
// 产物：docs/ui-demo/frames/*.png（2x，786×1704）
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, 'frames');
mkdirSync(outDir, { recursive: true });

const url = 'file://' + path.join(here, 'index.html').replace(/\\/g, '/');

const browser = await chromium.launch({
  channel: 'chrome',                       // 用系统 Chrome
  args: ['--force-device-scale-factor=3', '--hide-scrollbars'],
});
const context = await browser.newContext({
  viewport: { width: 900, height: 1000 },
  deviceScaleFactor: 3,                    // 3x：393*3 = 1179，够 1920 片子用
});
const page = await context.newPage();
await page.goto(url, { waitUntil: 'networkidle' });

const phone = await page.$('#phone');
const shot = async (name) => {
  await phone.screenshot({ path: path.join(outDir, `${name}.png`) });
  console.log('shot:', name);
};

// 关掉开屏，先截空态
await page.evaluate(() => {
  document.getElementById('launch').style.display = 'none';
  document.querySelectorAll('.panel, #panel, .controls').forEach(e => e.style.display = 'none');
});

await page.waitForTimeout(300);
await shot('01-empty');

// 开屏（截中间态）
await page.evaluate(() => {
  const el = document.getElementById('launch');
  el.style.display = 'grid';
  el.classList.remove('in', 'leaving');
  void el.offsetWidth;
  el.classList.add('in');
});
await page.waitForTimeout(320);
await shot('02-launch');
await page.evaluate(() => {
  const el = document.getElementById('launch');
  el.style.display = 'none';
  el.classList.remove('in', 'leaving');
});

// 用户消息
await page.evaluate(() => Demo.askUser('把今天的改动同步到手机上'));
await page.waitForTimeout(350);
await shot('03-user');

// 思考
await page.evaluate(() => Demo.streamThinking());
await page.waitForTimeout(260);
await shot('04-thinking');

// 工具行（逐条：先 1 条、再全量）
await page.evaluate(() => Demo.streamTools([[
  '读取', 'uploads/1794560546-image-1794560546-0.jpg']]));
await page.waitForTimeout(300);
await shot('05-tool1');

await page.evaluate(() => Demo.streamTools([
  ['运行命令', 'Verify the build artifact'],
  ['写入', 'docs/KNOWN-GOOD.md'],
]));
await page.waitForTimeout(650);
await shot('06-tools');

// 回答
await page.evaluate(() => Demo.streamAnswer());
await page.waitForTimeout(600);
await shot('07-answer');

// 折叠
await page.evaluate(() => Demo.finishTurn({ steps: 7, seconds: '3 分 12 秒' }));
await page.waitForTimeout(700);
await shot('08-fold');

// 本轮过程
await page.evaluate(() => Demo.openTurnLog());
await page.waitForTimeout(600);
await shot('09-turnlog');

// 步骤详情
await page.evaluate(() => Demo.openStep(2));
await page.waitForTimeout(600);
await shot('10-detail');

// 返回并多截一张：折叠态 + 底部栏
await page.evaluate(() => { Demo.closeDetail(); Demo.closeTurnLog(); });
await page.waitForTimeout(500);
await shot('11-back');

await context.close();
await browser.close();

console.log('\n产物目录:', outDir);
