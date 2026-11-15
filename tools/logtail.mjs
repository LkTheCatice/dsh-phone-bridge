#!/usr/bin/env node
/**
 * 用**本地时间**看桥日志。
 *
 * 起因：bridge.log 里的时间是 UTC（"at":"2026-11-15T11:03:26.725Z"），
 * 而手机上显示的是本地时间 —— 差了 8 小时，回看时很容易把先后顺序搞反
 * （实拍：把 19:03 的手机提交误认为"11:03，重构之前"）。
 *
 * 用法：
 *   node tools/logtail.mjs                 # 最近 40 条，本地时间
 *   node tools/logtail.mjs 80              # 最近 80 条
 *   node tools/logtail.mjs 40 ask          # 只看 step/路径里含 "ask" 的
 *   node tools/logtail.mjs 40 approval dev # 多个关键词（任一命中）
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = process.env.USERPROFILE || os.homedir();
const LOG = process.env.DSH_BRIDGE_LOG
  || path.join("D:\\Documents\\deepseek-harness\\dsh-phone-bridge", "bridge.log")
  || path.join(HOME, ".dsh", "phone-bridge", "bridge.log");

const limit = Number(process.argv[2]) || 40;
const filters = process.argv.slice(3).map((s) => s.toLowerCase());

if (!fs.existsSync(LOG)) {
  console.error("找不到日志：", LOG);
  process.exit(1);
}

const lines = fs.readFileSync(LOG, "utf8").split("\n").filter(Boolean);

function localTime(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const p = (n, w = 2) => String(n).padStart(w, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function describe(obj) {
  const step = obj.step || "";
  const p = obj.p || "";
  const bits = [];
  if (step) bits.push(step);
  if (p) bits.push(`${obj.m || ""} ${p} ${obj.s ?? ""}`.trim());
  if (obj.d) bits.push(String(obj.d));
  if (obj.msg) bits.push(String(obj.msg));
  if (obj.err) bits.push(String(obj.err));
  if (obj.sessions !== undefined) bits.push(`sessions=${obj.sessions}`);
  if (obj.emitted !== undefined) bits.push(`emitted=${obj.emitted}`);
  if (obj.counts) bits.push(JSON.stringify(obj.counts));
  return bits.join("  ") || JSON.stringify(obj).slice(0, 160);
}

const out = [];
for (const line of lines.slice(-Math.max(limit * 4, 200))) {
  let obj;
  try {
    obj = JSON.parse(line);
  } catch {
    out.push(`        (raw) ${line.slice(0, 160)}`);
    continue;
  }
  const text = describe(obj);
  if (filters.length && !filters.some((f) => text.toLowerCase().includes(f))) continue;
  out.push(`${localTime(obj.at)}  ${text}`);
}

console.log(out.slice(-limit).join("\n"));
console.log(`\n（本地时间 · 共显示 ${Math.min(out.length, limit)} 条 · 源文件 ${path.basename(LOG)}）`);
