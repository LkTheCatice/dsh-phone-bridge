/**
 * dsh-phone-bridge —— 浏览器半边：在「设置」里加一页「手机设备」。
 *
 * client bundle 不是 ESM，是自注册脚本（照 dsh-bili-scroll 的既有约定）：
 *   window.__ModuleLoader__.load({ id: '<包名>', factory: (require) => ({ inject, apply }) })
 *
 * ⚠️ 为什么整个文件包在 IIFE 里并检查 window：
 *    DSH 的 client bundle 扫描会在 **Node 侧** 加载这个文件。直接写
 *    `window.__ModuleLoader__.load(...)` 会抛 ReferenceError: window is not defined，
 *    把整个 profile 拖进纯净模式。加守卫后 Node 侧只得到空模块，浏览器侧照常注册。
 *
 * 界面读的是本机 8765 的管理接口（只允许回环访问，手机与局域网一律 403）。
 */
;(() => {
  if (typeof window === 'undefined') return
  const loader = window.__ModuleLoader__
  if (!loader || typeof loader.load !== 'function') return

  loader.load({
    id: 'dsh-phone-bridge',
    factory: (require) => {
    const React = require('react')
    const h = React.createElement

    const ORIGIN = 'http://127.0.0.1:8765'

    const s = {
      wrap: { padding: '4px 2px', fontSize: 13, lineHeight: 1.6 },
      row: { display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', borderRadius: 10, border: '1px solid rgba(128,128,128,.22)', marginBottom: 8, background: 'rgba(128,128,128,.05)' },
      rowPending: { borderColor: 'rgba(230,160,40,.55)', background: 'rgba(230,160,40,.10)' },
      name: { fontWeight: 600 },
      muted: { opacity: 0.62, fontSize: 12 },
      mono: { fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 11, opacity: 0.72 },
      dot: (on) => ({ width: 8, height: 8, borderRadius: 4, background: on ? '#35c06a' : 'rgba(128,128,128,.45)', flex: '0 0 auto' }),
      btn: { padding: '4px 12px', borderRadius: 8, border: '1px solid rgba(128,128,128,.35)', background: 'transparent', cursor: 'pointer', fontSize: 12 },
      btnPrimary: { padding: '4px 12px', borderRadius: 8, border: 'none', background: '#2f6bff', color: '#fff', cursor: 'pointer', fontSize: 12 },
      btnDanger: { padding: '4px 12px', borderRadius: 8, border: '1px solid rgba(220,70,70,.5)', background: 'transparent', color: '#d84646', cursor: 'pointer', fontSize: 12 },
      section: { marginTop: 18, marginBottom: 6, fontWeight: 600 },
      badge: { fontSize: 11, padding: '1px 7px', borderRadius: 20, background: 'rgba(128,128,128,.18)' },
    }

    async function call(path, body) {
      const res = await fetch(ORIGIN + path, body === undefined ? { credentials: 'omit' } : {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      })
      if (res.status === 204) return {}
      const text = await res.text()
      let data = {}
      try {
        data = text ? JSON.parse(text) : {}
      } catch {
        throw new Error('HTTP ' + res.status)
      }
      if (!res.ok) throw new Error(data.message || ('HTTP ' + res.status))
      return data
    }

    const fmt = (iso) => {
      if (!iso) return '—'
      const d = new Date(iso)
      if (Number.isNaN(d.getTime())) return '—'
      const diff = Date.now() - d.getTime()
      if (diff < 60000) return '刚刚'
      if (diff < 3600000) return Math.floor(diff / 60000) + ' 分钟前'
      if (diff < 86400000) return Math.floor(diff / 3600000) + ' 小时前'
      return d.toLocaleDateString() + ' ' + d.toLocaleTimeString().slice(0, 5)
    }

    function Panel() {
      const [data, setData] = React.useState(null)
      const [error, setError] = React.useState(null)
      const [busy, setBusy] = React.useState('')

      const load = React.useCallback(async () => {
        try {
          setData(await call('/admin/devices'))
          setError(null)
        } catch (e) {
          setError(String(e.message || e))
        }
      }, [])

      React.useEffect(() => {
        load()
        const timer = setInterval(load, 5000)
        return () => clearInterval(timer)
      }, [load])

      const act = async (key, fn) => {
        setBusy(key)
        try {
          await fn()
          await load()
        } catch (e) {
          setError(String(e.message || e))
        }
        setBusy('')
      }

      if (error) {
        return h('div', { style: s.wrap }, [
          h('div', { key: 'e', style: { color: '#d84646', marginBottom: 8 } }, '读不到设备列表：' + error),
          h('div', { key: 'h', style: s.muted }, '确认 DeepSeek Harness 里 phone-bridge 插件已加载、端口是 8765，然后点刷新。'),
          h('button', { key: 'b', style: s.btn, onClick: load }, '刷新'),
        ])
      }
      if (!data) return h('div', { style: s.wrap }, '读取中…')

      const devices = data.devices || []
      const pending = devices.filter((d) => d.status === 'pending')
      const approved = devices.filter((d) => d.status === 'approved')
      const blocked = devices.filter((d) => d.status === 'blocked')

      const deviceRow = (d) => h('div', { key: d.fingerprint, style: d.status === 'pending' ? Object.assign({}, s.row, s.rowPending) : s.row }, [
        h('div', { key: 'dot', style: s.dot(d.online) }),
        h('div', { key: 'main', style: { flex: 1, minWidth: 0 } }, [
          h('div', { key: 'n', style: s.name }, [
            d.name,
            d.online ? h('span', { key: 'on', style: Object.assign({}, s.badge, { marginLeft: 8, color: '#1f9a52' }) }, '在线') : null,
            d.status === 'pending' ? h('span', { key: 'p', style: Object.assign({}, s.badge, { marginLeft: 8, color: '#b57811' }) }, '待批准') : null,
            d.status === 'blocked' ? h('span', { key: 'b', style: Object.assign({}, s.badge, { marginLeft: 8, color: '#d84646' }) }, '已拉黑') : null,
          ].filter(Boolean)),
          h('div', { key: 'f', style: s.mono }, '指纹 ' + String(d.fingerprint).slice(0, 16) + '…'),
          h('div', { key: 't', style: s.muted }, '首次 ' + fmt(d.firstSeen) + ' · 最近 ' + fmt(d.lastSeen)),
        ]),
        h('div', { key: 'actions', style: { display: 'flex', gap: 6, flex: '0 0 auto' } }, [
          d.status !== 'approved'
            ? h('button', {
                key: 'ok',
                style: s.btnPrimary,
                disabled: busy === d.fingerprint,
                onClick: () => act(d.fingerprint, () => call('/admin/devices/status', { fingerprint: d.fingerprint, status: 'approved' })),
              }, '允许')
            : null,
          d.status === 'approved'
            ? h('button', {
                key: 'block',
                style: s.btnDanger,
                disabled: busy === d.fingerprint,
                onClick: () => act(d.fingerprint, () => call('/admin/devices/status', { fingerprint: d.fingerprint, status: 'blocked' })),
              }, '拉黑')
            : null,
          h('button', {
            key: 'del',
            style: s.btn,
            disabled: busy === d.fingerprint,
            onClick: () => act(d.fingerprint, () => call('/admin/devices/remove', { fingerprint: d.fingerprint })),
          }, '删除'),
        ].filter(Boolean)),
      ])

      return h('div', { style: s.wrap }, [
        h('div', { key: 'sum', style: { display: 'flex', gap: 16, flexWrap: 'wrap', marginBottom: 6 } }, [
          h('span', { key: 'a' }, '已连接 ' + data.onlineCount + ' 台'),
          h('span', { key: 'b' }, '已批准 ' + approved.length + ' 台'),
          pending.length ? h('span', { key: 'c', style: { color: '#b57811' } }, '待批准 ' + pending.length + ' 台') : null,
        ].filter(Boolean)),

        h('label', { key: 'auto', style: { display: 'flex', alignItems: 'center', gap: 8, margin: '10px 0 4px' } }, [
          h('input', {
            key: 'cb',
            type: 'checkbox',
            checked: !!data.autoApprove,
            onChange: (e) => act('auto', () => call('/admin/settings', { autoApprove: e.target.checked })),
          }),
          h('span', { key: 't' }, '自动批准新设备'),
          h('span', { key: 'h', style: s.muted }, data.autoApprove ? '（有风险：任何拿到配对串的设备都能直接连）' : '（推荐：新设备必须在这里点允许）'),
        ]),

        pending.length ? h('div', { key: 'pend' }, [
          h('div', { key: 'h', style: s.section }, '等待你的批准'),
          ...pending.map(deviceRow),
        ]) : null,

        h('div', { key: 'appr' }, [
          h('div', { key: 'h', style: s.section }, '已批准的设备'),
          approved.length ? approved.map(deviceRow) : h('div', { key: 'none', style: s.muted }, '还没有任何设备'),
        ]),

        blocked.length ? h('div', { key: 'blk' }, [
          h('div', { key: 'h', style: s.section }, '已拉黑'),
          ...blocked.map(deviceRow),
        ]) : null,

        h('div', { key: 'srv', style: { marginTop: 22 } }, [
          h('div', { key: 'h', style: s.section }, '这台电脑'),
          h('div', { key: 'f', style: s.mono }, '公钥指纹 ' + (data.server.fingerprint || '—')),
          h('div', { key: 'p', style: s.muted }, '端口 ' + data.server.port + (data.server.lanHost ? ' · 局域网 ' + data.server.lanHost : ' · 仅回环（Tailscale 模式）')),
          h('div', { key: 'd', style: Object.assign({}, s.muted, { wordBreak: 'break-all' }) }, '状态目录 ' + data.server.stateDir),
          h('div', { key: 'e', style: s.muted }, '端到端加密：' + (data.server.e2eeRequired ? '强制开启' : '已关闭')),
        ]),

        h('div', { key: 'danger', style: { marginTop: 20, paddingTop: 14, borderTop: '1px solid rgba(128,128,128,.2)' } }, [
          h('div', { key: 'h', style: s.section }, '危险操作'),
          h('button', {
            key: 'rot',
            style: s.btnDanger,
            disabled: busy === 'rotate',
            onClick: () => act('rotate', () => call('/admin/rotate-token', {})),
          }, '轮换配对 token'),
          h('div', { key: 'note', style: Object.assign({}, s.muted, { marginTop: 6 }) }, '换 token 后所有手机都要重新配对；怀疑配对串外泄时用它。'),
        ]),
      ].filter(Boolean))
    }

    return {
      // cordis 的 inject 收的是**服务名**，不是包名。
      // 写包名 → 服务永远不会 ready → 这个 entry 永久 pending
      // → web boot 直接 "1 entry did not activate"，整个界面卡在「已停止」。
      // 包里要的 slots 由 dsh-client-ui-settings-plugins 提供，这里只声明 slots。
      inject: ['slots'],
      apply(ctx) {
        const slots = ctx.get('slots')
        if (!slots) return
        slots.inject('settings.section', () =>
          slots.register(
            { name: 'settings.section', id: 'phone-bridge', order: 35, label: '手机设备' },
            () => h(Panel),
          ),
        )
      },
    }
    },
  })
})()
