// Playwright 录屏 / 抓帧脚本
// 用法：
//   npm i -D playwright && npx playwright install chromium
//   node docs/ui-demo/record.mjs
// 产物：docs/ui-demo/out/*.webm（整段视频）+ *.png（关键分镜静帧）

import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, 'out');
mkdirSync(outDir, { recursive: true });

const url = 'file://' + path.join(here, 'index.html').replace(/\\/g, '/');

const browser = await chromium.launch();
const context = await browser.newContext({
  // 2x 像素密度 → 手机框 786×1704，成片更干净
  viewport: { width: 900, height: 1000 },
  deviceScaleFactor: 2,
  recordVideo: { dir: outDir, size: { width: 900, height: 1000 } },
});
const page = await context.newPage();
await page.goto(url);

// 只录/只截手机那一块
const phone = await page.$('#phone');
const shot = async (name) => {
  await phone.screenshot({ path: path.join(outDir, `${name}.png`) });
  console.log('frame:', name);
};

// 关屏保式把开屏先放一遍，避免录到面板状态
await page.evaluate(() => document.getElementById('launch').style.display = 'none');

// ① 开屏
await page.evaluate(() => Demo.replayLaunch());
await shot('01-launch');

// ② 我发一条
await page.evaluate(() => Demo.askUser('我看下今天的改动'));
await shot('02-user');

// ③ 思考流式
await page.evaluate(() => Demo.streamThinking());
await shot('03-thinking');

// ④ 工具行
await page.evaluate(() => Demo.streamTools());
await shot('04-tools');

// ⑤ AI 回答
await page.evaluate(() => Demo.streamAnswer());
await shot('05-answer');

// ⑥ 收尾折叠
await page.evaluate(() => Demo.finishTurn());
await shot('06-fold');

// ⑦ 本轮过程页
await page.evaluate(() => Demo.openTurnLog());
await shot('07-turnlog');

// ⑧ 步骤详情（带图那一步）
await page.evaluate(() => Demo.openStep(2));
await shot('08-step-detail');

// 收尾：把页签切到设置再切回来，多一帧可选素材
await page.evaluate(() => Demo.closeDetail());
await page.evaluate(() => Demo.closeTurnLog());
await page.waitForTimeout(600);

const videoPath = await page.video().path();
console.log('video:', videoPath);
await context.close();
await browser.close();
console.log('done. 产物目录：', outDir);
