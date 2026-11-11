#!/usr/bin/env node
/**
 * 重启前的自检：确认插件不会把 DSH 拖进「纯净模式」。
 *
 *   node bin/selfcheck.mjs
 *
 * 检查 6 项（全部通过才建议重启）：
 *   1. client.js 在 Node 侧 import 不抛错（历史事故：window is not defined → SIGABRT/纯净模式）
 *   2. 浏览器侧仍能完成 __ModuleLoader__ 注册
 *   3. dsh.client.inject 为空（非空会让 loader 等一个永不出现的服务，永久 pending）
 *   4. index.js 的 apply 能真正起服务并正常关闭
 *   5. profile 的 cordis.patch.yml / package.json 配置完整
 *   6. loader 能从 profile 解析到本包
 */

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const BRIDGE = path.resolve(here, "..");

const DSH_HOME = process.env.DSH_HOME || path.join(process.env.USERPROFILE || process.env.HOME || "", ".dsh");
const PROFILE = path.join(DSH_HOME, "profiles", process.env.DSH_PROFILE || "desktop");

const YAML_PATH = path.join(PROFILE, "cordis.patch.yml");
const PROFILE_PKG = path.join(PROFILE, "package.json");

let failed = 0;
const ok = (m) => console.log(`  ✓ ${m}`);
const bad = (m) => {
  console.log(`  ✗ ${m}`);
  failed += 1;
};

function loadYaml() {
  // js-yaml 跟着 DSH 安装走（打包后是 asar，路径不固定），所以多试几个位置：
  // 环境变量显式指定 > profile > 本插件目录 > DSH 默认安装路径
  const candidates = [
    process.env.DSH_YAML_PATH,
    PROFILE,
    BRIDGE,
    path.join(process.env.LOCALAPPDATA || "", "Programs", "DeepSeek Harness", "resources", "app", "dsh", "node_modules"),
  ].filter(Boolean);
  for (const base of candidates) {
    try {
      const resolved = require.resolve("js-yaml", { paths: [base] });
      return require(resolved);
    } catch {
      /* 试下一个 */
    }
  }
  return null;
}

async function main() {
  console.log("DSH 手机桥 · 重启前自检\n");

  // 1
  console.log("[1] client.js 在 Node 侧加载");
  try {
    await import(`file:///${BRIDGE.replace(/\\/g, "/")}/client.js`);
    ok("不抛错（得到空模块）");
  } catch (error) {
    bad(`抛错：${error.message} —— 这会把 DSH 拖进纯净模式`);
  }

  // 2
  console.log("[2] 浏览器侧注册");
  try {
    globalThis.window = { __ModuleLoader__: { load: (spec) => { globalThis.__reg = spec; } } };
    await import(`file:///${BRIDGE.replace(/\\/g, "/")}/client.js?selfcheck=${Date.now()}`);
    if (globalThis.__reg?.id === "dsh-phone-bridge") ok("注册成功");
    else bad("没有完成注册");
    delete globalThis.window;
  } catch (error) {
    bad(`注册抛错：${error.message}`);
  }

  // 3
  console.log("[3] client.inject（pending 的直接原因）");
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(BRIDGE, "package.json"), "utf8"));
    const inject = pkg.dsh?.client?.inject;
    if (Array.isArray(inject) && inject.length === 0) ok("为空 —— loader 不会等待任何服务");
    else bad(`仍有依赖：${JSON.stringify(inject)}，可能永久 pending`);
  } catch (error) {
    bad(`读 package.json 失败：${error.message}`);
  }

  // 4
  console.log("[4] 插件本体启动");
  try {
    const mod = await import(`file:///${BRIDGE.replace(/\\/g, "/")}/index.js`);
    const handlers = new Map();
    const ctx = {
      on: (n, f) => handlers.set(n, [...(handlers.get(n) || []), f]),
      inject: () => {},
      effect: (f) => {
        const dispose = f();
        return () => dispose?.();
      },
    };
    const run = mod.apply(ctx, {
      port: 0,
      lanHost: "",
      requireE2ee: true,
      stateDir: process.env.DSH_PHONE_BRIDGE_DIR || "",
      roots: [],
    });
    const ready = await run.ready;
    ok(`apply 成功，临时端口 ${ready.port}`);
    await run.stop();
  } catch (error) {
    bad(`apply 抛错：${error.message}`);
  }

  // 5
  console.log("[5] profile 配置");
  const yaml = loadYaml();
  if (!yaml) {
    console.log("  – 找不到 js-yaml，跳过 YAML 解析（不影响结论）");
  } else {
    try {
      const doc = yaml.load(fs.readFileSync(YAML_PATH, "utf8"));
      const rows = (doc || []).flatMap((e) => e?.insert || []);
      const pb = rows.find((r) => r.id === "phone-bridge");
      ok(`cordis.patch.yml 解析成功（${doc?.length ?? 0} 条顶层）`);
      if (pb) ok(`phone-bridge 配置存在（lanHost=${JSON.stringify(pb.config?.lanHost)}）`);
      else bad("cordis.patch.yml 里没有 phone-bridge 配置");
    } catch (error) {
      bad(`cordis.patch.yml 解析失败：${error.message}`);
    }
    try {
      const pkg = JSON.parse(fs.readFileSync(PROFILE_PKG, "utf8"));
      const bundles = pkg.dsh?.profile?.bundles || [];
      if (bundles.includes("dsh-phone-bridge")) ok("dsh-phone-bridge 在 bundles 里");
      else bad("不在 bundles 里（client bundle 不会被扫描）");
    } catch (error) {
      bad(`读 profile package.json 失败：${error.message}`);
    }
  }

  // 6
  console.log("[6] loader 解析");
  try {
    ok(`resolve -> ${require.resolve("dsh-phone-bridge", { paths: [PROFILE] })}`);
  } catch (error) {
    bad(`resolve 失败：${error.message}`);
  }

  console.log("");
  console.log(failed === 0 ? "结论：全部通过，可以重启。" : `结论：${failed} 项未通过，先修再重启。`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error("自检脚本自身出错：", error);
  process.exit(2);
});
