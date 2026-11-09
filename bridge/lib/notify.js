/**
 * 完成通知。
 *
 * 为什么不用 APNs：免费签名的 iOS 应用拿不到 Push Notifications entitlement，
 * 而 APNs 还需要一个常驻的推送证书服务。Bark / ntfy 把这件事交给手机上那个
 * 已经签好名的小 App，电脑端只发一条 HTTP 请求。
 *
 * 私密性约定：
 *   - 通知正文由调用方决定，且**只允许**出现会话短码、状态、耗时
 *   - 绝不放文件内容、命令输出、模型回复摘要
 *   - 所有请求 5 秒超时，失败静默（通知不该影响主流程）
 */

const TIMEOUT_MS = 5000;

function withTimeout(promise, ms = TIMEOUT_MS) {
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      const t = setTimeout(() => reject(new Error("notify timeout")), ms);
      t.unref?.();
    }),
  ]);
}

export function createNotifier(config = {}) {
  const kind = String(config.kind || "").trim().toLowerCase();
  const server = String(config.server || "").trim();
  const key = String(config.key || "").trim();
  const topic = String(config.topic || "").trim();
  const enabled = Boolean(kind && key);

  async function bark({ title, body, group }) {
    const root = (server || "https://api.day.app").replace(/\/+$/, "");
    const res = await withTimeout(
      fetch(`${root}/push`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          device_key: key,
          title,
          body,
          group: group || "DSH",
          level: "active",
          badge: 1,
        }),
      }),
    );
    if (!res.ok) throw new Error(`bark ${res.status}`);
  }

  async function ntfy({ title, body }) {
    const root = (server || "https://ntfy.sh").replace(/\/+$/, "");
    const target = topic || key;
    const headers = { title: encodeURIComponent(title), priority: "default" };
    if (key && topic) headers.authorization = `Bearer ${key}`;
    const res = await withTimeout(fetch(`${root}/${encodeURIComponent(target)}`, {
      method: "POST",
      headers,
      body,
    }));
    if (!res.ok) throw new Error(`ntfy ${res.status}`);
  }

  async function push(payload) {
    if (!enabled) return { skipped: "disabled" };
    try {
      if (kind === "bark") await bark(payload);
      else if (kind === "ntfy") await ntfy(payload);
      else return { skipped: `unknown kind ${kind}` };
      return { ok: true };
    } catch (error) {
      return { ok: false, error: String(error?.message || error) };
    }
  }

  return { enabled, kind, push };
}
