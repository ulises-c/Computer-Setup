// Live fleet map for /rs-sdk/live-map. Read-only: polls /rs-sdk/api/live and renders.
// Served as a static file so the page CSP can stay `script-src 'self'` (no inline JS).
(() => {
    'use strict';
    const root = document.getElementById('live');
    if (!root) return;
    const api = root.dataset.api;
    const refreshMs = Math.max(600, Number(root.dataset.refreshMs) || 6000);
    const viewport = document.getElementById('live-map');
    const canvas = document.getElementById('live-canvas');
    const image = document.getElementById('live-image');
    const statusLine = document.getElementById('live-status');
    const list = document.getElementById('live-bots');
    let meta = { width: 1920, height: 3328, originX: 1792, labels: [] };
    let scale = 2; // screen pixels per tile
    let bots = [];
    let selected = null;
    let centred = false;
    const markers = new Map();
    const labelNodes = [];

    const el = (tag, cls, text) => {
        const node = document.createElement(tag);
        if (cls) node.className = cls;
        if (text !== undefined && text !== null) node.textContent = String(text);
        return node;
    };
    const fmt = n => (n === null || n === undefined) ? '—' : Number(n).toLocaleString();
    const ago = ms => {
        if (!ms && ms !== 0) return null;
        const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
        if (s < 90) return `${s}s`;
        if (s < 5400) return `${Math.round(s / 60)}m`;
        return `${Math.floor(s / 3600)}h ${Math.round((s % 3600) / 60)}m`;
    };
    const words = key => key.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase();

    function layout() {
        canvas.style.width = `${meta.width * scale}px`;
        canvas.style.height = `${meta.height * scale}px`;
        for (const { node, label } of labelNodes) {
            node.style.left = `${label.x * scale}px`;
            node.style.top = `${label.y * scale}px`;
            node.hidden = scale < (label.size === 2 ? 0.5 : label.size === 1 ? 1 : 2.5);
        }
        for (const [name, node] of markers) {
            const bot = bots.find(b => b.username === name);
            if (bot && bot.player && bot.player.map) {
                node.style.left = `${(bot.player.map[0] + 0.5) * scale}px`;
                node.style.top = `${(bot.player.map[1] + 0.5) * scale}px`;
            }
        }
    }

    function zoomTo(next, cx, cy) {
        next = Math.min(16, Math.max(0.25, next));
        const rect = viewport.getBoundingClientRect();
        cx = cx ?? rect.width / 2;
        cy = cy ?? rect.height / 2;
        const tileX = (viewport.scrollLeft + cx) / scale;
        const tileY = (viewport.scrollTop + cy) / scale;
        scale = next;
        layout();
        viewport.scrollLeft = tileX * scale - cx;
        viewport.scrollTop = tileY * scale - cy;
    }

    function centreOn(col, row) {
        viewport.scrollLeft = (col + 0.5) * scale - viewport.clientWidth / 2;
        viewport.scrollTop = (row + 0.5) * scale - viewport.clientHeight / 2;
    }

    function region(bot) {
        if (!bot.player || !bot.player.map) return null;
        const [col, row] = bot.player.map;
        let best = null;
        for (const label of meta.labels) {
            if (label.size > 1) continue;
            const d = Math.hypot(label.x - col, label.y - row);
            if (d < 90 && (!best || d < best.d)) best = { d, text: label.text.replace(/\//g, ' ') };
        }
        return best ? `near ${best.text}` : null;
    }

    function renderMarkers() {
        const live = new Set();
        for (const bot of bots) {
            if (!bot.player || !bot.player.map) continue;
            live.add(bot.username);
            let node = markers.get(bot.username);
            if (!node) {
                node = el('button', 'live-marker');
                node.type = 'button';
                node.append(el('span', 'dot'), el('span', 'tag'));
                node.addEventListener('click', () => select(bot.username, true));
                canvas.append(node);
                markers.set(bot.username, node);
            }
            node.querySelector('.tag').textContent = bot.displayName || bot.username;
            node.title = `${bot.displayName || bot.username}: ${bot.activity.label}`;
            node.classList.toggle('selected', selected === bot.username);
            node.classList.toggle('fighting', !!bot.player.inCombat);
            node.classList.toggle('offline', bot.status !== 'active');
        }
        for (const [name, node] of markers) {
            if (!live.has(name)) { node.remove(); markers.delete(name); }
        }
        layout();
    }

    function select(name, scroll) {
        selected = name;
        const bot = bots.find(b => b.username === name);
        if (bot && bot.player && bot.player.map) centreOn(bot.player.map[0], bot.player.map[1]);
        for (const card of list.children) card.classList.toggle('selected', card.dataset.bot === name);
        if (scroll) {
            const card = list.querySelector(`[data-bot="${CSS.escape(name)}"]`);
            if (card) card.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        }
        renderMarkers();
    }

    function itemGrid(items, slots, empty) {
        const grid = el('div', slots ? 'live-items inventory' : 'live-items');
        if (!items.length) grid.append(el('span', 'muted', empty));
        for (const item of items) {
            const cell = el('span', 'item', item.name || `#${item.id}`);
            if (item.count > 1) cell.append(el('b', null, ` ×${fmt(item.count)}`));
            grid.append(cell);
        }
        return grid;
    }

    // Structured "what is it doing" block: routine status, frame observations, XP flow.
    function activityDetail(bot) {
        const a = bot.activity || {};
        const s = a.status;
        const rows = [];
        const row = (label, ...content) => {
            const dd = el('dd');
            for (const c of content) if (c !== null && c !== undefined && c !== '') dd.append(typeof c === 'string' ? document.createTextNode(c) : c);
            if (dd.childNodes.length) rows.push(el('dt', null, label), dd);
        };
        if (s) {
            const head = [s.routine, ...(s.args || [])].filter(Boolean).join(' ');
            row('Routine', el('b', null, head || 'routine'), ' ', el('span', `state ${s.state}`, s.state),
                s.startedAt ? ` · started ${ago(s.startedAt)} ago` : '',
                s.state !== 'running' && s.updatedAt ? ` · last update ${ago(s.updatedAt)} ago` : '');
            if (s.state === 'running') {
                row('Phase', el('b', null, s.phase), s.phaseSince ? ` for ${ago(s.phaseSince)}` : '', s.detail ? ` · ${s.detail}` : '');
            } else if (s.stopReason) {
                row('Stopped', s.stopReason);
            }
            const counts = Object.entries(s.counts || {});
            if (counts.length) {
                const list = el('span', 'counts');
                for (const [k, v] of counts) list.append(el('span', 'count', `${words(k)} ${fmt(v)}`));
                row('Counts', list);
            }
            if (s.lastEvent) row('Last event', `${s.lastEvent.kind}${s.lastEvent.at ? ` (${ago(s.lastEvent.at)} ago)` : ''}`);
        } else if (a.routine) {
            row('Routine', el('b', null, [a.routine, ...(a.args || [])].join(' ')), ' (no status published)');
        }
        if (a.fleetTask) row('Fleet', `${a.fleetTask.phase}${a.fleetTask.detail ? ` · ${a.fleetTask.detail}` : ''}${a.fleetTask.updatedAt ? ` (${ago(a.fleetTask.updatedAt)} ago)` : ''}`);
        if (a.levelUp) row('Dialog', `Level-up: ${a.levelUp}`);
        const seen = [];
        if (bot.player && bot.player.inCombat) seen.push(`fighting ${bot.player.target || 'something'}`);
        if (a.anim) {
            const tag = el('span', 'anim', a.anim.action);
            tag.title = `${a.anim.name || 'unknown animation'} (#${a.anim.id})${a.anim.ageMs ? `, ${(a.anim.ageMs / 1000).toFixed(0)} s ago` : ''}`;
            seen.push(tag);
        }
        if (a.motion && a.motion.state !== 'still') seen.push(`${a.motion.state}${a.motion.tiles ? ` (${a.motion.tiles} tiles)` : ''}`);
        if (seen.length) row('Seen', ...seen.flatMap((item, i) => (i ? [' · ', item] : [item])));
        const rates = Object.entries(bot.xpRate || {}).sort((x, y) => y[1] - x[1]);
        if (rates.length) row('XP/hour', rates.slice(0, 4).map(([k, v]) => `${k} ${fmt(v)}`).join(' · '));
        if (!rows.length) return null;
        const dl = el('dl', 'live-activity');
        dl.append(...rows);
        return dl;
    }

    function card(bot) {
        const p = bot.player;
        const node = el('article', 'live-bot');
        node.dataset.bot = bot.username;
        node.classList.toggle('selected', selected === bot.username);
        node.classList.toggle('is-offline', bot.status !== 'active');
        const head = el('header');
        head.append(el('b', null, bot.displayName || bot.username), el('span', `badge ${bot.status}`, bot.status));
        if (p) head.append(el('span', 'muted', `Combat ${fmt(p.combatLevel)}`));
        node.append(head, el('p', 'activity', bot.activity.label));
        const detail = activityDetail(bot);
        if (detail) node.append(detail);
        if (p) {
            const hp = el('div', 'hp');
            const bar = el('span');
            bar.style.width = `${Math.max(0, Math.min(100, p.maxHp ? (100 * p.hp) / p.maxHp : 0))}%`;
            hp.append(bar, el('em', null, `HP ${fmt(p.hp)} / ${fmt(p.maxHp)}`));
            const where = [`(${p.x}, ${p.z})`, p.level ? `plane ${p.level}` : null, region(bot), `run ${fmt(p.runEnergy)}%`].filter(Boolean).join(' · ');
            node.append(hp, el('p', 'where', where));
        }
        const details = el('details');
        details.open = selected === bot.username || (bot.status === 'active' && bots.filter(b => b.status === 'active').length <= 3);
        details.append(el('summary', null, 'Stats, inventory & equipment'));
        if (bot.skills.length) {
            const skills = el('div', 'live-skills');
            const total = bot.skills.reduce((sum, s) => sum + (s.baseLevel || 0), 0);
            for (const s of bot.skills.filter(skill => !/^Stat\d+$/.test(skill.name))) {
                const cell = el('span', bot.recentXp[s.name] ? 'skill gaining' : 'skill');
                cell.title = `${s.name}: ${fmt(s.experience)} XP${bot.recentXp[s.name] ? ` (+${fmt(bot.recentXp[s.name])} last minute)` : ''}`;
                cell.append(el('small', null, s.name), el('b', null, s.level === s.baseLevel ? s.level : `${s.level}/${s.baseLevel}`), el('em', null, fmt(s.experience)));
                skills.append(cell);
            }
            details.append(el('h3', null, `Skills · total ${total}`), skills);
        }
        details.append(el('h3', null, `Inventory · ${bot.inventory.length}/28`), itemGrid(bot.inventory, true, bot.player ? 'Empty' : 'Not known while offline'));
        details.append(el('h3', null, 'Equipment'), itemGrid(bot.equipment, false, bot.player ? 'Nothing worn' : 'Not known while offline'));
        if (bot.messages.length) {
            const log = el('ul', 'messages');
            for (const m of bot.messages) log.append(el('li', null, m));
            details.append(el('h3', null, 'Recent game messages'), log);
        }
        node.append(details);
        node.addEventListener('click', event => {
            if (!event.target.closest('details')) select(bot.username, false);
        });
        return node;
    }

    function renderList(payload) {
        const open = new Set([...list.querySelectorAll('article')].filter(a => a.querySelector('details')?.open).map(a => a.dataset.bot));
        list.replaceChildren(...bots.map(bot => {
            const node = card(bot);
            if (open.has(bot.username)) node.querySelector('details').open = true;
            return node;
        }));
        const online = bots.filter(b => b.status === 'active').length;
        const parts = [`${online} online of ${bots.length} accounts`];
        if (payload.ageMs !== null && payload.ageMs !== undefined) parts.push(`snapshot ${(payload.ageMs / 1000).toFixed(1)} s old`);
        if (payload.fleet) parts.push(payload.fleet.running ? 'fleet supervisor running' : 'fleet supervisor idle');
        if (payload.fleet && payload.fleet.focus) parts.push(`event focus: ${payload.fleet.focus}`);
        parts.push(`refresh every ${payload.ticks} ticks (${(payload.refreshMs / 1000).toFixed(1)} s)`);
        statusLine.textContent = parts.join(' · ');
        statusLine.classList.toggle('stale', !!payload.stale);
        const warning = document.getElementById('live-warning');
        warning.textContent = payload.error || '';
        warning.hidden = !payload.error;
    }

    async function poll() {
        try {
            const response = await fetch(api, { cache: 'no-store', headers: { Accept: 'application/json' } });
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const payload = await response.json();
            bots = payload.bots || [];
            renderMarkers();
            renderList(payload);
            if (!centred) {
                const first = bots.find(b => b.player && b.player.map);
                if (first) { centreOn(first.player.map[0], first.player.map[1]); centred = true; }
            }
        } catch (error) {
            statusLine.textContent = `Live data unavailable (${error.message}); retrying…`;
            statusLine.classList.add('stale');
        } finally {
            setTimeout(poll, refreshMs);
        }
    }

    // drag to pan, wheel / buttons to zoom
    let drag = null;
    viewport.addEventListener('pointerdown', event => {
        if (event.target.closest('.live-marker')) return;
        drag = { x: event.clientX, y: event.clientY, left: viewport.scrollLeft, top: viewport.scrollTop };
        viewport.setPointerCapture(event.pointerId);
        viewport.classList.add('dragging');
    });
    viewport.addEventListener('pointermove', event => {
        if (!drag) return;
        viewport.scrollLeft = drag.left - (event.clientX - drag.x);
        viewport.scrollTop = drag.top - (event.clientY - drag.y);
    });
    const endDrag = () => { drag = null; viewport.classList.remove('dragging'); };
    viewport.addEventListener('pointerup', endDrag);
    viewport.addEventListener('pointercancel', endDrag);
    viewport.addEventListener('wheel', event => {
        event.preventDefault();
        const rect = viewport.getBoundingClientRect();
        zoomTo(scale * Math.pow(1.0015, -event.deltaY), event.clientX - rect.left, event.clientY - rect.top);
    }, { passive: false });
    document.getElementById('zoom-in').addEventListener('click', () => zoomTo(scale * 1.5));
    document.getElementById('zoom-out').addEventListener('click', () => zoomTo(scale / 1.5));

    fetch(root.dataset.meta, { cache: 'force-cache' })
        .then(r => (r.ok ? r.json() : null))
        .then(data => {
            if (data && data.width) meta = data;
            for (const label of meta.labels || []) {
                const node = el('span', `map-label size-${label.size}`);
                for (const [i, line] of label.text.split('/').entries()) {
                    if (i) node.append(el('br'));
                    node.append(document.createTextNode(line));
                }
                canvas.append(node);
                labelNodes.push({ node, label });
            }
            layout();
        })
        .catch(() => layout());
    image.addEventListener('error', () => { canvas.classList.add('no-image'); });
    layout();
    poll();
})();
