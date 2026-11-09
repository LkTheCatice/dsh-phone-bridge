/**
 * 受限文件访问。
 *
 * 规则（安全默认，不做"任意盘符"开口）：
 *   1. 任何路径 realpath 之后必须落在某个白名单根之内 —— 符号链接逃逸因此自动失败
 *   2. 写新文件时校验父目录（realpath 不存在会抛错）
 *   3. 分块读写，单块默认 1 MiB，单文件默认上限 512 MiB
 *   4. 拒绝设备名与 NTFS 备用数据流写法（C:、\\?\、:stream）
 */

import fsp from "node:fs/promises";
import path from "node:path";

export class FsDenied extends Error {
  constructor(message) {
    super(message);
    this.name = "FsDenied";
    this.status = 403;
  }
}

const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$/i;

function within(child, parent) {
  const rel = path.relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function looksHostile(abs) {
  if (abs.includes("\0")) return "路径含空字节";
  if (process.platform === "win32") {
    if (/^\\\\[.?]\\/.test(abs)) return "拒绝 \\\\?\\ 设备路径";
    if (/:[^\\]/.test(abs.slice(2))) return "拒绝 NTFS 备用数据流写法";
  }
  const base = path.basename(abs);
  if (WINDOWS_RESERVED.test(base)) return "拒绝 Windows 设备名";
  return null;
}

export function createSafeFs({
  roots,
  maxChunkBytes = 1024 * 1024,
  maxReadBytes = 8 * 1024 * 1024,
  maxFileBytes = 512 * 1024 * 1024,
} = {}) {
  const baseRoots = () => (typeof roots === "function" ? roots() : roots || []);

  function allowedRoots() {
    const seen = new Set();
    const out = [];
    for (const r of baseRoots()) {
      if (!r) continue;
      const abs = path.resolve(String(r));
      if (seen.has(abs)) continue;
      seen.add(abs);
      out.push(abs);
    }
    return out;
  }

  async function resolveAllowed(target, { forWrite = false } = {}) {
    if (typeof target !== "string" || !target.trim()) throw new FsDenied("缺少 path");
    const abs = path.resolve(target);
    const hostile = looksHostile(abs);
    if (hostile) throw new FsDenied(hostile);

    let real;
    try {
      real = await fsp.realpath(abs);
    } catch {
      if (!forWrite) throw new FsDenied(`路径不存在: ${target}`);
      const parent = await fsp.realpath(path.dirname(abs)).catch(() => null);
      if (!parent) throw new FsDenied(`父目录不存在: ${path.dirname(target)}`);
      real = path.join(parent, path.basename(abs));
    }

    const rootsList = allowedRoots();
    if (rootsList.length === 0) throw new FsDenied("没有配置任何允许的根目录");
    if (!rootsList.some((r) => within(real, r))) {
      throw new FsDenied(`路径不在允许的根目录内: ${target}`);
    }
    return real;
  }

  async function list(target) {
    const real = await resolveAllowed(target);
    const st = await fsp.stat(real);
    if (!st.isDirectory()) throw new FsDenied(`不是目录: ${target}`);
    const entries = await fsp.readdir(real, { withFileTypes: true });
    const out = [];
    for (const entry of entries) {
      const full = path.join(real, entry.name);
      let info = null;
      try {
        info = await fsp.lstat(full);
      } catch {
        continue;
      }
      out.push({
        name: entry.name,
        // 符号链接单独标出来：手机端可以显示，但点进去仍会被 realpath 校验
        dir: entry.isDirectory(),
        link: entry.isSymbolicLink(),
        size: entry.isFile() ? info.size : null,
        mtime: info.mtimeMs,
      });
    }
    out.sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1));
    return { path: real, entries: out };
  }

  async function statOf(target) {
    const real = await resolveAllowed(target);
    const st = await fsp.stat(real);
    return {
      path: real,
      dir: st.isDirectory(),
      size: st.size,
      mtime: st.mtimeMs,
      mode: st.mode,
    };
  }

  async function read(target, { offset = 0, limit = maxChunkBytes } = {}) {
    const real = await resolveAllowed(target);
    const st = await fsp.stat(real);
    if (!st.isFile()) throw new FsDenied(`不是文件: ${target}`);
    if (st.size > maxFileBytes) throw new FsDenied(`文件超过上限 ${maxFileBytes} 字节`);
    const start = Math.max(0, Number(offset) || 0);
    const want = Math.min(Math.max(1, Number(limit) || maxChunkBytes), maxReadBytes);
    const length = Math.max(0, Math.min(want, st.size - start));
    if (length === 0) return { buffer: Buffer.alloc(0), size: st.size, offset: start, eof: true };
    const handle = await fsp.open(real, "r");
    try {
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await handle.read(buffer, 0, length, start);
      return {
        buffer: buffer.subarray(0, bytesRead),
        size: st.size,
        offset: start,
        eof: start + bytesRead >= st.size,
      };
    } finally {
      await handle.close();
    }
  }

  async function write(target, { offset = 0, truncate = false } = {}, buffer) {
    const real = await resolveAllowed(target, { forWrite: true });
    const start = Math.max(0, Number(offset) || 0);
    if (start + buffer.length > maxFileBytes) throw new FsDenied(`超过单文件上限 ${maxFileBytes} 字节`);
    const handle = await fsp.open(real, truncate ? "w+" : "r+").catch(async (error) => {
      if (error?.code === "ENOENT") return fsp.open(real, "w+");
      throw error;
    });
    try {
      if (truncate) await handle.truncate(0);
      const { bytesWritten } = await handle.write(buffer, 0, buffer.length, start);
      const st = await handle.stat();
      return { path: real, written: bytesWritten, size: st.size, offset: start };
    } finally {
      await handle.close();
    }
  }

  return { allowedRoots, resolveAllowed, list, stat: statOf, read, write };
}
