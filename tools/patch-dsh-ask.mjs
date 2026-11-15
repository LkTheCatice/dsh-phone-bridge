#!/usr/bin/env node
/**
 * 兼容入口：真正的实现在 bridge/bin/patch-dsh.mjs（随插件包一起发布）。
 * 老文档里写的是 tools/patch-dsh-ask.mjs，这里转发一下，避免命令失效。
 */
import { main } from "../bridge/bin/patch-dsh.mjs";

process.exit(main());
