#!/usr/bin/env node
/**
 * 给 DSH 打「提问远程提交」补丁。
 *
 * 为什么需要：
 *   手机选了答案之后，必须由**桌面端自己按下"提交"**，DSH 才会按原生流程
 *   结算提问、收起面板、广播 tool.result。桥拿不到那个按钮，只能通过一个
 *   自定义 Remote 事件请前端代按。
 *
 * 改什么：
 *   ① dsh-api-remotes/lib/index.js        把 phone-bridge/ask-submit 加入转发白名单
 *   ② dsh-client-ui-user-questions/lib/client.js
 *      订阅该事件 → card.pending.answer({ answers })（和点按钮同一条路径）
 *
 * 用法：
 *   node tools/patch-dsh-ask.mjs           打补丁（幂等）
 *   node tools/patch-dsh-ask.mjs --check   只看状态
 *   node tools/patch-dsh-ask.mjs --revert  从备份还原
 *
 * DSH 升级会覆盖这两个文件，重新跑一次即可。
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const EVENT = "phone-bridge/ask-submit";
const LEGACY_EVENT = "phone-bridge/ask-settled";

const CANDIDATES = [
  path.join(
    process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
    "Programs", "DeepSeek Harness", "resources", "app", "dsh", "node_modules", "@deepseek-ai",
  ),
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
  console.error("[patch] 找不到 DSH 安装目录");
  process.exit(1);
}

const REMOTES = path.join(root, "dsh-api-remotes", "lib", "index.js");
const UQ = path.join(root, "dsh-client-ui-user-questions", "lib", "client.js");

const mode = process.argv.includes("--revert")
  ? "revert"
  : process.argv.includes("--check")
    ? "check"
    : "apply";

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

/** ① remotes：把事件加进转发白名单（顺带清掉旧的 ask-settled） */
function patchRemotes() {
  let t = fs.readFileSync(REMOTES, "utf8");
  const hasNew = t.includes(`event: "${EVENT}"`);
  const hasLegacy = t.includes(`event: "${LEGACY_EVENT}"`);

  if (hasNew && !hasLegacy) return "已打过";
  if (mode === "check") return hasNew ? "已打过" : "未打";

  backup(REMOTES);

  if (hasLegacy) {
    // 旧补丁残留：整段替换
    t = t.replace(
      new RegExp(`\\{\\s*event: "${LEGACY_EVENT}",\\s*mode: "emit"\\s*\\}`),
      `{\n\t\tevent: "${EVENT}",\n\t\tmode: "emit"\n\t}`,
    );
  }
  if (!t.includes(`event: "${EVENT}"`)) {
    const m = t.match(/(\{\s*event: "user-questions\/request",\s*mode: "waterfall"\s*\})\s*\];/);
    if (!m) return "没找到锚点（DSH 版本可能变了）";
    t = t.replace(
      m[0],
      `${m[1]},\n\t{\n\t\tevent: "${EVENT}",\n\t\tmode: "emit"\n\t}\n];`,
    );
  }
  fs.writeFileSync(REMOTES, t);
  return "已打";
}

const ANCHOR = `\t\t\tctx.remote.$on("user-questions/request", function(request, next) {\n\t\t\t\treturn answerQuestion(ctx, this, request, next, cards);\n\t\t\t});`;

const HANDLER = `
\t\t\t// [phone-bridge 补丁] 手机提交的答案，由桌面端替用户按下「提交」。
\t\t\t// 走的是面板按钮同一条路径（pending.answer → waterfall.resolve），
\t\t\t// 所以 DSH 按原生流程结算：工具返回、面板收起、tool.result 广播。
\t\t\tctx.remote.$on("${EVENT}", function(payload) {
\t\t\t\tconst sessionId = payload?.sessionId;
\t\t\t\tconst answers = payload?.answers;
\t\t\t\tif (sessionId === void 0 || Array.isArray(answers) === false) return;
\t\t\t\tfor (const card of cards.values()) {
\t\t\t\t\tif (card.pending.sessionId !== sessionId) continue;
\t\t\t\t\tif (card.pending.review !== void 0) continue;
\t\t\t\t\tcard.pending.answer({ answers }).catch(() => {});
\t\t\t\t\treturn;
\t\t\t\t}
\t\t\t});`;

/** ② client：订阅事件 → 替用户提交 */
function patchClient() {
  let t = fs.readFileSync(UQ, "utf8");
  const hasLegacy = t.includes(LEGACY_EVENT);

  if (t.includes(EVENT) && !hasLegacy) return "已打过";
  if (mode === "check") return t.includes(EVENT) ? "已打过" : "未打";

  backup(UQ);

  if (hasLegacy) {
    // 删掉旧补丁块（从注释行到配对的 "});"）
    const i = t.indexOf(`ctx.remote.$on("${LEGACY_EVENT}"`);
    if (i > 0) {
      const commentStart = t.lastIndexOf("\n\t\t\t// [phone-bridge", i);
      const endMarker = "\n\t\t\t});";
      const j = t.indexOf(endMarker, i);
      if (commentStart > 0 && j > i) {
        t = t.slice(0, commentStart) + t.slice(j + endMarker.length);
      }
    }
  }

  if (!t.includes(EVENT)) {
    if (!t.includes(ANCHOR)) return "没找到锚点（DSH 版本可能变了）";
    t = t.replace(ANCHOR, ANCHOR + "\n" + HANDLER);
  }

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
  console.log(`[patch] dsh-api-remotes             : ${patchRemotes()}`);
  console.log(`[patch] dsh-client-ui-user-questions: ${patchClient()}`);
  if (mode === "apply") console.log("[patch] 改完要重启 DSH 才生效");
}
