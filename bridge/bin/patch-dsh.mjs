#!/usr/bin/env node
/**
 * 给 DSH 打「提问远程提交」补丁。
 *
 * 为什么需要：
 *   手机选了答案之后，必须由**桌面端自己按下「提交」**，DSH 才会按原生流程
 *   结算提问、收起面板、广播 tool.result。桥拿不到那个按钮，只能通过一个
 *   自定义 Remote 事件请前端代按。
 *
 * 改什么：
 *   ① dsh-api-remotes/lib/index.js        把 phone-bridge/ask-submit 加入转发白名单
 *   ② dsh-client-ui-user-questions/lib/client.js
 *      订阅该事件 → card.pending.answer({ answers })（和点按钮同一条路径）
 *
 * 用法：
 *   node bin/patch-dsh.mjs           打补丁（幂等）
 *   node bin/patch-dsh.mjs --check   只看状态
 *   node bin/patch-dsh.mjs --revert  从备份还原
 *
 * DSH 升级会覆盖这两个文件，重新跑一次即可（doctor 也会提醒）。
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const EVENT = "phone-bridge/ask-submit";
const LEGACY_EVENT = "phone-bridge/ask-settled";

const CANDIDATES = [
  path.join(
    process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
    "Programs",
    "DeepSeek Harness",
    "resources",
    "app",
    "dsh",
    "node_modules",
    "@deepseek-ai",
  ),
  "C:/Program Files/DeepSeek Harness/resources/app/dsh/node_modules/@deepseek-ai",
];

export function findDshPluginRoot() {
  for (const root of CANDIDATES) {
    if (fs.existsSync(path.join(root, "dsh-api-remotes", "lib", "index.js"))) return root;
  }
  return null;
}

export const PATCH_TARGETS = () => {
  const root = findDshPluginRoot();
  if (!root) return null;
  return {
    root,
    remotes: path.join(root, "dsh-api-remotes", "lib", "index.js"),
    client: path.join(root, "dsh-client-ui-user-questions", "lib", "client.js"),
  };
};

/** 只读检查：返回 { remotes: bool, client: bool } */
export function patchStatus() {
  const t = PATCH_TARGETS();
  if (!t) return null;
  const read = (p) => fs.readFileSync(p, "utf8");
  return {
    remotes: read(t.remotes).includes(`event: "${EVENT}"`),
    client: read(t.client).includes(`ctx.remote.$on("${EVENT}"`),
    legacy: read(t.client).includes(LEGACY_EVENT),
  };
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

function patchRemotes(file, mode) {
  let t = fs.readFileSync(file, "utf8");
  const hasNew = t.includes(`event: "${EVENT}"`);
  const hasLegacy = t.includes(`event: "${LEGACY_EVENT}"`);
  if (hasNew && !hasLegacy) return "已打过";
  if (mode === "check") return hasNew ? "已打过" : "未打";

  backup(file);
  if (hasLegacy) {
    t = t.replace(
      new RegExp(`\\{\\s*event: "${LEGACY_EVENT}",\\s*mode: "emit"\\s*\\}`),
      `{\n\t\tevent: "${EVENT}",\n\t\tmode: "emit"\n\t}`,
    );
  }
  if (!t.includes(`event: "${EVENT}"`)) {
    const m = t.match(/(\{\s*event: "user-questions\/request",\s*mode: "waterfall"\s*\})\s*\];/);
    if (!m) return "没找到锚点（DSH 版本可能变了）";
    t = t.replace(m[0], `${m[1]},\n\t{\n\t\tevent: "${EVENT}",\n\t\tmode: "emit"\n\t}\n];`);
  }
  fs.writeFileSync(file, t);
  return "已打";
}

function patchClient(file, mode) {
  let t = fs.readFileSync(file, "utf8");
  const hasLegacy = t.includes(LEGACY_EVENT);
  if (t.includes(EVENT) && !hasLegacy) return "已打过";
  if (mode === "check") return t.includes(EVENT) ? "已打过" : "未打";

  backup(file);

  if (hasLegacy) {
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

  fs.writeFileSync(file, t);
  return "已打";
}

function revert() {
  const t = PATCH_TARGETS();
  if (!t) {
    console.log("[patch] 找不到 DSH 安装目录");
    return;
  }
  for (const file of [t.remotes, t.client]) {
    const bak = newestBackup(file);
    if (!bak) {
      console.log(`[revert] ${path.basename(file)}: 没有备份`);
      continue;
    }
    fs.copyFileSync(bak, file);
    console.log(`[revert] ${path.basename(file)} ← ${path.basename(bak)}`);
  }
}

/** 命令行入口：direct 调用和 tools/patch-dsh-ask.mjs 转发都用它 */
export function main(argv = process.argv.slice(2)) {
  const mode = argv.includes("--revert") ? "revert" : argv.includes("--check") ? "check" : "apply";

  if (mode === "revert") {
    revert();
    return 0;
  }

  const t = PATCH_TARGETS();
  if (!t) {
    console.error("[patch] 找不到 DSH 安装目录");
    return 1;
  }
  console.log(`[patch] DSH: ${t.root}`);
  console.log(`[patch] dsh-api-remotes             : ${patchRemotes(t.remotes, mode)}`);
  console.log(`[patch] dsh-client-ui-user-questions: ${patchClient(t.client, mode)}`);
  if (mode === "apply") console.log("[patch] 改完要重启 DSH 才生效");
  return 0;
}

// 直接 `node bin/patch-dsh.mjs` 时自动执行
if (process.argv[1] && path.basename(process.argv[1]) === "patch-dsh.mjs") {
  process.exit(main());
}
