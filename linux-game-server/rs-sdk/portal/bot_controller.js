// Bot controller page (/rs-sdk/bot-controller/): polls /rs-sdk/api/controller and lets the
// owner set per-bot desired state (run a registry routine, stop, hold, clear). Served as a
// static file so the page CSP stays `script-src 'self'` (no inline JS).

// Pure rules (arg validation, eligibility, labels, filters), DOM-free so test_controller.py
// can exercise them with node.
const ControllerLogic = (() => {
    'use strict';
    const routineById = (registry, id) => (registry && Array.isArray(registry.routines) ? registry.routines.find(r => r.id === id) : null) || null;
    const defaults = spec => Object.fromEntries((spec ? spec.args : []).map(a => [a.name, a.default ?? (a.type === 'enum' ? a.values[0] : a.min)]));
    // Same rules as the portal and the daemon: enum values from the list, integers within bounds, no extra keys.
    const validateArgs = (spec, raw) => {
        const args = {};
        const errors = {};
        if (!spec) return { ok: false, args, errors: { routine: 'choose a routine' } };
        for (const a of spec.args) {
            const v = raw ? raw[a.name] : undefined;
            if (a.type === 'enum') {
                if (typeof v === 'string' && a.values.includes(v)) args[a.name] = v;
                else errors[a.name] = `one of ${a.values.join(', ')}`;
            } else {
                const text = typeof v === 'number' ? String(v) : String(v ?? '').trim();
                const n = /^\d{1,7}$/.test(text) ? Number(text) : NaN;
                if (Number.isSafeInteger(n) && n >= a.min && n <= a.max) args[a.name] = n;
                else errors[a.name] = `whole number ${a.min}–${a.max}`;
            }
        }
        return { ok: Object.keys(errors).length === 0, args, errors };
    };
    // Routines every selected bot may run (bulk form).
    const commonEligible = rows => {
        if (!rows.length) return [];
        return rows.map(r => r.eligible || []).reduce((acc, list) => acc.filter(id => list.includes(id)));
    };
    const TONES = {
        running: 'ok', finished: 'ok', stopped: 'ok', done: 'ok', starting: 'busy', stopping: 'busy', switching: 'busy', pending: 'busy',
        blocked: 'warn', foreign: 'warn', expired: 'warn', unknown: 'warn', held: 'muted', idle: 'muted', rejected: 'bad', failed: 'bad', error: 'bad',
    };
    const tone = state => TONES[state] || 'muted';
    const desiredText = d => {
        if (!d) return 'No request';
        const what = d.action === 'run' ? `Run ${d.routine} ${Object.values(d.args || {}).join(' ')}`.trim() : d.action === 'stop' ? 'Stop (log out)' : 'Hold (hands off)';
        return `${what} · r${d.rev}`;
    };
    const ago = ms => {
        if (ms === null || ms === undefined || !Number.isFinite(ms)) return '?';
        const s = Math.max(0, Math.round(ms / 1000));
        return s < 90 ? `${s}s` : s < 5400 ? `${Math.round(s / 60)}m` : `${Math.round(s / 3600)}h`;
    };
    const heartbeat = p => {
        if (!p || !p.daemon) return { tone: 'bad', text: p && p.error ? p.error : 'The controller daemon has not connected yet.' };
        const d = p.daemon;
        const bits = [`Controller daemon on ${d.host || '?'}`, p.online ? `heartbeat ${ago(p.ageMs)} ago` : `OFFLINE (last heartbeat ${ago(p.ageMs)} ago)`];
        if (d.commit) bits.push(`commit ${d.commit}`);
        if (d.dryRun) bits.push('DRY RUN: decisions only, nothing is started or stopped');
        if (!d.portalOk) bits.push('it could not read requests last cycle');
        if (d.error) bits.push(d.error);
        return { tone: !p.online ? 'bad' : d.dryRun || d.error ? 'warn' : 'ok', text: bits.join(' · ') };
    };
    const SHOWS = ['all', 'active'];
    const validShow = v => (SHOWS.includes(v) ? v : null);
    const visible = (row, show) => show !== 'active' || !!(row.desired || row.presence === 'controlled' || row.presence === 'ghost' || (row.controller && row.controller.job));
    const parseSet = raw => {
        try {
            const value = JSON.parse(raw || '[]');
            return new Set(Array.isArray(value) ? value.filter(v => typeof v === 'string') : []);
        } catch {
            return new Set();
        }
    };
    return { routineById, defaults, validateArgs, commonEligible, tone, desiredText, ago, heartbeat, validShow, visible, parseSet };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = ControllerLogic;

(() => {
    'use strict';
    if (typeof document === 'undefined') return;
    const root = document.getElementById('ctl');
    if (!root) return;
    const L = ControllerLogic;
    const api = root.dataset.api;
    const postUrl = root.dataset.post;
    const refreshMs = Math.max(1000, Number(root.dataset.refreshMs) || 3000);
    const list = document.getElementById('ctl-bots');
    const daemonLine = document.getElementById('ctl-daemon');
    const authLine = document.getElementById('ctl-auth');
    const pauseLine = document.getElementById('ctl-pause');
    const flash = document.getElementById('ctl-flash');
    const empty = document.getElementById('ctl-empty');
    const bulk = document.getElementById('ctl-bulk');
    const bulkForm = document.getElementById('ctl-bulk-form');
    const selectedCount = document.getElementById('ctl-selected');
    const filterButtons = [...document.querySelectorAll('#ctl-filter [data-show]')];
    const store = kind => { try { return window[kind]; } catch { return null; } };
    const EXPANDED_KEY = 'rs-sdk-ctl-expanded', SELECTED_KEY = 'rs-sdk-ctl-selected', SHOW_KEY = 'rs-sdk-ctl-show';
    const expanded = L.parseSet(store('sessionStorage')?.getItem(EXPANDED_KEY));
    const selected = L.parseSet(store('sessionStorage')?.getItem(SELECTED_KEY));
    let show = L.validShow(store('localStorage')?.getItem(SHOW_KEY)) || 'all';
    const cards = new Map();
    let payload = null;
    let registrySig = '';
    let busy = false;

    const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text !== undefined) n.textContent = text; return n; };
    const save = () => {
        store('sessionStorage')?.setItem(EXPANDED_KEY, JSON.stringify([...expanded]));
        store('sessionStorage')?.setItem(SELECTED_KEY, JSON.stringify([...selected]));
    };
    const canWrite = () => !!(payload && payload.auth && payload.auth.canWrite && payload.auth.csrf);

    function say(text, bad) {
        flash.hidden = !text;
        flash.textContent = text || '';
        flash.classList.toggle('bad', !!bad);
    }

    async function send(bots, action, routine, args) {
        if (!canWrite() || busy) return false;
        busy = true;
        try {
            const body = { bots, action };
            if (action === 'run') Object.assign(body, { routine, args });
            const res = await fetch(postUrl, {
                method: 'POST', credentials: 'same-origin', cache: 'no-store',
                headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': payload.auth.csrf }, body: JSON.stringify(body),
            });
            const out = await res.json().catch(() => ({}));
            if (!res.ok) {
                const detail = out.bots ? ' ' + Object.entries(out.bots).map(([b, e]) => `${b}: ${e}`).join('; ') : '';
                say(`${out.error || `Request failed (HTTP ${res.status})`}${detail}`, true);
                return false;
            }
            say(`${action === 'run' ? `Start ${routine}` : action[0].toUpperCase() + action.slice(1)} recorded for ${bots.join(', ')}; the daemon applies it within a few seconds.`);
            poll();
            return true;
        } catch (err) {
            say(`Request failed: ${err.message || err}`, true);
            return false;
        } finally {
            busy = false;
        }
    }

    // Routine picker + argument fields + action buttons. Kept across refreshes (values persist);
    // rebuilt only when the eligible routines or the registry change.
    function buildForm(container, eligible, botsOf, opts = {}) {
        container.replaceChildren();
        const registry = payload.registry;
        const form = el('form', 'ctl-actions');
        form.noValidate = true;
        const pick = el('select');
        pick.setAttribute('aria-label', 'Routine');
        for (const id of eligible) {
            const spec = L.routineById(registry, id);
            const o = el('option', '', spec ? spec.label : id);
            o.value = id;
            pick.append(o);
        }
        const fields = el('div', 'ctl-fields');
        const desc = el('p', 'ctl-desc');
        const errors = el('p', 'ctl-errors');
        const inputs = {};
        const renderFields = () => {
            fields.replaceChildren();
            for (const k of Object.keys(inputs)) delete inputs[k];
            const spec = L.routineById(registry, pick.value);
            desc.textContent = spec ? spec.description : '';
            const values = L.defaults(spec);
            for (const a of spec ? spec.args : []) {
                const label = el('label', 'ctl-field');
                label.append(el('span', '', a.label));
                let input;
                if (a.type === 'enum') {
                    input = el('select');
                    for (const v of a.values) { const o = el('option', '', v); o.value = v; input.append(o); }
                } else {
                    input = el('input');
                    Object.assign(input, { type: 'number', min: a.min, max: a.max, step: 1, inputMode: 'numeric' });
                }
                input.value = String(values[a.name]);
                input.name = a.name;
                label.append(input);
                fields.append(label);
                inputs[a.name] = input;
            }
        };
        pick.addEventListener('change', renderFields);
        renderFields();
        const button = (label, action, cls) => {
            const b = el('button', cls, label);
            b.type = 'button';
            b.dataset.action = action;
            b.addEventListener('click', async ev => {
                ev.stopPropagation();
                const bots = botsOf();
                if (!bots.length) { say('Select at least one bot.', true); return; }
                errors.textContent = '';
                if (action === 'run') {
                    const spec = L.routineById(registry, pick.value);
                    const raw = Object.fromEntries(Object.entries(inputs).map(([k, i]) => [k, i.value]));
                    const v = L.validateArgs(spec, raw);
                    if (!v.ok) { errors.textContent = Object.entries(v.errors).map(([k, e]) => `${k}: ${e}`).join('; '); return; }
                    await send(bots, 'run', spec.id, v.args);
                } else {
                    if (action === 'stop' && bots.length > 1 && !window.confirm(`Log out ${bots.length} bots?`)) return;
                    await send(bots, action);
                }
            });
            return b;
        };
        const buttons = el('div', 'ctl-buttons');
        if (eligible.length) {
            form.append(pick, fields, desc);
            buttons.append(button('Start', 'run', 'ctl-start'));
        } else {
            form.append(el('p', 'ctl-desc', opts.noneText || 'No registry routine is launchable for this bot.'));
        }
        buttons.append(button('Stop', 'stop', 'ctl-stop'), button('Hold', 'hold', 'ctl-hold'), button('Clear request', 'clear', 'ctl-clear'));
        form.append(buttons, errors);
        form.addEventListener('submit', ev => ev.preventDefault());
        container.append(form);
        setDisabled(container);
    }

    function setDisabled(container) {
        const off = !canWrite();
        for (const b of container.querySelectorAll('button')) b.disabled = off;
    }

    function makeCard(row) {
        const node = el('div', 'live-bot ctl-card');
        node.dataset.bot = row.username;
        const summary = el('div', 'ctl-summary');
        const head = el('div', 'ctl-head');
        const check = el('input');
        check.type = 'checkbox';
        check.setAttribute('aria-label', `Select ${row.username}`);
        check.addEventListener('click', ev => ev.stopPropagation());
        check.addEventListener('change', () => { if (check.checked) selected.add(row.username); else selected.delete(row.username); save(); renderBulk(); });
        const name = el('b', 'ctl-name', row.username);
        const presence = el('span', 'ctl-badge');
        const state = el('span', 'ctl-badge');
        head.append(check, name, presence, state);
        const activity = el('p', 'line ctl-activity');
        const desired = el('p', 'line ctl-desired');
        const message = el('p', 'line ctl-message');
        summary.append(head, activity, desired, message);
        const detail = el('div', 'ctl-detail');
        const info = el('dl', 'ctl-info');
        const formBox = el('div', 'ctl-form');
        detail.append(info, formBox);
        node.append(summary, detail);
        summary.addEventListener('click', () => setExpanded(row.username, !expanded.has(row.username)));
        detail.addEventListener('click', ev => ev.stopPropagation());
        const card = { node, check, presence, state, activity, desired, message, info, formBox, detail, formSig: '' };
        cards.set(row.username, card);
        return card;
    }

    function setExpanded(name, open) {
        if (open) expanded.add(name); else expanded.delete(name);
        save();
        const card = cards.get(name);
        if (card) { card.node.classList.toggle('expanded', open); card.detail.hidden = !open; }
    }

    function infoRows(row) {
        const c = row.controller || {};
        const rows = [];
        if (c.job) rows.push(['Job', `${c.job.kind === 'stop' ? 'logout' : `${c.job.routine} ${c.job.args.join(' ')}`} · pid ${c.job.pid} · ${L.ago(Date.now() - c.job.startedAt)}${c.job.stopping ? ' · stopping' : ''}`]);
        rows.push(['Gates', c.gates && c.gates.length ? c.gates.join('; ') : 'none (read-only; cleared only on the workstation)']);
        if (c.foreign && c.foreign.length) rows.push(['Other controllers', c.foreign.join('; ')]);
        if (c.lastResult) rows.push(['Last job', `${c.lastResult.kind} r${c.lastResult.rev}: ${c.lastResult.rc === 0 ? 'exit 0' : c.lastResult.rc === null ? 'no result' : `exit ${c.lastResult.rc}`} · ${L.ago(Date.now() - c.lastResult.endedAt)} ago`]);
        if (row.desired) rows.push(['Requested', `${L.desiredText(row.desired)} · by ${row.desired.by || '?'} · ${L.ago(Date.now() - row.desired.at)} ago`]);
        if (row.phase) rows.push(['Routine phase', `${row.routine}: ${row.phase}`]);
        return rows;
    }

    function fillCard(card, row) {
        const c = row.controller;
        card.check.checked = selected.has(row.username);
        card.check.disabled = !row.launchable;
        card.presence.textContent = row.presence;
        card.presence.className = `ctl-badge presence-${row.presence}`;
        const st = c ? c.state : 'no report';
        card.state.textContent = st;
        card.state.className = `ctl-badge tone-${L.tone(c && c.state)}`;
        card.activity.textContent = row.activity || (row.presence === 'offline' ? 'Offline' : '—');
        card.desired.textContent = L.desiredText(row.desired);
        card.message.textContent = c && c.message ? c.message : row.launchable ? '' : 'Not launchable from the controller';
        card.message.className = `line ctl-message tone-${L.tone(c && c.state)}`;
        card.info.replaceChildren(...infoRows(row).flatMap(([k, v]) => [el('dt', '', k), el('dd', '', v)]));
        const sig = `${registrySig}|${row.launchable}|${row.eligible.join(',')}`;
        if (sig !== card.formSig) {
            card.formSig = sig;
            if (row.launchable) buildForm(card.formBox, row.eligible, () => [row.username]);
            else card.formBox.replaceChildren(el('p', 'ctl-desc', 'This account is not launchable from the controller (registry exclusion).'));
        }
        setDisabled(card.formBox);
        const open = expanded.has(row.username);
        card.node.classList.toggle('expanded', open);
        card.detail.hidden = !open;
        card.node.hidden = !L.visible(row, show);
    }

    let bulkSig = '';
    function renderBulk() {
        if (!payload) return;
        const rows = payload.bots.filter(r => selected.has(r.username) && r.launchable);
        selectedCount.textContent = String(rows.length);
        const eligible = L.commonEligible(rows);
        const sig = `${registrySig}|${rows.map(r => r.username).join(',')}|${eligible.join(',')}`;
        if (sig !== bulkSig) {
            bulkSig = sig;
            buildForm(bulkForm, eligible, () => payload.bots.filter(r => selected.has(r.username) && r.launchable).map(r => r.username),
                { noneText: rows.length ? 'No routine is launchable for every selected bot.' : 'Select bots with the checkboxes.' });
        }
        setDisabled(bulkForm);
    }

    function render() {
        const hb = L.heartbeat(payload);
        daemonLine.textContent = hb.text;
        daemonLine.className = `note live-status tone-${hb.tone}`;
        const auth = payload.auth || {};
        authLine.textContent = auth.canWrite ? `Signed in as ${auth.login} (owner): changes are allowed and audited.` : (auth.reason || 'Read-only.');
        authLine.className = `note ${auth.canWrite ? 'tone-ok' : 'tone-warn'}`;
        pauseLine.hidden = !(payload.fleet && payload.fleet.pause);
        pauseLine.textContent = 'Fleet-wide pause (focus.json) is latched: the controller starts nothing until the owner resolves it on the workstation.';
        if (payload.registryError) say(`Registry from the daemon was rejected: ${payload.registryError}`, true);
        const sig = JSON.stringify(payload.registry);
        if (sig !== registrySig) registrySig = sig;
        const seen = new Set();
        let shown = 0;
        payload.bots.forEach((row, index) => {
            seen.add(row.username);
            const card = cards.get(row.username) || makeCard(row);
            fillCard(card, row);
            if (list.children[index] !== card.node) list.insertBefore(card.node, list.children[index] || null);
            if (!card.node.hidden) shown++;
        });
        for (const [name, card] of cards) if (!seen.has(name)) { card.node.remove(); cards.delete(name); }
        empty.hidden = shown > 0;
        empty.textContent = payload.bots.length ? 'No bot matches this filter.' : 'No bot accounts known yet.';
        const counts = { all: payload.bots.length, active: payload.bots.filter(r => L.visible(r, 'active')).length };
        for (const b of filterButtons) {
            b.setAttribute('aria-pressed', String(b.dataset.show === show));
            b.querySelector('.n').textContent = String(counts[b.dataset.show]);
        }
        renderBulk();
    }

    async function poll() {
        try {
            const res = await fetch(api, { cache: 'no-store', credentials: 'same-origin' });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            payload = await res.json();
            render();
        } catch (err) {
            daemonLine.textContent = `Controller state unavailable: ${err.message || err}`;
            daemonLine.className = 'note live-status tone-bad';
        }
    }

    for (const b of filterButtons) b.addEventListener('click', () => { show = L.validShow(b.dataset.show) || 'all'; store('localStorage')?.setItem(SHOW_KEY, show); if (payload) render(); });
    document.getElementById('ctl-expand-all').addEventListener('click', () => { if (payload) for (const r of payload.bots) if (L.visible(r, show)) setExpanded(r.username, true); });
    document.getElementById('ctl-collapse-all').addEventListener('click', () => { for (const name of [...expanded]) setExpanded(name, false); });
    document.getElementById('ctl-select-none').addEventListener('click', () => { selected.clear(); save(); if (payload) render(); });
    bulk.addEventListener('toggle', renderBulk);
    poll();
    setInterval(() => { if (!document.hidden) poll(); }, refreshMs);
})();
