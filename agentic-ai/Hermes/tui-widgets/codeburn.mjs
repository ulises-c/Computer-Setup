/**
 * codeburn — ambient TUI card: today's and this month's AI spend, plus the
 * Claude / Codex subscription quota windows. Data comes from the local
 * `codeburn` CLI (npm i -g codeburn); nothing leaves the machine.
 *
 * `/codeburn` toggles the card; `/codeburn 120` sets the refresh interval in
 * seconds (minimum 30, default 60).
 */
export default function register(sdk) {
  const { Box, Dialog, React, ShimmerRows, Text, defineWidgetApp, gauge, h } = sdk

  const WIDTH = 46
  const BAR = 7
  const QUOTA_IDS = ['claude', 'codex']
  const TIMEOUT_MS = 30_000

  async function run(args) {
    const { execFile } = await import('node:child_process')

    return new Promise((resolve, reject) => {
      execFile('codeburn', args, { timeout: TIMEOUT_MS, maxBuffer: 8 * 1024 * 1024 }, (error, stdout) => {
        if (error) {
          reject(new Error(error.code === 'ENOENT' ? 'codeburn not on PATH' : error.message.split('\n')[0]))

          return
        }

        try {
          resolve(JSON.parse(stdout))
        } catch {
          reject(new Error(`codeburn ${args[0]}: unparseable output`))
        }
      })
    })
  }

  async function fetchReport() {
    const [status, quota] = await Promise.all([
      run(['status', '--format', 'json']),
      run(['quota', '--format', 'json']).catch(() => ({ providers: [] }))
    ])

    const providers = (quota.providers ?? []).filter(p => QUOTA_IDS.includes(p.id) && p.available)

    return {
      currency: status.currency ?? 'USD',
      month: status.month ?? { cost: 0, calls: 0 },
      quota: providers.map(p => ({
        name: p.name,
        windows: (p.windows ?? []).filter(w => w.label === '5-hour' || w.label === 'Weekly')
      })),
      today: status.today ?? { cost: 0, calls: 0 },
      updated: new Date()
    }
  }

  const money = (v, currency) => {
    const n = Number(v) || 0
    const text = n >= 1000 ? n.toFixed(0) : n.toFixed(2)

    return (currency === 'USD' ? '$' : `${currency} `) + text
  }

  const tone = (pct, t) => (pct >= 85 ? t.color.error : pct >= 60 ? t.color.warn : t.color.ok)

  function QuotaRow({ provider, t }) {
    const cells = [h(Text, { color: t.color.label, key: 'n' }, provider.name.padEnd(7).slice(0, 7))]

    for (const w of provider.windows) {
      const pct = Math.round(Number(w.usedPct) || 0)
      const label = w.label === '5-hour' ? '5h' : 'wk'

      cells.push(
        h(Text, { color: t.color.muted, key: `${label}l` }, label),
        h(Text, { color: tone(pct, t), key: `${label}g` }, gauge(pct / 100, BAR)),
        h(Text, { color: t.color.text, key: `${label}p` }, `${String(pct).padStart(3)}%`)
      )
    }

    return h(Box, { columnGap: 1, flexDirection: 'row' }, ...cells)
  }

  function Card({ intervalS, t }) {
    const [phase, setPhase] = React.useState({ kind: 'loading' })

    React.useEffect(() => {
      let alive = true

      const tick = () =>
        fetchReport().then(
          report => alive && setPhase({ kind: 'ready', report }),
          error => alive && setPhase(prev => ({ kind: 'error', message: error.message, last: prev.report ?? prev.last }))
        )

      tick()
      const id = setInterval(tick, intervalS * 1000)

      return () => {
        alive = false
        clearInterval(id)
      }
    }, [intervalS])

    if (phase.kind === 'loading') {
      return h(ShimmerRows, { rows: 3, t, width: WIDTH - 6 })
    }

    const report = phase.kind === 'ready' ? phase.report : phase.last

    if (!report) {
      return h(Text, { color: t.color.error, wrap: 'truncate-end' }, `codeburn: ${phase.message}`)
    }

    const stamp = report.updated.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', hour12: false })

    return h(
      Box,
      { flexDirection: 'column' },
      h(
        Box,
        { columnGap: 1, flexDirection: 'row' },
        h(Text, { bold: true, color: t.color.primary }, 'burn'),
        h(Text, { color: t.color.label }, 'today'),
        h(Text, { color: t.color.text }, money(report.today.cost, report.currency).padStart(7)),
        h(Text, { color: t.color.label }, 'month'),
        h(Text, { color: t.color.text }, money(report.month.cost, report.currency).padStart(7)),
        h(Text, { color: phase.kind === 'error' ? t.color.error : t.color.muted }, phase.kind === 'error' ? 'stale' : stamp)
      ),
      ...report.quota.map(p => h(QuotaRow, { key: p.name, provider: p, t }))
    )
  }

  defineWidgetApp({
    id: 'codeburn',
    help: 'AI spend today/month + Claude/Codex quota (arg: refresh seconds)',
    mode: 'ambient',
    usage: 'usage: /codeburn [refresh-seconds ≥ 30]',
    width: WIDTH,
    zone: 'dock-top',

    init(arg) {
      const raw = arg.trim()

      if (!raw) {
        return { intervalS: 60 }
      }

      const n = Number(raw)

      return Number.isFinite(n) && n >= 30 ? { intervalS: Math.round(n) } : null
    },

    reduce(state, { ch, key }) {
      return key.escape || ch === 'q' ? null : state
    },

    render({ state, t }) {
      return h(Dialog, { width: WIDTH }, h(Card, { intervalS: state.intervalS, t }))
    }
  })
}
