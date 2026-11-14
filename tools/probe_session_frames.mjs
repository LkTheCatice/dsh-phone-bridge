// 用 node 自带的 zstd 解一段会话日志，检查 tool.call / turn.end 到底带不带 turn
import { readFileSync } from "node:fs";
import { zstdDecompressSync } from "node:zlib";

const file = process.argv[2];
const raw = readFileSync(file);
// 流式追加写的 zstd：逐帧解压，失败就停在能解的部分
let text = "";
try {
  text = zstdDecompressSync(raw).toString("utf8");
} catch (e) {
  // 退化：二分截断找最大可解长度
  let lo = 0, hi = raw.length;
  while (lo < hi) {
    const mid = Math.floor((lo + hi + 1) / 2);
    try { zstdDecompressSync(raw.subarray(0, mid)); lo = mid; } catch { hi = mid - 1; }
  }
  try { text = zstdDecompressSync(raw.subarray(0, lo)).toString("utf8"); } catch { text = ""; }
}

const lines = text.split("\n").filter(Boolean);
console.log("lines:", lines.length);

let tool = 0, toolWithTurn = 0, end = 0, endWithTurn = 0, think = 0, thinkWithTurn = 0;
const samples = [];
for (const line of lines) {
  let ev;
  try { ev = JSON.parse(line); } catch { continue; }
  const t = ev.type || ev.event || "";
  const d = ev.data || {};
  const hasTurn = d.turn !== undefined || ev.turn !== undefined;
  if (t === "tool/call") { tool++; if (hasTurn) toolWithTurn++; if (samples.length < 3) samples.push(["tool/call", hasTurn, d.turn]); }
  if (t === "turn/end") { end++; if (hasTurn) endWithTurn++; if (samples.length < 6) samples.push(["turn/end", hasTurn, d.turn]); }
  if (t === "assistant/message") { const parts = d.content || d.parts || d.message?.content || []; const hasReason = JSON.stringify(parts).includes("reasoning"); if (hasReason) { think++; if (hasTurn) thinkWithTurn++; } }
}
console.log({ tool, toolWithTurn, end, endWithTurn, think, thinkWithTurn });
console.log("samples:", JSON.stringify(samples));
