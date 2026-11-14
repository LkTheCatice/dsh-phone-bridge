// 单独验证路径脱敏正则（从 index.js 里抄同一份）
const PATH_RE = /(?:[A-Za-z]:[\\/]|\\{2}[^\s"']+[\\/])(?:[^\s"'<>|*?\r\n]+[\\/])*([^\s"'<>|*?\r\n\\/]+)/g;

function redactPaths(value) {
  if (typeof value === "string") {
    return value.replace(PATH_RE, (_m, base) => (base ? "…/" + base : "…"));
  }
  if (Array.isArray(value)) return value.map(redactPaths);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = redactPaths(v);
    return out;
  }
  return value;
}

const cases = [
  { step: "fs/read", path: "D:\\Documents\\deepseek-harness\\default-workspace\\phone-dsh\\bridge\\index.js" },
  { step: "preview", err: "C:\\Users\\acer\\Desktop\\千问1生图\\夜景_01.png 读不到" },
  { step: "forward", path: "D:/Documents/x/y.ipa", note: "顺便看下" },
  { step: "session/new", cwd: "(default workspace)", requested: null },
  { step: "plain", value: "没有路径的一段中文" },
];

for (const c of cases) {
  console.log(JSON.stringify(redactPaths(c)));
}
