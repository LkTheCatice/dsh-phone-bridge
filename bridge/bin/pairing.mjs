#!/usr/bin/env node
/**
 * 打印配对串（或轮换 token）。
 *
 *   node bin/pairing.mjs                            # 默认 127.0.0.1:8765
 *   node bin/pairing.mjs 192.168.124.27 8765        # 手机会用的地址
 *   node bin/pairing.mjs --rotate                   # 轮换 token（旧手机立即失效）
 *   node bin/pairing.mjs --json                     # 机器可读输出
 *
 * 状态目录优先级：$DSH_PHONE_BRIDGE_DIR > cordis.patch.yml 里的 stateDir > ~/.dsh/phone-bridge
 * 注意：这里只读不建。凭据不存在时会提示先重启 DSH，而不是悄悄生成一套新的
 * （那样会把正在运行的实例顶掉）。
 */

import { readPairState, rotateToken, stateDir } from "../lib/store.js";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith("--")));
const positional = args.filter((a) => !a.startsWith("--"));

if (flags.has("--rotate")) {
  const existing = readPairState();
  if (!existing) {
    console.error(`[phone-bridge] 找不到凭据（${stateDir()}\\pair.json），先重启一次 DSH 让它生成。`);
    process.exit(1);
  }
  rotateToken();
  console.error("[phone-bridge] token 已轮换，所有已配对手机需要重新配对");
}

const state = readPairState();
if (!state) {
  console.error(`[phone-bridge] 找不到配对凭据：${stateDir()}\\pair.json`);
  console.error("  1. 确认插件已装并重启过 DSH（凭据由运行中的实例生成）");
  console.error("  2. 确认 cordis.patch.yml 里的 stateDir 指向这个目录");
  console.error("  3. 或设置环境变量 DSH_PHONE_BRIDGE_DIR 指向正确目录");
  process.exit(1);
}

// 不带 host 参数时自动探测局域网 IP：
// 以前默认 127.0.0.1，手机扫出来的二维码指向它自己，永远连不上。
function detectLanIp() {
  // 挑第一个"像物理网卡"的 IPv4（跳过 loopback / 虚拟网卡 / 169.254 自分配）
  try {
    const os = require("node:os");
    const all = os.networkInterfaces() || {};
    const skip = /(loopback|vmware|virtualbox|vethernet|hyper-v|docker|wsl|tap|tun|bluetooth)/i;
    const prefer = /(wi-?fi|wlan|以太网|ethernet|en0|eth)/i;
    const candidates = [];
    for (const [name, list] of Object.entries(all)) {
      if (!list || skip.test(name)) continue;
      for (const item of list) {
        if (!item || item.family !== "IPv4" || item.internal) continue;
        const ip = String(item.address || "");
        if (!ip || ip.startsWith("127.") || ip.startsWith("169.254.")) continue;
        candidates.push({ ip, preferred: prefer.test(name) ? 1 : 0 });
      }
    }
    candidates.sort((a, b) => b.preferred - a.preferred);
    return candidates[0]?.ip || "127.0.0.1";
  } catch {
    return "127.0.0.1";
  }
}

const host = positional[0] || detectLanIp();
const port = positional[1] || "8765";

const uri = `dshnb://pair?host=${encodeURIComponent(host)}&port=${encodeURIComponent(port)}&token=${encodeURIComponent(state.token)}&fp=${encodeURIComponent(state.fingerprint)}`;

if (flags.has("--json")) {
  console.log(
    JSON.stringify(
      {
        uri,
        host,
        port: Number(port),
        token: state.token,
        fingerprint: state.fingerprint,
        stateDir: state.stateDir,
        createdAt: state.createdAt,
        clients: state.clients,
      },
      null,
      2,
    ),
  );
} else {
  console.log(uri);
  console.error("");
  console.error(`服务器公钥指纹：${state.fingerprint}`);
  console.error(`状态目录：      ${state.stateDir}`);
  console.error(`首次配对时间：  ${state.createdAt}`);
  console.error(
    state.clients.length
      ? `已连接过的手机：${state.clients.map((c) => `${c.name}(${String(c.fingerprint).slice(0, 8)})`).join(", ")}`
      : "还没有任何手机连过（首次连接会被记入名单）",
  );
  console.error("");
  console.error("手机 App → 配对 → 粘贴上面这串即可。");
  console.error("要踢掉所有已登记设备：node bin/pairing.mjs --rotate（连 token 一起换）");
}
