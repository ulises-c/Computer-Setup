const durations = { '1d': 86400, '1w': 604800, '1m': 2592000, '1y': 31536000 }
let range = '1d'
let requestNumber = 0
let latest = null
const modelSelect = document.getElementById('model')
const format = n => new Intl.NumberFormat(undefined, { maximumFractionDigits: 1, notation: n >= 10000 ? 'compact' : 'standard' }).format(n)
const formatRate = n => n > 0 && n < 0.01 ? '<0.01' : n > 0 && n < 0.1 ? n.toFixed(2) : format(n)
const color = name => {
  let hash = 0
  for (const char of name) hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  return `hsl(${170 + hash % 170} 65% 68%)`
}

function chart(id, data, key) {
  const canvas = document.getElementById(`chart-${id}`)
  const bounds = canvas.getBoundingClientRect()
  const width = Math.max(240, Math.round(bounds.width))
  const height = 210
  const scale = window.devicePixelRatio || 1
  canvas.width = width * scale
  canvas.height = height * scale
  const ctx = canvas.getContext('2d')
  ctx.scale(scale, scale)
  const left = 48, right = width - 14, top = 13, bottom = height - 29
  const periodStart = data.generated_at - durations[data.range]
  const names = [...new Set(data.series.map(row => row.model))].sort()
  const maxValue = Math.max(key === 'requests' ? 1 : 0.001, ...data.series.map(row => row[key] ?? 0)) * 1.12
  ctx.font = '10px ui-monospace, monospace'
  ctx.textAlign = 'right'
  for (let tick = 0; tick <= 3; tick++) {
    const y = bottom - (bottom - top) * tick / 3
    ctx.strokeStyle = '#2a3944'; ctx.lineWidth = 1
    ctx.beginPath(); ctx.moveTo(left, y); ctx.lineTo(right, y); ctx.stroke()
    ctx.fillStyle = '#7f94a2'; ctx.fillText(formatRate(maxValue * tick / 3), left - 8, y + 3)
  }
  ctx.textAlign = 'center'; ctx.fillStyle = '#8196a5'
  for (let tick = 0; tick <= 3; tick++) {
    const x = left + (right - left) * tick / 3
    const date = new Date((periodStart + durations[data.range] * tick / 3) * 1000)
    const label = data.range === '1d'
      ? date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
      : date.toLocaleDateString([], { month: 'short', day: 'numeric' })
    ctx.fillText(label, x, height - 8)
  }
  if (!names.length) {
    ctx.fillStyle = '#91a5b5'; ctx.font = '12px ui-monospace, monospace'
    ctx.fillText('No activity in this period', (left + right) / 2, height / 2)
    return
  }
  for (const name of names) {
    const byBucket = new Map(data.series.filter(row => row.model === name).map(row => [row.bucket, row]))
    ctx.strokeStyle = color(name); ctx.lineWidth = 2; ctx.lineJoin = 'round'
    ctx.beginPath()
    let drawing = false
    for (let t = Math.floor(periodStart / data.bucket_seconds) * data.bucket_seconds;
         t <= data.generated_at; t += data.bucket_seconds) {
      const row = byBucket.get(t)
      const value = row?.[key] ?? (key === 'pp_tps' || key === 'tg_tps' ? null : 0)
      if (value == null) { drawing = false; continue }
      const bucketEnd = Math.min(data.generated_at, t + data.bucket_seconds)
      const x = left + (right - left) * Math.max(0, bucketEnd - periodStart) / durations[data.range]
      const y = bottom - (bottom - top) * value / maxValue
      if (drawing) ctx.lineTo(x, y)
      else { ctx.moveTo(x, y); drawing = true }
    }
    ctx.stroke()
    for (const row of byBucket.values()) {
      if (row[key] == null) continue
      const bucketEnd = Math.min(data.generated_at, row.bucket + data.bucket_seconds)
      const x = left + (right - left) * Math.max(0, bucketEnd - periodStart) / durations[data.range]
      const y = bottom - (bottom - top) * row[key] / maxValue
      ctx.beginPath(); ctx.arc(x, y, 2.5, 0, Math.PI * 2); ctx.fillStyle = color(name); ctx.fill()
    }
  }
}

function render(data) {
  latest = data
  const selected = modelSelect.value
  const existing = [...modelSelect.options].slice(1).map(option => option.value)
  if (JSON.stringify(existing) !== JSON.stringify(data.models)) {
    modelSelect.replaceChildren(new Option('All models', ''), ...data.models.map(name => new Option(name, name)))
    modelSelect.value = data.models.includes(selected) ? selected : ''
  }
  const rows = data.series
  const sum = name => rows.reduce((total, row) => total + row[name], 0)
  const total = sum('requests')
  document.getElementById('requests').textContent = format(total)
  document.getElementById('errors').textContent = `${format(sum('errors'))} errors`
  document.getElementById('input').textContent = format(sum('input_tokens'))
  document.getElementById('output').textContent = format(sum('output_tokens'))
  const bucketRates = new Map()
  for (const row of rows) bucketRates.set(row.bucket, (bucketRates.get(row.bucket) ?? 0) + row.output_tps)
  document.getElementById('peak').textContent = `${formatRate(Math.max(0, ...bucketRates.values()))} tok/s`
  const names = [...new Set(rows.map(row => row.model))].sort()
  const legend = document.getElementById('legend')
  legend.replaceChildren(...names.map(name => {
    const item = document.createElement('span')
    const swatch = document.createElement('i')
    swatch.style.background = color(name)
    item.append(swatch, document.createTextNode(name))
    return item
  }))
  for (const key of ['requests', 'output_tps', 'tg_tps', 'pp_tps']) chart(key, data, key)
  for (const [key, samples] of [['tg', 'tg_samples'], ['pp', 'pp_samples']]) {
    const available = sum(samples)
    document.getElementById(`${key}-coverage`).textContent = `${format(available)} of ${format(total)} requests have ${key.toUpperCase()} timing data`
  }
  document.getElementById('updated').textContent = `Updated ${new Date(data.generated_at * 1000).toLocaleTimeString()}`
}

async function load() {
  const sequence = ++requestNumber
  const params = new URLSearchParams({ range })
  if (modelSelect.value) params.set('model', modelSelect.value)
  try {
    const response = await fetch(`/api/series?${params}`)
    if (!response.ok) throw new Error(`Server returned ${response.status}`)
    const data = await response.json()
    if (sequence !== requestNumber) return
    document.getElementById('error').hidden = true
    render(data)
  } catch (error) {
    if (sequence !== requestNumber) return
    const el = document.getElementById('error')
    el.textContent = `Telemetry is unavailable: ${error.message}`
    el.hidden = false
    document.getElementById('updated').textContent = 'Disconnected'
  }
}

for (const button of document.querySelectorAll('[data-range]')) button.addEventListener('click', () => {
  range = button.dataset.range
  for (const other of document.querySelectorAll('[data-range]')) {
    const active = other === button
    other.classList.toggle('selected', active)
    other.setAttribute('aria-pressed', String(active))
  }
  load()
})
modelSelect.addEventListener('change', load)
window.addEventListener('resize', () => { if (latest) render(latest) })
setInterval(load, 60000)
load()
