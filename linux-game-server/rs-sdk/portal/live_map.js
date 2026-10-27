// Live fleet map for /rs-sdk/live-map. Read-only: polls /rs-sdk/api/live and renders.
// Served as a static file so the page CSP can stay `script-src 'self'` (no inline JS).

// Pure view-state rules (filter choice, counts, expanded set), kept DOM-free so
// test_live.py can exercise them with node.
const LiveLogic = (() => {
    'use strict';
    const SHOWS = ['all', 'bots', 'players'];
    const validShow = value => (SHOWS.includes(value) ? value : null);
    // ?show= wins over the remembered choice; default All.
    const initialShow = (search, stored) => validShow(new URLSearchParams(search || '').get('show')) || validShow(stored) || 'all';
    // Query string with show set, keeping every other parameter (e.g. ?ticks=N).
    const withShow = (search, show) => {
        const params = new URLSearchParams(search || '');
        params.set('show', show);
        return `?${params}`;
    };
    const visible = (kind, show) => show === 'all' || (show === 'bots' && kind === 'bot') || (show === 'players' && kind === 'player');
    const counts = (bots, others) => ({ all: bots.length + others.length, bots: bots.length, players: others.length });
    const parseExpanded = raw => {
        try {
            const value = JSON.parse(raw || '[]');
            return new Set(Array.isArray(value) ? value.filter(v => typeof v === 'string') : []);
        } catch {
            return new Set();
        }
    };
    return { SHOWS, validShow, initialShow, withShow, visible, counts, parseExpanded };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = LiveLogic;

(() => {
    'use strict';
    if (typeof document === 'undefined') return;
    const root = document.getElementById('live');
    if (!root) return;
    const api = root.dataset.api;
    const refreshMs = Math.max(600, Number(root.dataset.refreshMs) || 600);
    const viewport = document.getElementById('live-map');
    const canvas = document.getElementById('live-canvas');
    const image = document.getElementById('live-image');
    const statusLine = document.getElementById('live-status');
    const list = document.getElementById('live-bots');
    const empty = document.getElementById('live-empty');
    const filterButtons = [...document.querySelectorAll('#live-filter [data-show]')];
    const SHOW_KEY = 'rs-sdk-live-show';
    const EXPANDED_KEY = 'rs-sdk-live-expanded';
    let meta = { width: 1920, height: 3328, originX: 1792, labels: [] };
    let scale = 2; // screen pixels per tile
    let bots = [];
    let others = []; // non-fleet players in the world: name + position only
    let selected = null;
    let centred = false;
    let loaded = false; // first payload rendered
    const markers = new Map();
    const labelNodes = [];
    const cards = new Map(); // card key -> { node, summary, toggle, detail, kind }
    let cardSeq = 0;

    const storage = kind => {
        try { return window[kind]; } catch { return null; }
    };
    const remember = (kind, key, value) => {
        try { storage(kind)?.setItem(key, value); } catch { /* private mode / quota: keep in memory only */ }
    };
    let show = LiveLogic.initialShow(location.search, storage('localStorage')?.getItem(SHOW_KEY));
    const expanded = LiveLogic.parseExpanded(storage('sessionStorage')?.getItem(EXPANDED_KEY));

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
    const PRESENCE_LABEL = { controlled: 'controlled', ghost: 'no controller', offline: 'offline', unknown: 'presence unknown' };
    const PRESENCE_TITLE = { controlled: 'In the world, driven by an SDK client', ghost: 'In the world with NO controller (SDK client disconnected)', offline: 'Not in the world', unknown: 'World player list unavailable' };
    const inWorld = bot => bot.presence === 'controlled' || bot.presence === 'ghost';
    const words = key => key.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase();
    const nameOf = bot => bot.displayName || bot.username;

    function layout() {
        canvas.style.width = `${meta.width * scale}px`;
        canvas.style.height = `${meta.height * scale}px`;
        for (const { node, label } of labelNodes) {
            node.style.left = `${label.x * scale}px`;
            node.style.top = `${label.y * scale}px`;
            node.hidden = scale < (label.size === 2 ? 0.5 : label.size === 1 ? 1 : 2.5);
        }
        for (const [name, node] of markers) {
            const where = name.startsWith('world:')
                ? others.find(p => `world:${p.name}` === name)
                : (bots.find(b => b.username === name) || {}).player;
            if (where && where.map) {
                node.style.left = `${(where.map[0] + 0.5) * scale}px`;
                node.style.top = `${(where.map[1] + 0.5) * scale}px`;
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

    function nearest(map) {
        if (!map) return null;
        const [col, row] = map;
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
            node.querySelector('.tag').textContent = nameOf(bot);
            node.title = `${nameOf(bot)}: ${bot.activity.label}`;
            node.classList.toggle('selected', selected === bot.username);
            node.classList.toggle('fighting', !!bot.player.inCombat);
            node.classList.toggle('offline', !inWorld(bot));
            node.classList.toggle('ghost', bot.presence === 'ghost');
            if (bot.presence === 'ghost') node.title = `${nameOf(bot)}: IN WORLD WITH NO CONTROLLER`;
            node.hidden = !LiveLogic.visible('bot', show);
        }
        for (const p of others) {
            if (!p.map) continue;
            const key = `world:${p.name}`;
            live.add(key);
            let node = markers.get(key);
            if (!node) {
                node = el('span', 'live-marker other');
                node.append(el('span', 'dot'), el('span', 'tag', p.name));
                canvas.append(node);
                markers.set(key, node);
            }
            node.title = `${p.name} (other player, not in the fleet) · (${p.x}, ${p.z})`;
            node.hidden = !LiveLogic.visible('player', show);
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
        for (const card of list.children) card.classList.toggle('selected', !!card.dataset.bot && card.dataset.bot === name);
        if (scroll) {
            const card = list.querySelector(`[data-bot="${CSS.escape(name)}"]`);
            if (card && !card.hidden) card.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        }
        renderMarkers();
    }

    function itemGrid(items, slots, emptyText) {
        const grid = el('div', slots ? 'live-items inventory' : 'live-items');
        if (!items.length) grid.append(el('span', 'muted', emptyText));
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
            const counted = Object.entries(s.counts || {});
            if (counted.length) {
                const tally = el('span', 'counts');
                for (const [k, v] of counted) tally.append(el('span', 'count', `${words(k)} ${fmt(v)}`));
                row('Counts', tally);
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

    // One-line text that truncates with an ellipsis; the title keeps the full text.
    const line = (cls, text) => {
        const node = el('p', `line ${cls}`, text);
        node.title = text;
        return node;
    };

    function hpBar(p) {
        const hp = el('div', 'hp');
        if (!p || p.hp === null || p.hp === undefined) {
            hp.classList.add('unknown');
            hp.append(el('em', null, 'HP unknown'));
            return hp;
        }
        const bar = el('span');
        bar.style.width = `${Math.max(0, Math.min(100, p.maxHp ? (100 * p.hp) / p.maxHp : 0))}%`;
        hp.append(bar, el('em', null, `HP ${fmt(p.hp)} / ${fmt(p.maxHp)}`));
        return hp;
    }

    // Fixed-height collapsed view: name, status, combat, HP, activity, position / nearest town.
    function botSummary(bot) {
        const p = bot.player;
        const presence = bot.presence || 'unknown';
        const head = el('header');
        const name = el('b', null, nameOf(bot));
        name.title = nameOf(bot);
        head.append(name);
        if (p && p.combatLevel !== null && p.combatLevel !== undefined) head.append(el('span', 'combat', `Cb ${fmt(p.combatLevel)}`));
        const badge = el('span', `badge ${presence}`, PRESENCE_LABEL[presence] || presence);
        badge.title = PRESENCE_TITLE[presence] || presence;
        head.append(badge);
        if (presence === 'controlled' && bot.status !== 'active') head.append(el('span', `badge ${bot.status}`, bot.status));
        const where = p
            ? [nearest(p.map), `(${p.x}, ${p.z})`, p.level ? `plane ${p.level}` : null,
                p.runEnergy === null || p.runEnergy === undefined ? null : `run ${fmt(p.runEnergy)}%`].filter(Boolean).join(' · ')
            : 'Position unknown';
        return [head, hpBar(p), line('activity', bot.activity.label), line('where', where)];
    }

    function playerSummary(p) {
        const head = el('header');
        const name = el('b', null, p.name);
        name.title = p.name;
        const badge = el('span', 'badge other', 'player');
        badge.title = 'A real player, not a fleet account';
        head.append(name, badge);
        const where = [nearest(p.map), `(${p.x}, ${p.z})`, p.level ? `plane ${p.level}` : null].filter(Boolean).join(' · ');
        return [head, el('div', 'hp placeholder'), line('activity muted', 'Not in the fleet: name and position only'), line('where', where)];
    }

    function botDetail(bot) {
        const parts = [];
        if (bot.presence === 'ghost') {
            parts.push(el('p', 'ghost-note', bot.lastKnownAt
                ? `Position is live (world list); stats, HP and items are last-known from ${ago(bot.lastKnownAt)} ago.`
                : 'Position is live (world list); no stats known since this publisher started.'));
        }
        const activity = activityDetail(bot);
        if (activity) parts.push(activity);
        if (bot.skills.length) {
            const skills = el('div', 'live-skills');
            const total = bot.skills.reduce((sum, s) => sum + (s.baseLevel || 0), 0);
            for (const s of bot.skills.filter(skill => !/^Stat\d+$/.test(skill.name))) {
                const cell = el('span', bot.recentXp[s.name] ? 'skill gaining' : 'skill');
                cell.title = `${s.name}: ${fmt(s.experience)} XP${bot.recentXp[s.name] ? ` (+${fmt(bot.recentXp[s.name])} last minute)` : ''}`;
                cell.append(el('small', null, s.name), el('b', null, s.level === s.baseLevel ? s.level : `${s.level}/${s.baseLevel}`), el('em', null, fmt(s.experience)));
                skills.append(cell);
            }
            parts.push(el('h3', null, `Skills · total ${total}`), skills);
        }
        const known = bot.presence === 'controlled' || (bot.presence === 'ghost' && bot.lastKnownAt);
        parts.push(el('h3', null, `Inventory · ${bot.inventory.length}/28${bot.presence === 'ghost' ? ' (last known)' : ''}`), itemGrid(bot.inventory, true, known ? 'Empty' : 'Not known without a controller'));
        parts.push(el('h3', null, `Equipment${bot.presence === 'ghost' ? ' (last known)' : ''}`), itemGrid(bot.equipment, false, known ? 'Nothing worn' : 'Not known without a controller'));
        if (bot.messages.length) {
            const log = el('ul', 'messages');
            for (const m of bot.messages) log.append(el('li', null, m));
            parts.push(el('h3', null, 'Recent game messages'), log);
        }
        return parts;
    }

    // Cards are created once per key and updated in place on every refresh, so the
    // expand buttons keep focus and the page keeps its scroll position.
    function makeCard(key, kind) {
        const node = el('article', `live-bot ${kind === 'player' ? 'live-player' : ''}`.trim());
        node.dataset.key = key;
        const summary = el('div', 'live-summary');
        const actions = el('div', 'live-card-actions');
        const locate = el('button', 'live-locate', 'Show on map');
        locate.type = 'button';
        actions.append(locate);
        const card = { node, summary, kind, locate, toggle: null, detail: null, map: null };
        locate.addEventListener('click', () => {
            if (kind === 'bot') select(node.dataset.bot, false);
            else if (card.map) centreOn(card.map[0], card.map[1]);
        });
        node.append(summary, actions);
        if (kind === 'bot') {
            const id = `live-detail-${++cardSeq}`;
            const toggle = el('button', 'live-toggle');
            toggle.type = 'button';
            toggle.setAttribute('aria-controls', id);
            const detail = el('div', 'live-detail');
            detail.id = id;
            toggle.addEventListener('click', () => setExpanded(node.dataset.bot, !expanded.has(node.dataset.bot)));
            actions.prepend(toggle);
            node.append(detail);
            card.toggle = toggle;
            card.detail = detail;
            node.addEventListener('click', event => {
                if (!event.target.closest('button, .live-detail')) select(node.dataset.bot, false);
            });
        } else {
            node.addEventListener('click', event => {
                if (!event.target.closest('button') && card.map) centreOn(card.map[0], card.map[1]);
            });
        }
        return card;
    }

    function fillDetail(card, bot) {
        const open = expanded.has(bot.username);
        card.node.classList.toggle('expanded', open);
        card.toggle.setAttribute('aria-expanded', String(open));
        card.toggle.textContent = open ? 'Hide details' : 'Details';
        card.toggle.setAttribute('aria-label', `${open ? 'Hide' : 'Show'} stats, inventory and equipment for ${nameOf(bot)}`);
        card.detail.hidden = !open;
        // Collapsed cards skip building the (large) detail DOM entirely.
        if (open) card.detail.replaceChildren(...botDetail(bot));
        else card.detail.replaceChildren();
    }

    function setExpanded(username, open) {
        if (open) expanded.add(username); else expanded.delete(username);
        remember('sessionStorage', EXPANDED_KEY, JSON.stringify([...expanded]));
        const card = cards.get(`bot:${username}`);
        const bot = bots.find(b => b.username === username);
        if (card && bot) fillDetail(card, bot);
    }

    function applyFilter() {
        const tally = LiveLogic.counts(bots, others);
        for (const button of filterButtons) {
            const value = button.dataset.show;
            button.setAttribute('aria-pressed', String(value === show));
            const count = button.querySelector('.n');
            if (count) count.textContent = String(tally[value]);
        }
        let shown = 0;
        for (const { node, kind } of cards.values()) {
            node.hidden = !LiveLogic.visible(kind, show);
            if (!node.hidden) shown += 1;
        }
        for (const [name, node] of markers) node.hidden = !LiveLogic.visible(name.startsWith('world:') ? 'player' : 'bot', show);
        if (empty) {
            empty.textContent = show === 'players' ? 'No other players are in the world right now.' : show === 'bots' ? 'No fleet accounts are published.' : 'Nobody to show yet.';
            empty.hidden = shown > 0 || !loaded;
        }
    }

    function setShow(next, persist) {
        show = LiveLogic.validShow(next) || 'all';
        if (persist) remember('localStorage', SHOW_KEY, show);
        const query = LiveLogic.withShow(location.search, show);
        if (query !== location.search) history.replaceState(history.state, '', `${location.pathname}${query}${location.hash}`);
        applyFilter();
    }

    function renderList(payload) {
        loaded = true;
        const wanted = [];
        for (const bot of bots) {
            const key = `bot:${bot.username}`;
            const card = cards.get(key) || makeCard(key, 'bot');
            cards.set(key, card);
            const { node } = card;
            node.dataset.bot = bot.username;
            node.classList.toggle('selected', selected === bot.username);
            node.classList.toggle('is-offline', !inWorld(bot));
            node.classList.toggle('is-ghost', bot.presence === 'ghost');
            card.summary.replaceChildren(...botSummary(bot));
            card.map = bot.player && bot.player.map;
            card.locate.disabled = !card.map;
            card.locate.setAttribute('aria-label', `Show ${nameOf(bot)} on the map`);
            fillDetail(card, bot);
            wanted.push(node);
        }
        for (const p of [...others].sort((x, y) => x.name.localeCompare(y.name))) {
            const key = `player:${p.name}`;
            const card = cards.get(key) || makeCard(key, 'player');
            cards.set(key, card);
            card.summary.replaceChildren(...playerSummary(p));
            card.map = p.map;
            card.locate.disabled = !card.map;
            card.locate.setAttribute('aria-label', `Show ${p.name} on the map`);
            wanted.push(card.node);
        }
        const keep = new Set(wanted);
        for (const [key, card] of cards) {
            if (!keep.has(card.node)) { card.node.remove(); cards.delete(key); }
        }
        // Reorder by moving only misplaced nodes, so unchanged cards (and focus) stay put.
        wanted.forEach((node, i) => {
            if (list.children[i] !== node) list.insertBefore(node, list.children[i] || null);
        });
        applyFilter();

        const world = payload.world || {};
        const controlled = bots.filter(b => b.presence === 'controlled').length;
        const ghosts = bots.filter(b => b.presence === 'ghost');
        const parts = [];
        if (world.ok) {
            parts.push(`Online in world: ${world.count}`);
            parts.push(`fleet ${controlled} controlled, ${ghosts.length} without controller, ${bots.length - controlled - ghosts.length} offline`);
            if (others.length) parts.push(`${others.length} other player${others.length === 1 ? '' : 's'}`);
        } else {
            parts.push(`${controlled} controlled of ${bots.length} accounts`, 'world player list unavailable');
        }
        if (payload.ageMs !== null && payload.ageMs !== undefined) parts.push(`snapshot ${(payload.ageMs / 1000).toFixed(1)} s old`);
        if (payload.fleet) parts.push(payload.fleet.running ? 'fleet supervisor running' : 'fleet supervisor idle');
        if (payload.fleet && payload.fleet.focus) parts.push(`event focus: ${payload.fleet.focus}`);
        parts.push(`refresh every ${payload.ticks} ticks (${(payload.refreshMs / 1000).toFixed(1)} s)`);
        statusLine.textContent = parts.join(' · ');
        statusLine.classList.toggle('stale', !!payload.stale);
        const warning = document.getElementById('live-warning');
        const problems = [payload.error, payload.available && !world.ok
            ? `Cannot read the game's player list (${world.error || 'unavailable'}): bots in the world without a controller cannot be detected right now.`
            : null].filter(Boolean);
        warning.textContent = problems.join(' ');
        warning.hidden = !problems.length;
        // The ghost banner ignores the filter: a bot without a controller always needs attention.
        let banner = document.getElementById('live-ghosts');
        if (!banner) {
            banner = el('p', 'note live-ghosts');
            banner.id = 'live-ghosts';
            statusLine.before(banner);
        }
        banner.textContent = ghosts.length
            ? `⚠ ${ghosts.length} bot${ghosts.length === 1 ? ' is' : 's are'} in the world with NO controller (SDK client disconnected): ${ghosts.map(nameOf).join(', ')}`
            : '';
        banner.hidden = !ghosts.length;
    }

    for (const button of filterButtons) button.addEventListener('click', () => setShow(button.dataset.show, true));
    document.getElementById('expand-all')?.addEventListener('click', () => {
        for (const bot of bots) if (LiveLogic.visible('bot', show)) expanded.add(bot.username);
        remember('sessionStorage', EXPANDED_KEY, JSON.stringify([...expanded]));
        for (const bot of bots) { const card = cards.get(`bot:${bot.username}`); if (card) fillDetail(card, bot); }
    });
    document.getElementById('collapse-all')?.addEventListener('click', () => {
        expanded.clear();
        remember('sessionStorage', EXPANDED_KEY, '[]');
        for (const bot of bots) { const card = cards.get(`bot:${bot.username}`); if (card) fillDetail(card, bot); }
    });
    setShow(show, false);

    async function poll() {
        try {
            const response = await fetch(api, { cache: 'no-store', headers: { Accept: 'application/json' } });
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const payload = await response.json();
            bots = payload.bots || [];
            others = (payload.world && payload.world.others) || [];
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
