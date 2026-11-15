#!/usr/bin/env node
/**
 * 一键体检：把「装完到底能不能用」的每一项都打出来。
 *
 * 用法：node bin/doctor.mjs
 *
 * 检查项：
 *   ① DSH 安装目录 / 版本
 *   ② 插件是否装进 profile（junction 或复制）
 *   ③ profile 配置里有没有 phone-bridge 那一行
 *   ④ DSH 两个关键文件是否被升级覆盖（提问补丁）
 *   ⑤ 桥的端口是否在监听 / 配对文件是否有效
 *   ⑥ 通知推送是否配置（决定锁屏能否收到）
 *   ⑦ 手机最近一次上报的 build（判断 App 版本）
 */

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { patchStatus, PATCH_TARGETS } from "./patch-dsh.mjs";

const HOME = process.env.USERPROFILE || os.homedir();
const DSH_HOME = process.env.DSH_HOME || path.join(HOME, ".dsh");
const PROFILE = path.join(DSH_HOME, "profiles", "desktop");
const PROFILE_PKG = path.join(PROFILE, "package.json");
const PROFILE_PATCH = path.join(PROFILE, "cordis.patch.yml");
const LINK = path.join(PROFILE, "node_modules", "dsh-phone-bridge");

const rows = [];
function line(ok, label, detail = "") {
  rows.push({ ok, label, detail });
}

const MARK = { true: "✓", false: "✗", null: "○" };

// ① DSH 目录
const dshApp = path.join(process.env.LOCALAPPDATA || "", "Programs", "DeepSeek Harness");
const dshAppOk = fs.existsSync(dshApp);
line(dshAppOk, "DSH 安装", dshAppOk ? dshApp : "没找到（或装在别处）");

const targets = PATCH_TARGETS();
line(Boolean(targets), "DSH 插件目录", targets ? targets.root : "找不到 @deepseek-ai");

// ② 插件是否装进 profile
let linkInfo = "未安装";
let linkOk = false;
if (fs.existsSync(LINK)) {
  const st = fs.lstatSync(LINK);
  linkOk = true;
  linkInfo = st.isSymbolicLink() || st.isJunction?.() ? "junction（跟源码联动）" : "复制目录";
}
line(linkOk, "插件已装进 profile", linkInfo);

// ③ profile 配置
let cfgOk = false;
let cfgDetail = "没有 cordis.patch.yml";
if (fs.existsSync(PROFILE_PATCH)) {
  const cfg = fs.readFileSync(PROFILE_PATCH, "utf8");
  cfgOk = cfg.includes("phone-bridge");
  cfgDetail = cfgOk ? "有 phone-bridge 配置" : "缺 phone-bridge 配置段";
}
line(cfgOk, "profile 配置", cfgDetail);

let bundleOk = false;
if (fs.existsSync(PROFILE_PKG)) {
  try {
    const pkg = JSON.parse(fs.readFileSync(PROFILE_PKG, "utf8"));
    bundleOk = (pkg?.dsh?.profile?.bundles || []).includes("dsh-phone-bridge");
  } catch {}
}
line(bundleOk, "bundles 里已登记", bundleOk ? "dsh-phone-bridge" : "没登记 → 不会加载");

// ④ 提问补丁
const st = patchStatus();
if (!st) {
  line(null, "提问补丁", "无法检查（DSH 目录缺失）");
} else {
  const ok = st.remotes && st.client;
  line(ok, "提问补丁（手机提交）", ok ? "已打" : `remotes=${st.remotes} client=${st.client}${st.legacy ? " 有旧版残留" : ""}`);
  if (!ok) rows.push({ ok: null, label: "  ↳ 修复", detail: "node bin/patch-dsh.mjs（改完重启 DSH）" });
}

// ⑤ 端口 + 配对
function probePort(port) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: "127.0.0.1", port }, () => {
      sock.destroy();
      resolve(true);
    });
    sock.on("error", () => resolve(false));
    sock.setTimeout(1200, () => {
      sock.destroy();
      resolve(false);
    });
  });
}

// 从 profile 配置里读端口与 stateDir
let port = 8765;
let stateDir = null;
if (fs.existsSync(PROFILE_PATCH)) {
  const cfg = fs.readFileSync(PROFILE_PATCH, "utf8");
  const mp = cfg.match(/^\s*port:\s*(\d+)/m);
  if (mp) port = Number(mp[1]);
  const md = cfg.match(/^\s*stateDir:\s*['"]?([^'"\r\n]+)['"]?/m);
  if (md) stateDir = md[1].trim();
}
const listening = await probePort(port);
line(listening, "桥端口", listening ? `127.0.0.1:${port} 在监听` : `127.0.0.1:${port} 没监听（DSH 没开？）`);

const pairPath = path.join(stateDir || path.join(HOME, ".dsh", "phone-bridge"), "pair.json");
let pairOk = false;
let pairDetail = `没有 ${pairPath}`;
if (fs.existsSync(pairPath)) {
  try {
    const pair = JSON.parse(fs.readFileSync(pairPath, "utf8"));
    pairOk = typeof pair.token === "string" && pair.token.length > 20;
    pairDetail = pairOk ? `token ${pair.token.slice(0, 6)}…（${(pair.clients || []).length} 台设备）` : "token 异常";
  } catch (error) {
    pairDetail = `解析失败：${error.message}`;
  }
}
line(pairOk, "配对凭据", pairDetail);

// ⑥ 通知推送
let notifyDetail = "未配置 → 手机锁屏时收不到提问";
let notifyOk = null;
if (fs.existsSync(PROFILE_PATCH)) {
  const cfg = fs.readFileSync(PROFILE_PATCH, "utf8");
  const kind = cfg.match(/kind:\s*"([^"]*)"/g) || [];
  const hasKind = kind.some((k) => !/kind:\s*""/.test(k));
  if (hasKind) {
    notifyOk = true;
    notifyDetail = "已配置";
  }
}
line(notifyOk, "通知推送", notifyDetail);

// ⑦ 手机 build（从桥日志里捞最后一行）
let buildDetail = "日志里没有 build= 记录（手机没连过？）";
let buildOk = null;
const logPath = path.join(stateDir || path.join(HOME, ".dsh", "phone-bridge"), "bridge.log");
if (fs.existsSync(logPath)) {
  const tail = fs.readFileSync(logPath, "utf8").split("\n").slice(-800).reverse();
  for (const l of tail) {
    const m = l.match(/"d":"build=([^"\s]+)/);
    if (m) {
      buildOk = true;
      buildDetail = m[1];
      break;
    }
  }
}
line(buildOk, "手机 App 版本", buildDetail);

// 输出
const width = Math.max(...rows.map((r) => r.label.length)) + 2;
console.log("");
console.log("dsh-phone-bridge doctor");
console.log("─".repeat(width + 40));
for (const r of rows) {
  const mark = MARK[String(r.ok)];
  console.log(`${mark} ${r.label.padEnd(width)}${r.detail}`);
}
console.log("─".repeat(width + 40));

const failed = rows.filter((r) => r.ok === false).length;
console.log(failed === 0 ? "全部通过。" : `${failed} 项需要处理。`);
console.log("");
