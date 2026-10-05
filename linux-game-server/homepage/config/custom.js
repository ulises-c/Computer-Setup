// Generated from server-base/homepage/custom.js.in.
// Tags each Homepage group with its accent (server-base/fleet.json) so
// custom.css can colour it. Homepage renders client-side and may re-render
// groups, so re-apply on DOM changes.
(() => {
  const accents = {"Game server": "blue", "Games": "rose", "Servers": "indigo", "Shared services": "cyan"};
  const apply = () => {
    for (const heading of document.querySelectorAll(".service-group-name")) {
      const accent = accents[heading.textContent.trim()];
      const group = heading.closest(".services-group");
      if (accent && group && group.dataset.accent !== accent) {
        group.dataset.accent = accent;
      }
    }
  };
  apply();
  new MutationObserver(apply).observe(document.body, { childList: true, subtree: true });
})();

/* Opt-in Homepage monitor; native requests are observed, never duplicated. */
((root) => {
  const isNativeRequest = (input, origin) => {
    try {
      const url = new URL(typeof input === 'string' ? input : input.url, origin);
      return url.origin === origin && url.pathname === '/api/widgets/glances' && url.searchParams.get('index') === '0';
    } catch { return false; }
  };
  const number = (n) => typeof n === 'number' && Number.isFinite(n);
  const decimal = (n) => number(n) ? String(Math.round(n * 10) / 10) : '—';
  const pct = (n) => number(n) ? `${decimal(n)}%` : '—';
  const bytes = (n, binary = false) => {
    if (!number(n)) return '—';
    const base = binary ? 1024 : 1000;
    const units = binary ? ['B','KiB','MiB','GiB','TiB'] : ['B','kB','MB','GB','TB'];
    let i = 0;
    while (n >= base && i < units.length - 1) { n /= base; i++; }
    return `${decimal(n)} ${units[i]}`;
  };
  const status = (sample, now, ttl = 15000) => sample?.error ? (sample.at ? 'Unavailable · last value' : 'Unavailable') : !sample?.at ? 'Loading' : now - sample.at > ttl ? 'Stale · last value' : '';
  const interval = (value, minimum) => number(value) && value >= minimum ? value : minimum;
  // Conservative floors: filesystem figures are cached by the host collector for
  // 5 minutes and NVMe health for 10; a config value can only lengthen them.
  const cadence = config => ({filesystem:interval(config.filesystemIntervalMs,300000),smart:interval(config.smartIntervalMs,600000)});
  const duration = ms => `${decimal(ms / 60000)}m`;
  const ageText = ms => ms < 60000 ? `${Math.max(0,Math.floor(ms / 1000))}s` : ms < 3600000 ? `${Math.floor(ms / 60000)}m` : `${Math.floor(ms / 3600000)}h`;
  // Collector age, never HTTP response age: the native proxy may serve a cached
  // snapshot instantly. Seconds reported by the host are advanced by the time
  // since that report reached this browser (no browser/server clock comparison).
  const storageState = (meta, receivedAt, now, floorMs) => {
    if (meta?.status === 'never') return 'Waiting for first collection';
    if (meta?.status === 'empty') return 'Collector returned no data';
    const age = number(meta?.age) ? meta.age * 1000 + Math.max(0, now - receivedAt) : null;
    if (meta?.status === 'error') return `Collection error · last value${age == null ? '' : `, ${ageText(age)} old`}`;
    if (age == null) return 'Cached · age unknown';
    const ttl = 2 * Math.max(floorMs, number(meta.interval) ? meta.interval * 1000 : 0);
    return `${age > ttl ? 'Stale' : 'Cached'} · collected ${ageText(age)} ago`;
  };
  const rowMeta = row => row && {status:row.collection_status,age:row.collection_age_seconds,interval:row.collection_interval_seconds};
  const model = (samples, config, now, clock) => {
    const groups = ['Compute','Storage','Connectivity','System'].map(title => ({title, tiles:[]}));
    const add = (group, label, rows, source = 'native', usage, detail, ttl) => {
      groups[group].tiles.push({label, rows, usage, detail, state:status(samples[source],now,ttl)});
    };
    const d = samples.native?.data || {};
    add(0,'CPU',[['Usage',pct(d.cpu?.total)],['Load · 15m',decimal(d.load?.min15)]], 'native', d.cpu?.total);
    add(0,'RAM',[['Used',pct(d.mem?.percent)],['Free',bytes(d.mem?.available,true)],['Total',bytes(d.mem?.total,true)]], 'native', d.mem?.percent);
    const sensors = d.sensors || [];
    const celsius = n => number(n) ? `${decimal(n)}°C` : '—';
    const cpu = sensors.find(s=>s.label === 'CPU' && s.type === 'temperature_core');
    groups[0].tiles[0].rows.push(['Temp',celsius(cpu?.value)],['Warn',celsius(cpu?.warning)]);
    const thermalLabels = [...new Set([...(config.temperatureLabels || []), ...sensors.filter(s=>s.type === 'temperature_core' && s.label !== 'CPU').map(s=>s.label)])];
    for (const label of thermalLabels) {
      const s = sensors.find(s=>s.label === label && s.type === 'temperature_core');
      add(1,label === 'NVMe' ? label : `${label} temperature`,[['Temp',celsius(s?.value)],['Warn',celsius(s?.warning)]]);
      // Drive temperature shares the host's cached health sample; label it so.
      if (config.temperatureLabels?.includes(label) && samples.native?.at && !groups[1].tiles.at(-1).state) groups[1].tiles.at(-1).state = 'Cached · age unknown';
    }
    for (const s of sensors) {
      if (s.type === 'fan_speed' && number(s.value) && s.value > 0) add(0,s.label,[['Fan',`${decimal(s.value)} RPM`]]);
    }
    const gpu = config.gpu === false ? [] : samples.gpu?.data || [];
    const gpuIds = [...new Set([...Object.keys(config.gpuTypes || {}), ...gpu.map((g,i)=>g.gpu_id ?? `unidentified-${i}`)])];
    for (const id of gpuIds) {
      const g = gpu.find((g,i)=>(g.gpu_id ?? `unidentified-${i}`) === id) || {gpu_id:id};
      const rows = [];
      // Hardware inventory is explicit per host; vendor alone is not a type.
      const kind = ['dGPU','iGPU'].includes(config.gpuTypes?.[g.gpu_id]) ? config.gpuTypes[g.gpu_id] : 'GPU';
      rows.push(['Usage',pct(g.proc)],['Temp',celsius(g.temperature)]);
      const memory = number(g.memory_used) && number(g.memory_total) && g.memory_used >= 0 && g.memory_total > 0 && g.memory_used <= g.memory_total;
      rows.push([kind === 'iGPU' ? 'Memory' : 'VRAM',memory ? `${bytes(g.memory_used,true)} / ${bytes(g.memory_total,true)}` : '— / —']);
      rows.push(['Memory used',pct(g.mem)],['Fan',pct(g.fan_speed)]);
      const selectedRows = config.gpuFields?.[g.gpu_id];
      add(0,kind,Array.isArray(selectedRows) ? rows.filter(([label])=>selectedRows.includes(label)) : rows,'gpu',g.proc,`${g.name || 'Device data pending'}${kind === 'GPU' ? ' · type unknown' : ''}`);
    }
    const hdd = new Set(config.hddDisks || []);
    for (const mount of config.disks || []) {
      const label = config.diskLabels?.[mount] || (mount === '/etc/hostname' ? 'System disk' : mount);
      if (hdd.has(mount)) {
        // Policy: spinning disks are never polled or displayed, even if an older
        // backend still returns a row for them.
        add(1,label,[['Used','—'],['Free','—'],['Total','—']],'native');
        groups[1].tiles.at(-1).state = 'Not monitored · HDD';
        continue;
      }
      const f = (d.fs || []).find(f=>f.mnt_point === mount);
      add(1, config.diskLabels?.[mount] || (mount === '/etc/hostname' || f?.alias === 'system' ? 'System disk' : f?.alias || mount),
        [['Used',pct(f?.percent)],['Free',bytes(f?.free)],['Total',bytes(f?.size)]], 'native',f?.percent, f?.fs_type);
      const tile = groups[1].tiles.at(-1);
      if (samples.native?.at && !samples.native.error) tile.state = f ? storageState(rowMeta(f),samples.native.at,now,cadence(config).filesystem) : 'Unavailable';
      else if (samples.native?.error && samples.native.at) tile.state = f ? 'Unavailable · last value' : 'Unavailable';
    }
    const policy = samples.storagepolicy?.data;
    const policyDevice = name => (policy?.smart?.devices || []).find(x=>x.DeviceName === name);
    const smartState = (disk) => {
      if (samples.smart?.error) return status(samples.smart,now);
      if (policy?.smart?.enabled === false) return 'Health disabled by host policy';
      const entry = policyDevice(disk?.DeviceName);
      return storageState(entry && {status:policy.smart.status === 'error' ? 'error' : 'ok',age:entry.collection_age_seconds,interval:policy.smart.interval_seconds},samples.storagepolicy?.at ?? now,now,cadence(config).smart);
    };
    const attrs = disk => Object.values(disk || {}).filter(a=>a && typeof a === 'object' && 'key' in a);
    const attr = (disk, key) => attrs(disk).find(a=>a.key===key)?.value;
    // Health slots exist from first paint when the host opted in (dashes), and
    // are filled in place later: nothing is appended after the shell is laid out.
    if (config.safeSSDHealth === true || samples.smart) {
      const present = (samples.smart?.data || []).filter(disk=>attr(disk,'percentageUsed') != null);
      const slots = present.length > 1 ? present : [present[0]];
      slots.forEach((disk, i) => {
        const health = !disk ? '—' : attr(disk,'criticalWarning') == null || attr(disk,'integrityErrors') == null ? 'Unknown' : (Number(attr(disk,'criticalWarning')) || Number(attr(disk,'integrityErrors'))) ? 'WARN' : 'OK';
        const rows = [['Health',health],['Wear',disk ? `${attr(disk,'percentageUsed')}%` : '—']];
        // Merge only when there is exactly one device; don't imply a thermal
        // sensor belongs to a particular drive in a multi-NVMe host.
        const thermal = slots.length === 1 && groups[1].tiles.find(t=>t.label === 'NVMe');
        const state = disk ? smartState(disk) : samples.smart?.at && !samples.smart.error ? (policy?.smart?.enabled === false ? 'Health disabled by host policy' : 'Health unavailable') : status(samples.smart,now);
        if (thermal) { thermal.rows.push(...rows); thermal.state = state || thermal.state; }
        else { add(1,`NVMe health${i ? ` ${i+1}` : ''}`,rows,'smart'); groups[1].tiles.at(-1).state = state; }
      });
    }
    if (config.net) {
      const nic = (samples.network?.data || []).find(n=>n.interface_name===config.net);
      add(2,config.net,[['Upload',number(nic?.bytes_sent_rate_per_sec) ? `${bytes(nic.bytes_sent_rate_per_sec)}/s` : '—'],['Download',number(nic?.bytes_recv_rate_per_sec) ? `${bytes(nic.bytes_recv_rate_per_sec)}/s` : '—']], 'network',undefined,nic ? 'Throughput' : 'Interface unavailable');
    }
    const wifi = samples.wifi?.data || [];
    for (const w of wifi.length ? wifi : config.wifi ? [{}] : []) {
      add(2,'Wi-Fi',[['Signal',number(w.quality_level) ? `${w.quality_level} dBm` : '—'],['Link',pct(w.quality_link)]],'wifi');
    }
    add(3,'Host',[['Uptime',d.uptime || '—'],['Clock',clock || '—']], 'native',undefined,'Clock · browser local time');
    return groups;
  };
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const publicUrl = (value, origin) => {
    if (!value) return null;
    try {
      const url = new URL(value,origin);
      return !url.username && !url.password && (url.protocol === 'https:' || (url.protocol === 'http:' && url.origin === origin)) ? url.href : null;
    } catch { return null; }
  };
  // A healthy cache age and the standing info banner are routine, not warnings:
  // amber is reserved for stale, unknown, failed or unavailable data.
  const calmState = text => !text || /^Cached · collected /.test(text);
  const noticeLevel = text => (!text || text === 'Loading host metrics' ||
    text.startsWith('Core metrics update automatically')) ? 'calm' : 'warn';
  const markup = (groups) => groups.map((group,i)=>`<section class="monitor-group" aria-labelledby="monitor-heading-${i}"><h2 id="monitor-heading-${i}">${esc(group.title)}</h2><div class="monitor-tiles">${group.tiles.map(tile=>`<article class="monitor-tile${tile.state && !calmState(tile.state) ? ' has-warning' : ''}"><h3>${esc(tile.label)}</h3><p class="monitor-detail">${esc(tile.detail || '')}</p><dl>${tile.rows.map(([label,value])=>`<div><dt>${esc(label)}</dt><dd>${esc(value)}</dd></div>`).join('')}</dl><div class="monitor-meter" aria-hidden="true">${number(tile.usage) ? `<span style="width:${Math.min(100,Math.max(0,tile.usage))}%"></span>` : ''}</div><p class="monitor-state${calmState(tile.state) ? ' is-calm' : ''}">${esc(tile.state || '')}</p></article>`).join('')}</div></section>`).join('');
  const start = (root, config) => {
    const {document} = root;
    const originalFetch = root.fetch;
    const glances = publicUrl(config.glances, root.location.origin);
    const samples = {};
    const startedAt = Date.now();
    const intervals = cadence(config);
    let busy = false, stopped = false, smartAttempt = 0, lastMarkup = '';
    const record = (key,data,error = false) => {
      samples[key] = error ? {...samples[key],error:true} : {data,at:Date.now(),error:false};
    };
    const render = () => {
      // The grouped shell belongs to layout, not arrival of a live sample.
      // Unknown measurements remain dashes; React still owns native children.
      const host = document.querySelector('#information-widgets');
      if (!host) return;
      const clock = document.querySelector('.information-widget-datetime')?.textContent.trim() || '';
      const groups = model(samples,config,Date.now(),clock);
      // Filesystem rows ride in the native payload; their failures show on each tile.
      const failed = Object.entries(samples).filter(([key,s])=>key !== 'native' && s.error).map(([key])=>key.toUpperCase());
      const waiting = !samples.native?.at && !samples.native?.error && !document.hidden && Date.now() - startedAt > 12000;
      const nativeState = waiting ? 'Unavailable · awaiting native data' : status(samples.native,Date.now());
      const notice = [nativeState,failed.length ? `Extras unavailable: ${failed.join(', ')}` : ''].filter(Boolean).join(' · ') || (samples.native?.at ? 'Core metrics update automatically · filesystem and health values are cached snapshots' : 'Loading host metrics');
      const content = `<p class="monitor-notice${noticeLevel(notice) === 'calm' ? ' is-calm' : ''}" role="status" title="${esc(notice)}">${esc(notice)}</p><div class="monitor-groups">${markup(groups)}</div>`;
      let panel = host.querySelector(':scope > .host-monitor');
      if (!panel) {
        panel = document.createElement('div');
        panel.className = 'host-monitor';
        panel.setAttribute('aria-label','Host metrics');
        panel.innerHTML = `<header class="monitor-header"><span class="monitor-host">${esc(config.label || 'Host metrics')}</span><span class="monitor-cadence">Native auto · extras 5s · filesystem cache ${duration(intervals.filesystem)} · ${config.safeSSDHealth === true ? `health ${duration(intervals.smart)}` : 'health disabled'}</span>${glances ? `<a href="${esc(glances)}" target="_blank" rel="noopener noreferrer">Open Glances ↗</a>` : ''}</header><div class="monitor-body"></div>`;
        host.prepend(panel);
        lastMarkup = '';
      }
      // Keep the keyboard-focusable link stable while readings change.
      if (content !== lastMarkup) { panel.querySelector('.monitor-body').innerHTML = content; lastMarkup = content; }
      host.classList.add('host-monitor-ready');
    };
    const wrappedFetch = async function(input,...args) {
      const native = isNativeRequest(input,root.location.origin);
      try {
        const response = await originalFetch.call(this,input,...args);
        if (native && !stopped) {
          // A clone is consumed, never the Response SWR needs. This is passive:
          // Homepage alone owns native request scheduling and visibility policy.
          Promise.resolve().then(()=>response.clone().json()).then(data=>{
            if (stopped) return;
            if (response.ok && !data.error && number(data.cpu?.total) && number(data.mem?.percent) && Array.isArray(data.fs)) record('native',data);
            else record('native',null,true);
            render();
          }).catch(()=>{record('native',null,true);render();});
        }
        return response;
      } catch (error) {
        if (native && !stopped) {record('native',null,true);render();}
        throw error;
      }
    };
    root.fetch = wrappedFetch;
    const get = async (key,url) => {
      try {
        const response = await originalFetch.call(root,url,{cache:'no-store',credentials:'omit',signal:root.AbortSignal.timeout(4000)});
        if (!response.ok) throw new Error('endpoint unavailable');
        const data = await response.json();
        // storagepolicy is one object; every other endpoint is a list.
        if (key === 'storagepolicy' ? !data || typeof data !== 'object' || Array.isArray(data) : !Array.isArray(data)) throw new Error('invalid endpoint shape');
        if (!stopped) record(key,data);
      } catch { if (!stopped) record(key,null,true); }
    };
    const refresh = async () => {
      render(); // Also age samples when a tab returns from background.
      if (busy || stopped || document.hidden) return;
      busy = true;
      try {
        const jobs = [];
        if (glances) {
          for (const key of [...(config.gpu === false ? [] : ['gpu']),...(config.wifi === false ? [] : ['wifi']),...(config.net ? ['network'] : [])]) jobs.push(get(key,`${glances.replace(/\/$/,'')}/api/4/${key}`));
          if (config.safeSSDHealth === true && (!smartAttempt || Date.now() - smartAttempt >= intervals.smart)) {
            smartAttempt = Date.now();
            // Health ages come from the host's metadata-only storagepolicy plugin.
            jobs.push(get('smart',`${glances.replace(/\/$/,'')}/api/4/smart`),get('storagepolicy',`${glances.replace(/\/$/,'')}/api/4/storagepolicy`));
          }
        }
        // Sensors already arrive in the native response: no duplicate request.
        await Promise.all(jobs);
      } finally { busy = false; if (!stopped) render(); }
    };
    const timer = root.setInterval(refresh,5000);
    document.addEventListener('visibilitychange',refresh);
    const stop = () => {
      stopped = true;
      root.clearInterval(timer);
      document.removeEventListener('visibilitychange',refresh);
      if (root.fetch === wrappedFetch) root.fetch = originalFetch;
    };
    root.addEventListener('pagehide',event=>{if (!event.persisted) stop();});
    refresh();
    return {samples,stop};
  };
  if (typeof module !== 'undefined') module.exports = { isNativeRequest, model, status, markup, noticeLevel, publicUrl, start };
  else {
    const config = root.__NEXT_DATA__?.props?.pageProps?.initialSettings?.topbarExtras;
    if (config?.grouped && !root.__homepageGroupedTopbar) root.__homepageGroupedTopbar = start(root,config);
  }
})(typeof window === 'undefined' ? globalThis : window);
