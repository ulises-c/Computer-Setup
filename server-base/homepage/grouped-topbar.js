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
  const model = (samples, config, now, clock) => {
    const groups = ['Compute','Storage','Connectivity','System'].map(title => ({title, tiles:[]}));
    const add = (group, label, rows, source = 'native', usage, detail, ttl) => {
      groups[group].tiles.push({label, rows, usage, detail, state:status(samples[source],now,ttl)});
    };
    const d = samples.native?.data || {};
    add(0,'CPU',[['Usage',pct(d.cpu?.total)],['Load · 15m',decimal(d.load?.min15)]], 'native', d.cpu?.total);
    add(0,'RAM',[['Used',pct(d.mem?.percent)],['Free',bytes(d.mem?.available,true)],['Total',bytes(d.mem?.total,true)]], 'native', d.mem?.percent);
    for (const s of d.sensors || []) {
      if (s.type === 'temperature_core' && number(s.value)) {
        if (s.label === 'CPU') {
          groups[0].tiles[0].rows.push(['Temp',`${decimal(s.value)}°C`]);
          if (number(s.warning)) groups[0].tiles[0].rows.push(['Warn',`${decimal(s.warning)}°C`]);
        } else {
          add(1,s.label === 'NVMe' ? 'NVMe' : `${s.label} temperature`,[['Temp',`${decimal(s.value)}°C`],['Warn',number(s.warning) ? `${decimal(s.warning)}°C` : '—']]);
        }
      } else if (s.type === 'fan_speed' && number(s.value) && s.value > 0) {
        add(0,s.label,[['Fan',`${decimal(s.value)} RPM`]]);
      }
    }
    for (const g of samples.gpu?.data || []) {
      const rows = [];
      // Hardware inventory is explicit per host; vendor alone is not a type.
      const kind = ['dGPU','iGPU'].includes(config.gpuTypes?.[g.gpu_id]) ? config.gpuTypes[g.gpu_id] : 'GPU';
      if (number(g.proc)) rows.push(['Usage',pct(g.proc)]);
      if (number(g.temperature)) rows.push(['Temp',`${decimal(g.temperature)}°C`]);
      const memory = number(g.memory_used) && number(g.memory_total) && g.memory_used >= 0 && g.memory_total > 0 && g.memory_used <= g.memory_total;
      rows.push([kind === 'iGPU' ? 'Memory' : 'VRAM',memory ? `${bytes(g.memory_used,true)} / ${bytes(g.memory_total,true)}` : '— / —']);
      if (number(g.mem)) rows.push(['Memory used',pct(g.mem)]);
      if (number(g.fan_speed)) rows.push(['Fan',pct(g.fan_speed)]);
      add(0,kind,rows,'gpu',g.proc,`${g.name || 'Unknown model'}${kind === 'GPU' ? ' · type unknown' : ''}`);
    }
    for (const mount of config.disks || []) {
      const f = (d.fs || []).find(f=>f.mnt_point === mount);
      add(1, f?.alias === 'system' ? 'System disk' : f?.alias || mount,
        [['Used',pct(f?.percent)],['Free',bytes(f?.free)],['Total',bytes(f?.size)]], 'native',f?.percent, f?.fs_type);
    }
    for (const [i, disk] of (samples.smart?.data || []).entries()) {
      const attrs = Object.values(disk).filter(a=>a && typeof a === 'object' && 'key' in a);
      const get = key => attrs.find(a=>a.key===key)?.value;
      if (get('percentageUsed') == null) continue;
      const health = get('criticalWarning') == null || get('integrityErrors') == null ? 'Unknown' : (Number(get('criticalWarning')) || Number(get('integrityErrors'))) ? 'WARN' : 'OK';
      // Merge only when there is exactly one device; don't imply a thermal
      // sensor belongs to a particular drive in a multi-NVMe host.
      const thermal = samples.smart.data.length === 1 && groups[1].tiles.find(t=>t.label === 'NVMe');
      if (thermal) {
        thermal.rows.push(['Health',health],['Wear',`${get('percentageUsed')}%`]);
        thermal.state = status(samples.smart,now,130000) || thermal.state;
      } else {
        add(1,`NVMe health${i ? ` ${i+1}` : ''}`,[['Health',health],['Wear',`${get('percentageUsed')}%`]],'smart',undefined,undefined,130000);
      }
    }
    if (config.net) {
      const nic = (samples.network?.data || []).find(n=>n.interface_name===config.net);
      add(2,config.net,[['Upload',number(nic?.bytes_sent_rate_per_sec) ? `${bytes(nic.bytes_sent_rate_per_sec)}/s` : '—'],['Download',number(nic?.bytes_recv_rate_per_sec) ? `${bytes(nic.bytes_recv_rate_per_sec)}/s` : '—']], 'network',undefined,nic ? 'Throughput' : 'Interface unavailable');
    }
    for (const w of samples.wifi?.data || []) {
      if (w.quality_level == null) continue;
      add(2,'Wi-Fi',[['Signal',`${w.quality_level} dBm`],['Link',pct(w.quality_link)]],'wifi');
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
  const markup = (groups) => groups.map((group,i)=>`<section class="monitor-group" aria-labelledby="monitor-heading-${i}"><h2 id="monitor-heading-${i}">${esc(group.title)}</h2><div class="monitor-tiles">${group.tiles.map(tile=>`<article class="monitor-tile${tile.state ? ' has-warning' : ''}"><h3>${esc(tile.label)}</h3>${tile.detail ? `<p class="monitor-detail">${esc(tile.detail)}</p>` : ''}<dl>${tile.rows.map(([label,value])=>`<div><dt>${esc(label)}</dt><dd>${esc(value)}</dd></div>`).join('')}</dl>${number(tile.usage) ? `<div class="monitor-meter" aria-hidden="true"><span style="width:${Math.min(100,Math.max(0,tile.usage))}%"></span></div>` : ''}${tile.state ? `<p class="monitor-state">${esc(tile.state)}</p>` : ''}</article>`).join('')}</div></section>`).join('');
  const start = (root, config) => {
    const {document} = root;
    const originalFetch = root.fetch;
    const glances = publicUrl(config.glances, root.location.origin);
    const samples = {};
    let busy = false, stopped = false, smartAttempt = 0, lastMarkup = '';
    const record = (key,data,error = false) => {
      samples[key] = error ? {...samples[key],error:true} : {data,at:Date.now(),error:false};
    };
    const render = () => {
      // Leave native markup visible until a compatible native payload exists.
      // React owns it: never move/remove its children or attach an observer here.
      const host = document.querySelector('#information-widgets');
      if (!host || !samples.native?.data) return;
      const clock = document.querySelector('.information-widget-datetime')?.textContent.trim() || '';
      const groups = model(samples,config,Date.now(),clock);
      const failed = Object.entries(samples).filter(([key,s])=>key !== 'native' && s.error).map(([key])=>key.toUpperCase());
      const nativeState = status(samples.native,Date.now());
      const content = `${nativeState || failed.length ? `<p class="monitor-notice" role="status">${esc([nativeState,failed.length ? `Extras unavailable: ${failed.join(', ')}` : ''].filter(Boolean).join(' · '))}</p>` : ''}<div class="monitor-groups">${markup(groups)}</div>`;
      let panel = host.querySelector(':scope > .host-monitor');
      if (!panel) {
        panel = document.createElement('div');
        panel.className = 'host-monitor';
        panel.setAttribute('aria-label','Host metrics');
        panel.innerHTML = `<header class="monitor-header"><span class="monitor-host">${esc(config.label || 'Host metrics')}</span><span class="monitor-cadence">Native auto · extras 5s · health 60s</span>${glances ? `<a href="${esc(glances)}" target="_blank" rel="noopener noreferrer">Open Glances ↗</a>` : ''}</header><div class="monitor-body"></div>`;
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
            if (response.ok && !data.error && data.cpu && data.mem && Array.isArray(data.fs)) record('native',data);
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
        if (!Array.isArray(data)) throw new Error('invalid endpoint shape');
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
          for (const key of ['gpu','wifi',...(config.net ? ['network'] : [])]) jobs.push(get(key,`${glances.replace(/\/$/,'')}/api/4/${key}`));
          if (!smartAttempt || Date.now() - smartAttempt >= 60000) {
            smartAttempt = Date.now();
            jobs.push(get('smart',`${glances.replace(/\/$/,'')}/api/4/smart`));
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
  if (typeof module !== 'undefined') module.exports = { isNativeRequest, model, status, markup, publicUrl, start };
  else {
    const config = root.__NEXT_DATA__?.props?.pageProps?.initialSettings?.topbarExtras;
    if (config?.grouped && !root.__homepageGroupedTopbar) root.__homepageGroupedTopbar = start(root,config);
  }
})(typeof window === 'undefined' ? globalThis : window);
