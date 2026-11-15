#!/usr/bin/env node
/**
 * 给 DSH 打「提问结算通知」补丁 —— 让手机回答完之后，电脑端的提问面板能立刻收起。
 *
 * 背景：
 *   手机答完，答案走宿主侧的 waterfall，桌面端的卡片永远收不到通知
 *   （它的生命周期绑在自己的 promise 上，而宿主没有入口去 resolve 它）。
 *   所以桥会发一个事件 `phone-bridge/ask-settled`，前端收到就把卡片移除。
 *   但前端要能收到，必须：
 *     ① dsh-api-remotes 把这个事件加进转发白名单
 *     ② dsh-client-ui-user-questions 订阅它并移除卡片
 *
 * 用法：
 *   node tools/patch-dsh-ask.mjs            # 打补丁（幂等）
 *   node tools/patch-dsh-ask.mjs --check    # 只看状态，不改文件
 *   node tools/patch-dsh-ask.mjs --revert   # 从备份还原
 *
 * DSH 升级后补丁会被覆盖，重新跑一次即可。
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const EVENT = "phone-bridge/ask-settled";

const CANDIDATES = [
  path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "Programs", "DeepSeek Harness", "resources", "app", "dsh", "node_modules", "@deepseek-ai"),
  "C:/Program Files/DeepSeek Harness/resources/app/dsh/node_modules/@deepseek-ai",
];

function findRoot() {
  for (const root of CANDIDATES) {
    if (fs.existsSync(path.join(root, "dsh-api-remotes", "lib", "index.js"))) return root;
  }
  return null;
}

const root = findRoot();
if (!root) {
  console.error("[patch] 找不到 DSH 安装目录，检查上面的 CANDIDATES");
  process.exit(1);
}

const REMOTES = path.join(root, "dsh-api-remotes", "lib", "index.js");
const UQ = path.join(root, "dsh-client-ui-user-questions", "lib", "client.js");
const mode = process.argv.includes("--revert") ? "revert" : process.argv.includes("--check") ? "check" : "apply";
const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);

function backup(file) {
  const bak = `${file}.bak-phonebridge-${stamp}`;
  if (!fs.existsSync(bak)) fs.copyFileSync(file, bak);
  return bak;
}

function newestBackup(file) {
  const dir = path.dirname(file);
  const base = path.basename(file) + ".bak-phonebridge-";
  const hits = fs.readdirSync(dir).filter((n) => n.startsWith(base)).sort();
  return hits.length ? path.join(dir, hits[hits.length - 1]) : null;
}

function patchRemotes() {
  let t = fs.readFileSync(REMOTES, "utf8");
  if (t.includes(EVENT)) return "已打过";
  const m = t.match(/(\{\s*event: "user-questions\/request",\s*mode: "waterfall"\s*\})\s*\];/);
  if (!m) return "没找到锚点（DSH 版本可能变了）";
  if (mode === "check") return "未打";
  backup(REMOTES);
  t = t.replace(m[0], `${m[1]},\n\t{\n\t\tevent: "${EVENT}",\n\t\tmode: "emit"\n\t}\n];`);
  fs.writeFileSync(REMOTES, t);
  return "已打";
}

function patchClient() {
  let t = fs.readFileSync(UQ, "utf8");
  if (t.includes(EVENT)) return "已打过";
  const anchor = `\t\t\tctx.remote.$on("user-questions/request", function(request, next) {\n\t\t\t\treturn answerQuestion(ctx, this, request, next, cards);\n\t\t\t});`;
  if (!t.includes(anchor)) return "没找到锚点（DSH 版本可能变了）";
  if (mode === "check") return "未打";
  backup(UQ);
  const addition = `${anchor}\n\n\t\t\t// [phone-bridge 补丁] 手机回答完 → 移除本会话的提问卡片。\n\t\t\t// 手机的回答走宿主侧，前端收不到通道通知，面板会一直挂着。\n\t\t\tctx.remote.$on("${EVENT}", function(payload) {\n\t\t\t\tconst sessionId = payload?.sessionId;\n\t\t\t\tif (sessionId === void 0) return;\n\t\t\t\tfor (const card of cards.values()) {\n\t\t\t\t\tif (card.pending.sessionId !== sessionId) continue;\n\t\t\t\t\tif (card.pending.review !== void 0) continue;\n\t\t\t\t\tcard.remove();\n\t\t\t\t}\n\t\t\t});`;
  t = t.replace(anchor, addition);
  fs.writeFileSync(UQ, t);
  return "已打";
}

function revert() {
  for (const file of [REMOTES, UQ]) {
    const bak = newestBackup(file);
    if (!bak) {
      console.log(`[revert] ${path.basename(file)}: 没有备份`);
      continue;
    }
    fs.copyFileSync(bak, file);
    console.log(`[revert] ${path.basename(file)} ← ${path.basename(bak)}`);
  }
}

if (mode === "revert") {
  revert();
} else {
  console.log(`[patch] DSH: ${root}`);
  console.log(`[patch] dsh-api-remotes          : ${patchRemotes()}`);
  console.log(`[patch] dsh-client-ui-user-questions: ${patchClient()}`);
  if (mode === "apply") console.log("[patch] 改完要重启 DSH 才生效");
}
