// Bot controller page (/rs-sdk/bot-controller/): polls /rs-sdk/api/controller and lets the
// owner set per-account desired state (run a registry routine headless or in the browser view,
// stop, hold, clear) for fleet bots and his regular accounts. Headless runs show the job's live
// (sanitized) log; the browser view embeds the real game client (owner-only frame URL). Served
// as a static file so the page CSP stays `script-src 'self'` (no inline JS).

// Pure rules (arg validation, eligibility, labels, filters), DOM-free so test_controller.py
// can exercise them with node.
const ControllerLogic = (() => {
    'use strict';
    const routineById = (registry, id) => (registry && Array.isArray(registry.routines) ? registry.routines.find(r => r.id === id) : null) || null;
    const defaults = spec => Object.fromEntries((spec ? spec.args : []).map(a => [a.name, a.default ?? (a.type === 'enum' ? a.values[0] : a.min)]));
    // Durations (registry `unit: "seconds"`): Days / Hours / Minutes / Seconds boxes on the page, one whole number of
    // seconds on the wire. Every duration allows at most 7 days (the daemon and the portal refuse more); an arg may
    // allow less and then carries a maxNote saying why. Boxes carry over on change (90 min -> 1 h 30 min); a total
    // outside the arg's min..max is an inline error that disables Start (never clamped silently).
    const MAX_DURATION_S = 7 * 86400;
    const DURATION_PARTS = [['days', 'Days', 86400, 7], ['hours', 'Hours', 3600, 23], ['minutes', 'Minutes', 60, 59], ['seconds', 'Seconds', 1, 59]];
    const isDuration = a => !!a && a.type === 'int' && a.unit === 'seconds';
    const splitDuration = total => {
        let rest = Math.max(0, Math.floor(Number(total) || 0));
        const out = {};
        for (const [k, , size] of DURATION_PARTS) { out[k] = Math.floor(rest / size); rest -= out[k] * size; }
        return out;
    };
    const UNIT_TEXT = { days: 'd', hours: 'h', minutes: 'min', seconds: 's' };
    const durationText = total => {
        const parts = splitDuration(total);
        const bits = DURATION_PARTS.filter(([k]) => parts[k]).map(([k]) => `${parts[k]} ${UNIT_TEXT[k]}`);
        return bits.length ? bits.join(' ') : '0 s';
    };
    // Box texts -> total seconds; an empty box counts as 0. null total = a box is not a whole number >= 0.
    const durationTotal = raw => {
        let total = 0;
        for (const [k, , size] of DURATION_PARTS) {
            const text = String((raw || {})[k] ?? '').trim();
            if (text === '') continue;
            if (!/^\d{1,7}$/.test(text)) return null;
            total += Number(text) * size;
        }
        return total;
    };
    const durationError = (a, total) => {
        if (total < a.min) return `at least ${durationText(a.min)}`;
        if (total > a.max) return `at most ${durationText(a.max)}${a.max === MAX_DURATION_S ? ' (7 days)' : ''}`;
        return null;
    };
    // What the duration control shows for these box texts: total, summary, error (null when fine).
    const checkDuration = (a, raw) => {
        const total = durationTotal(raw);
        if (total === null) return { total: null, text: '', error: 'whole numbers only (0 or more) in each box' };
        return { total, text: `= ${durationText(total)}`, error: durationError(a, total) };
    };
    const durationRange = a => `${durationText(a.min)} to ${durationText(a.max)}`;
    // Same rules as the portal and the daemon: enum values from the list, integers within bounds, no extra keys.
    // `off(arg, chosen)` (optional): value -> reason for values this account cannot choose (greyed out on the page).
    const validateArgs = (spec, raw, off) => {
        const args = {};
        const errors = {};
        if (!spec) return { ok: false, args, errors: { routine: 'choose a routine' } };
        const chosen = {};   // valid-looking values, for the later args' lookups (an off value is still the choice)
        for (const a of spec.args) {
            const v = raw ? raw[a.name] : undefined;
            if (a.type === 'enum') {
                const allowed = allowedValues(a, chosen);
                const why = off ? off(a, chosen)[v] : undefined;
                if (typeof v === 'string' && allowed.includes(v)) chosen[a.name] = v;
                if (typeof v === 'string' && allowed.includes(v) && !why) args[a.name] = v;
                else errors[a.name] = why || `one of ${allowed.join(', ')}`;
            } else {
                const text = typeof v === 'number' ? String(v) : String(v ?? '').trim();
                const n = /^\d{1,7}$/.test(text) ? Number(text) : NaN;
                if (Number.isSafeInteger(n) && n >= a.min && n <= a.max) args[a.name] = n;
                else errors[a.name] = isDuration(a) ? (Number.isSafeInteger(n) && durationError(a, n)) || 'whole days, hours, minutes and seconds' : `whole number ${a.min}–${a.max}`;
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
    // With the registry, duration args read as e.g. "1 h 40 min" instead of "6000".
    const desiredText = (d, registry) => {
        if (!d) return 'No request';
        const spec = registry ? routineById(registry, d.routine) : null;
        const argText = ([k, v]) => { const a = spec && spec.args.find(x => x.name === k); return isDuration(a) && Number.isSafeInteger(v) ? durationText(v) : v; };
        const what = d.action === 'run' ? `Run ${d.routine} ${Object.entries(d.args || {}).map(argText).join(' ')}${d.mode === 'browser' ? ' (browser view)' : ''}`.trim() : d.action === 'stop' ? 'Stop' : 'Hold (hands off)';
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
    // Account filter (All / Bots / Regular), persisted like the live map's ?show=; plus an
    // independent "assigned / online only" toggle.
    const SHOWS = ['all', 'bots', 'regular'];
    const validShow = v => (SHOWS.includes(v) ? v : null);
    const initialShow = (search, stored) => validShow(new URLSearchParams(search || '').get('show')) || validShow(stored) || 'all';
    const withShow = (search, show) => {
        const params = new URLSearchParams(search || '');
        params.set('show', show);
        return `?${params.toString()}`;
    };
    const isActive = row => !!(row.desired || row.presence === 'controlled' || row.presence === 'ghost' || row.presence === 'online' || (row.controller && row.controller.job));
    const visible = (row, show, activeOnly) => {
        const type = row.type === 'player' ? 'regular' : 'bots';
        if (show && show !== 'all' && show !== type) return false;
        return !activeOnly || isActive(row);
    };
    const label = row => (row.type === 'player' && row.displayName ? `${row.displayName}` : row.username);
    // Headless always; the browser view only for session routines and one account at a time.
    const modesFor = (spec, count) => (spec && spec.runner === 'session' && count === 1 ? ['headless', 'browser'] : ['headless']);
    const showLog = row => !!(row && row.controller && Array.isArray(row.controller.log) && row.controller.log.length);
    const frameNote = row => `${row.type === 'player' ? `Log in as ${row.displayName || row.username} in the game view below (your password never touches the portal).` : 'The game view logs this bot in by itself.'} `
        + 'This game client is the account\u2019s only client and lives only while this page and its game view stay open: log out in the game before closing it, or the server keeps the player in the world for a few minutes.';
    // Dangerous routines (registry `danger`): a warning next to the routine and an explicit confirm before Start.
    const dangerOf = spec => (spec && typeof spec.danger === 'string' && spec.danger.trim() ? spec.danger : null);
    const optionLabel = spec => (dangerOf(spec) ? `\u26a0 ${spec.label} (dangerous)` : spec ? spec.label : '');
    const dangerConfirm = (spec, bots) => (dangerOf(spec)
        ? `${spec.label} is DANGEROUS for ${bots.join(', ')}:\n\n${spec.danger}\n\nStart it anyway?` : null);
    // Values an enum arg offers given the args before it (mirror of the daemon's allowedValues and the portal's
    // allowed_values): its valuesBy list for the chosen value of the earlier arg, else its fixed values.
    // renderFields re-renders the later fields when an earlier one changes.
    const allowedValues = (arg, chosen) => (arg.valuesBy ? (arg.valuesBy.map[(chosen || {})[arg.valuesBy.arg]] || []) : arg.values);
    const valueText = (arg, v) => (arg.valueLabels && arg.valueLabels[v]) || v;
    const BANK_ONLY = 'fleet bots bank their produce';
    // Why each value of `arg` is off for these accounts, given the earlier choices: registry playersOnly (fleet bots)
    // plus the daemon's per-account gathering choices (level, tool, hazard, full spot, not available yet).
    // accounts: [{ username, type, choices }] where choices = payload.gatherChoices[row.controller.gather[spec.id]].
    const offReasons = (arg, chosen, accounts) => {
        const out = {};
        const many = accounts.length > 1;
        const add = (who, v, why) => { if (why && !(v in out)) out[v] = many ? `${who}: ${why}` : why; };
        for (const acc of accounts) {
            if (acc.type !== 'player') for (const v of arg.playersOnly || []) add(acc.username, v, BANK_ONLY);
            const t = acc.choices && acc.choices.off ? acc.choices.off[arg.name] : null;
            if (!t || !t.map) continue;
            const reasons = t.map[t.by ? (chosen || {})[t.by] : ''] || {};
            for (const [v, why] of Object.entries(reasons)) add(acc.username, v, why);
        }
        return out;
    };
    // First value that is allowed and not off (keeps `current` when it still is).
    const pickValue = (allowed, off, current, fallback) => {
        if (allowed.includes(current) && !off[current]) return current;
        if (allowed.includes(fallback) && !off[fallback]) return fallback;
        return allowed.find(v => !off[v]) ?? (allowed.includes(fallback) ? fallback : allowed[0]);
    };
    const parseSet = raw => {
        try {
            const value = JSON.parse(raw || '[]');
            return new Set(Array.isArray(value) ? value.filter(v => typeof v === 'string') : []);
        } catch {
            return new Set();
        }
    };
    return { MAX_DURATION_S, DURATION_PARTS, isDuration, splitDuration, durationText, durationTotal, durationError, checkDuration, durationRange,
        routineById, defaults, validateArgs, commonEligible, tone, desiredText, ago, heartbeat, validShow, initialShow, withShow, visible, isActive, label, modesFor, showLog, frameNote, dangerOf, optionLabel, dangerConfirm, allowedValues, valueText, offReasons, pickValue, parseSet };
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
    const frameUrl = root.dataset.frame;
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
    const activeButton = document.getElementById('ctl-active');
    const EXPANDED_KEY = 'rs-sdk-ctl-expanded', SELECTED_KEY = 'rs-sdk-ctl-selected', SHOW_KEY = 'rs-sdk-ctl-show-type', ACTIVE_KEY = 'rs-sdk-ctl-active';
    const expanded = L.parseSet(store('sessionStorage')?.getItem(EXPANDED_KEY));
    const selected = L.parseSet(store('sessionStorage')?.getItem(SELECTED_KEY));
    let show = L.initialShow(location.search, store('localStorage')?.getItem(SHOW_KEY));
    let activeOnly = store('localStorage')?.getItem(ACTIVE_KEY) === '1';
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

    async function send(bots, action, routine, args, mode, confirmDanger) {
        if (!canWrite() || busy) return false;
        busy = true;
        try {
            const body = { bots, action };
            if (action === 'run') Object.assign(body, { routine, args, mode: mode || 'headless' }, confirmDanger ? { confirmDanger: true } : {});
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
            say(`${action === 'run' ? `Start ${routine}${mode === 'browser' ? ' (browser view)' : ''}` : action[0].toUpperCase() + action.slice(1)} recorded for ${bots.join(', ')}; the daemon applies it within a few seconds.`);
            await poll();
            if (action === 'run' && mode === 'browser' && bots.length === 1) openFrame(bots[0], 15);
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
        // Keep what the owner picked across rebuilds (registry or per-account choices changed).
        const prevPick = container.querySelector('select[aria-label="Routine"]')?.value;
        const prevValues = Object.fromEntries([...container.querySelectorAll('.ctl-fields [name]')].map(i => [i.name, i.value]));
        container.replaceChildren();
        const registry = payload.registry;
        const form = el('form', 'ctl-actions');
        form.noValidate = true;
        const pick = el('select');
        pick.setAttribute('aria-label', 'Routine');
        for (const id of eligible) {
            const spec = L.routineById(registry, id);
            const o = el('option', '', spec ? L.optionLabel(spec) : id);
            o.value = id;
            pick.append(o);
        }
        const fields = el('div', 'ctl-fields');
        const modeLabel = el('label', 'ctl-field ctl-mode');
        modeLabel.append(el('span', '', 'Client'));
        const modePick = el('select');
        modePick.name = 'mode';
        modeLabel.append(modePick);
        const desc = el('p', 'ctl-desc');
        const danger = el('p', 'ctl-danger');
        danger.setAttribute('role', 'alert');
        const errors = el('p', 'ctl-errors');
        const notes = el('p', 'ctl-desc ctl-notes');
        const inputs = {};
        // Per-account eligibility for this routine (gathering entries): the accounts the form acts on.
        const accountsFor = spec => (opts.accountsOf ? opts.accountsOf() : []).map(row => ({
            username: row.username, type: row.type,
            choices: spec && row.controller && row.controller.gather && payload.gatherChoices ? payload.gatherChoices[row.controller.gather[spec.id]] : null,
        }));
        const offFor = spec => { const accs = accountsFor(spec); return (a, chosen) => (a.type === 'enum' ? L.offReasons(a, chosen, accs) : {}); };
        const renderFields = (kept) => {
            // A kept duration is its total seconds (hidden input); an unparsable one falls back to the default.
            const kept0 = a => { const v = kept && kept[a.name] !== undefined ? String(kept[a.name]) : ''; return /^\d{1,7}$/.test(v) ? Number(v) : L.defaults(L.routineById(registry, pick.value))[a.name]; };
            fields.replaceChildren();
            for (const k of Object.keys(inputs)) delete inputs[k];
            const spec = L.routineById(registry, pick.value);
            desc.textContent = spec ? spec.description : '';
            const accs = accountsFor(spec);
            const noteText = [...new Set(accs.flatMap(a => (a.choices && a.choices.notes) || []))];
            notes.textContent = noteText.join(' ');
            notes.hidden = !noteText.length;
            const warn = L.dangerOf(spec);
            danger.hidden = !warn;
            danger.textContent = warn ? `\u26a0 Dangerous: ${warn}` : '';
            const values = L.defaults(spec);
            const modes = L.modesFor(spec, opts.single ? 1 : 2);
            const keep = modePick.value;
            modePick.replaceChildren(...modes.map(m => { const o = el('option', '', m === 'browser' ? 'Browser view (game in this page)' : 'Headless (workstation client, logs out at the end)'); o.value = m; return o; }));
            modePick.value = modes.includes(keep) ? keep : 'headless';
            modeLabel.hidden = modes.length < 2;
            const chosen = {};
            const off = offFor(spec);
            for (const a of spec ? spec.args : []) {
                if (L.isDuration(a)) {
                    const box = durationField(a, kept0(a), () => setDisabled(container));
                    fields.append(box.node);
                    inputs[a.name] = box.input;
                    continue;
                }
                const label = el('label', 'ctl-field');
                label.append(el('span', '', a.label));
                let input;
                const before = kept && kept[a.name] !== undefined ? kept[a.name] : values[a.name];
                if (a.type === 'enum') {
                    input = el('select');
                    const allowed = L.allowedValues(a, chosen);
                    const reasons = off(a, chosen);
                    for (const v of allowed) {
                        const o = el('option', '', reasons[v] ? `${L.valueText(a, v)} \u2014 ${reasons[v]}` : L.valueText(a, v));
                        o.value = v;
                        o.disabled = !!reasons[v];
                        if (reasons[v]) o.title = reasons[v];
                        input.append(o);
                    }
                    input.value = L.pickValue(allowed, reasons, String(before), a.default);
                    chosen[a.name] = input.value;
                    // A later arg may depend on this one: re-render the fields, keeping what still applies.
                    if (spec.args.some(b => b.valuesBy && b.valuesBy.arg === a.name) || spec.gather) {
                        input.addEventListener('change', () => renderFields(Object.fromEntries(Object.entries(inputs).map(([k, i]) => [k, i.value]))));
                    }
                } else {
                    input = el('input');
                    Object.assign(input, { type: 'number', min: a.min, max: a.max, step: 1, inputMode: 'numeric' });
                    input.value = String(before);
                }
                input.name = a.name;
                label.append(input);
                fields.append(label);
                inputs[a.name] = input;
            }
        };
        pick.addEventListener('change', () => renderFields());
        if (prevPick && eligible.includes(prevPick)) pick.value = prevPick;
        renderFields(prevPick === pick.value ? prevValues : undefined);
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
                    const v = L.validateArgs(spec, raw, offFor(spec));
                    if (!v.ok) { errors.textContent = Object.entries(v.errors).map(([k, e]) => `${k}: ${e}`).join('; '); return; }
                    const ask = L.dangerConfirm(spec, bots);
                    if (ask && !window.confirm(ask)) { say(`${spec.label} not started.`); return; }
                    await send(bots, 'run', spec.id, v.args, modeLabel.hidden ? 'headless' : modePick.value, !!ask);
                } else {
                    if (action === 'stop' && bots.length > 1 && !window.confirm(`Stop ${bots.length} accounts?`)) return;
                    await send(bots, action);
                }
            });
            return b;
        };
        const buttons = el('div', 'ctl-buttons');
        if (eligible.length) {
            form.append(pick, danger, fields, notes, modeLabel, desc);
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

    // Days / Hours / Minutes / Seconds boxes for a duration arg; the hidden input (name = the arg) holds the total
    // seconds that validateArgs and the request use. Carries on change (blur, Enter, spinner): 90 min -> 1 h 30 min.
    let durationIds = 0;
    function durationField(a, value, onState) {
        const id = `ctl-dur-${++durationIds}`;
        const node = el('fieldset', 'ctl-duration');
        node.append(el('legend', '', a.label));
        const input = el('input');
        input.type = 'hidden';
        input.name = a.name;
        const row = el('div', 'ctl-duration-row');
        const grid = el('div', 'ctl-duration-boxes');
        const sum = el('output', 'ctl-duration-sum');
        sum.id = `${id}-sum`;
        sum.setAttribute('aria-live', 'polite');
        const err = el('p', 'ctl-duration-err');
        err.id = `${id}-err`;
        err.setAttribute('aria-live', 'polite');
        const maxDays = Math.min(7, Math.floor(a.max / 86400));
        const boxes = {};
        for (const [k, text, , max] of L.DURATION_PARTS) {
            const label = el('label', 'ctl-duration-part');
            const box = el('input');
            Object.assign(box, { type: 'number', min: 0, max: k === 'days' ? maxDays : max, step: 1, inputMode: 'numeric' });
            box.dataset.part = k;
            box.setAttribute('aria-describedby', `${sum.id} ${err.id} ${id}-note`);
            if (k === 'days' && maxDays === 0) { box.disabled = true; box.title = 'This routine allows less than a day'; }
            label.append(el('span', '', text), box);
            grid.append(label);
            boxes[k] = box;
        }
        row.append(grid, sum);
        const note = el('p', 'ctl-duration-note', `Allowed: ${L.durationRange(a)}.${a.maxNote ? ` ${a.maxNote}` : ''}`);
        note.id = `${id}-note`;
        node.append(input, row, err, note);
        const show = parts => { for (const [k] of L.DURATION_PARTS) boxes[k].value = String(parts[k]); };
        const update = carry => {
            const r = L.checkDuration(a, Object.fromEntries(Object.entries(boxes).map(([k, b]) => [k, b.value])));
            if (carry && r.total !== null) show(L.splitDuration(r.total));
            input.value = r.total === null ? '' : String(r.total);
            sum.textContent = r.text;
            err.textContent = r.error ? `${a.label}: ${r.error}` : '';
            node.classList.toggle('invalid', !!r.error);
            for (const b of Object.values(boxes)) b.setAttribute('aria-invalid', String(!!r.error));
            onState();
        };
        for (const b of Object.values(boxes)) {
            b.addEventListener('input', () => update(false));
            b.addEventListener('change', () => update(true));
        }
        show(L.splitDuration(value));
        update(false);
        return { node, input };
    }

    // Start stays disabled while a duration box shows an error (the error says why).
    function setDisabled(container) {
        const off = !canWrite();
        for (const b of container.querySelectorAll('button')) {
            const bad = b.dataset.action === 'run' && !!b.closest('form')?.querySelector('.ctl-duration.invalid');
            b.disabled = off || bad;
            if (b.dataset.action === 'run') b.title = bad ? 'Fix the duration first' : '';
        }
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
        const name = el('b', 'ctl-name', L.label(row));
        if (row.type === 'player') name.title = row.username;
        const kind = el('span', `ctl-badge ctl-type-${row.type === 'player' ? 'regular' : 'bot'}`, row.type === 'player' ? 'regular' : 'bot');
        const presence = el('span', 'ctl-badge');
        const state = el('span', 'ctl-badge');
        head.append(check, name, kind, presence, state);
        const activity = el('p', 'line ctl-activity');
        const desired = el('p', 'line ctl-desired');
        const message = el('p', 'line ctl-message');
        summary.append(head, activity, desired, message);
        const detail = el('div', 'ctl-detail');
        const info = el('dl', 'ctl-info');
        const formBox = el('div', 'ctl-form');
        const logBox = el('div', 'ctl-log');
        logBox.append(el('h3', '', 'Job log (live, passwords redacted)'));
        const logPre = el('pre', 'ctl-log-lines');
        logBox.append(logPre);
        logBox.hidden = true;
        const frameBox = el('div', 'ctl-frame');
        const frameHead = el('div', 'ctl-frame-head');
        const frameButton = el('button', 'ctl-frame-open', 'Open game view');
        frameButton.type = 'button';
        const frameWhy = el('p', 'ctl-desc');
        frameHead.append(frameButton, frameWhy);
        const frameNote = el('p', 'note ctl-frame-note');
        frameNote.hidden = true;
        const frameSlot = el('div', 'ctl-frame-slot');
        frameBox.append(frameHead, frameNote, frameSlot);
        frameButton.addEventListener('click', ev => {
            ev.stopPropagation();
            if (frameSlot.firstChild) closeFrame(row.username); else openFrame(row.username, 0);
        });
        detail.append(info, formBox, frameBox, logBox);
        node.append(summary, detail);
        summary.addEventListener('click', () => setExpanded(row.username, !expanded.has(row.username)));
        detail.addEventListener('click', ev => ev.stopPropagation());
        const card = { node, check, presence, state, activity, desired, message, info, formBox, detail, formSig: '', logBox, logPre, logSig: '',
            frameBox, frameButton, frameWhy, frameNote, frameSlot, row };
        cards.set(row.username, card);
        return card;
    }

    // ---- browser view (the real game client in an iframe; URL from the owner-only endpoint) ----
    async function openFrame(name, retries) {
        const card = cards.get(name);
        if (!card || !canWrite()) return;
        setExpanded(name, true);
        card.frameButton.disabled = true;
        card.frameButton.dataset.busy = '1';
        card.frameWhy.textContent = 'Opening the game view…';
        try {
            for (let attempt = 0; ; attempt++) {
                const res = await fetch(frameUrl, {
                    method: 'POST', credentials: 'same-origin', cache: 'no-store',
                    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': payload.auth.csrf }, body: JSON.stringify({ account: name }),
                });
                const out = await res.json().catch(() => ({}));
                if (res.ok && typeof out.url === 'string') {
                    const frame = el('iframe', 'ctl-game');
                    frame.title = `Game client: ${L.label(card.row)}`;
                    frame.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-forms allow-pointer-lock');
                    frame.referrerPolicy = 'no-referrer';
                    frame.src = out.url;
                    card.frameSlot.replaceChildren(frame);
                    card.frameNote.textContent = L.frameNote(card.row);
                    card.frameNote.hidden = false;
                    card.node.classList.add('has-frame');
                    card.frameWhy.textContent = '';
                    return;
                }
                if (out.retry && attempt < retries) { await new Promise(r => setTimeout(r, 2000)); continue; }
                card.frameWhy.textContent = out.error || `Game view unavailable (HTTP ${res.status})`;
                return;
            }
        } catch (err) {
            card.frameWhy.textContent = `Game view unavailable: ${err.message || err}`;
        } finally {
            card.frameButton.dataset.busy = '';
            card.frameButton.disabled = !canWrite();
            card.frameButton.textContent = card.frameSlot.firstChild ? 'Close game view' : 'Open game view';
        }
    }
    function closeFrame(name) {
        const card = cards.get(name);
        if (!card || !card.frameSlot.firstChild) return;
        if (!window.confirm('Close the game view? Log out in the game first, or the server keeps the account in the world for a few minutes.')) return;
        card.frameSlot.replaceChildren();
        card.frameNote.hidden = true;
        card.node.classList.remove('has-frame');
        card.frameButton.textContent = 'Open game view';
    }
    window.addEventListener('beforeunload', ev => {
        if ([...cards.values()].some(c => c.frameSlot.firstChild)) { ev.preventDefault(); ev.returnValue = ''; }
    });

    function setExpanded(name, open) {
        if (open) expanded.add(name); else expanded.delete(name);
        save();
        const card = cards.get(name);
        if (card) { card.node.classList.toggle('expanded', open); card.detail.hidden = !open; }
    }

    function infoRows(row) {
        const c = row.controller || {};
        const rows = [];
        if (row.type === 'player') rows.push(['Account', `${row.displayName} (regular account, profile ${row.username})`]);
        if (c.job) rows.push(['Job', `${c.job.kind === 'stop' ? 'logout' : `${c.job.routine} ${c.job.args.join(' ')}`}${c.job.mode === 'browser' ? ' · browser view' : ' · headless'} · pid ${c.job.pid} · ${L.ago(Date.now() - c.job.startedAt)}${c.job.stopping ? ' · stopping' : ''}`]);
        if (c.job && c.job.note) rows.push(['Resolved', c.job.note]);
        if (c.client) rows.push(['Client', c.client === 'headless' ? 'headless, on the workstation' : 'browser view (this page)']);
        if (row.type !== 'player') rows.push(['Gates', c.gates && c.gates.length ? c.gates.join('; ') : 'none (read-only; cleared only on the workstation)']);
        if (c.foreign && c.foreign.length) rows.push(['Other controllers', c.foreign.join('; ')]);
        if (c.lastResult) rows.push(['Last job', `${c.lastResult.kind} r${c.lastResult.rev}: ${c.lastResult.rc === 0 ? 'exit 0' : c.lastResult.rc === null ? 'no result' : `exit ${c.lastResult.rc}`} · ${L.ago(Date.now() - c.lastResult.endedAt)} ago`]);
        if (row.desired) rows.push(['Requested', `${L.desiredText(row.desired, payload.registry)} · by ${row.desired.by || '?'} · ${L.ago(Date.now() - row.desired.at)} ago`]);
        if (row.phase) rows.push(['Routine phase', `${row.routine}: ${row.phase}`]);
        return rows;
    }

    function fillCard(card, row) {
        const c = row.controller;
        card.row = row;
        card.check.checked = selected.has(row.username);
        card.check.disabled = !row.launchable;
        card.presence.textContent = row.presence;
        card.presence.className = `ctl-badge presence-${row.presence}`;
        const st = c ? c.state : 'no report';
        card.state.textContent = st;
        card.state.className = `ctl-badge tone-${L.tone(c && c.state)}`;
        card.activity.textContent = row.activity || (row.presence === 'offline' ? 'Offline' : '—');
        card.desired.textContent = L.desiredText(row.desired, payload.registry);
        card.message.textContent = c && c.message ? c.message : row.launchable ? '' : 'Not launchable from the controller';
        card.message.className = `line ctl-message tone-${L.tone(c && c.state)}`;
        card.info.replaceChildren(...infoRows(row).flatMap(([k, v]) => [el('dt', '', k), el('dd', '', v)]));
        const sig = `${registrySig}|${row.launchable}|${row.eligible.join(',')}|${choicesSig([row])}`;
        if (sig !== card.formSig) {
            card.formSig = sig;
            if (row.launchable) buildForm(card.formBox, row.eligible, () => [row.username], { single: true, accountsOf: () => [card.row] });
            else card.formBox.replaceChildren(el('p', 'ctl-desc', 'This account is not launchable from the controller (registry exclusion).'));
        }
        setDisabled(card.formBox);
        // Live job log (headless runs, and the waiting/attached browser-view job).
        card.logBox.hidden = !L.showLog(row);
        const logSig = L.showLog(row) ? row.controller.log.join('\n') : '';
        if (logSig !== card.logSig) {
            const atBottom = card.logPre.scrollHeight - card.logPre.scrollTop - card.logPre.clientHeight < 24;
            card.logSig = logSig;
            card.logPre.textContent = logSig;
            if (atBottom) card.logPre.scrollTop = card.logPre.scrollHeight;
        }
        // Game view: offered per the portal's rules; an open frame is never torn down by a refresh.
        const frame = row.frame || { offered: false, reason: 'Not available.' };
        const isOpen = !!card.frameSlot.firstChild;
        card.frameBox.hidden = !row.launchable && !isOpen;
        card.frameButton.hidden = !frame.offered && !isOpen;
        card.frameButton.disabled = !canWrite();
        card.frameButton.textContent = isOpen ? 'Close game view' : 'Open game view';
        if (!isOpen && card.frameButton.dataset.busy !== '1') card.frameWhy.textContent = frame.offered ? (canWrite() ? '' : 'The game view needs the owner identity.') : (frame.reason || '');
        const open = expanded.has(row.username);
        card.node.classList.toggle('expanded', open);
        card.detail.hidden = !open;
        card.node.hidden = !L.visible(row, show, activeOnly);
    }

    // The gathering choices these accounts see (rebuild the form only when they change).
    const choicesSig = rows => JSON.stringify(rows.map(r => {
        const g = (r.controller && r.controller.gather) || {};
        return Object.keys(g).sort().map(id => [id, (payload.gatherChoices || {})[g[id]] || null]);
    }));
    let bulkSig = '';
    function renderBulk() {
        if (!payload) return;
        const rows = payload.bots.filter(r => selected.has(r.username) && r.launchable);
        selectedCount.textContent = String(rows.length);
        const eligible = L.commonEligible(rows);
        const sig = `${registrySig}|${rows.map(r => r.username).join(',')}|${eligible.join(',')}|${choicesSig(rows)}`;
        if (sig !== bulkSig) {
            bulkSig = sig;
            buildForm(bulkForm, eligible, () => payload.bots.filter(r => selected.has(r.username) && r.launchable).map(r => r.username),
                { noneText: rows.length ? 'No routine is launchable for every selected account.' : 'Select accounts with the checkboxes.',
                  accountsOf: () => payload.bots.filter(r => selected.has(r.username) && r.launchable) });
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
        empty.textContent = payload.bots.length ? (show === 'regular' && !payload.bots.some(r => r.type === 'player')
            ? 'No regular accounts yet: on the workstation run scripts/player.sh setup \'Your Name\' (it asks for the password there).' : 'No account matches this filter.') : 'No accounts known yet.';
        const counts = Object.fromEntries(['all', 'bots', 'regular'].map(v => [v, payload.bots.filter(r => L.visible(r, v, activeOnly)).length]));
        for (const b of filterButtons) {
            b.setAttribute('aria-pressed', String(b.dataset.show === show));
            b.querySelector('.n').textContent = String(counts[b.dataset.show]);
        }
        activeButton.setAttribute('aria-pressed', String(activeOnly));
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

    const setShow = (next, persist) => {
        show = L.validShow(next) || 'all';
        if (persist) store('localStorage')?.setItem(SHOW_KEY, show);
        try { history.replaceState(null, '', L.withShow(location.search, show) + location.hash); } catch { /* ignore */ }
        if (payload) render();
    };
    for (const b of filterButtons) b.addEventListener('click', () => setShow(b.dataset.show, true));
    activeButton.addEventListener('click', () => { activeOnly = !activeOnly; store('localStorage')?.setItem(ACTIVE_KEY, activeOnly ? '1' : '0'); if (payload) render(); });
    document.getElementById('ctl-expand-all').addEventListener('click', () => { if (payload) for (const r of payload.bots) if (L.visible(r, show, activeOnly)) setExpanded(r.username, true); });
    document.getElementById('ctl-collapse-all').addEventListener('click', () => { for (const name of [...expanded]) setExpanded(name, false); });
    document.getElementById('ctl-select-none').addEventListener('click', () => { selected.clear(); save(); if (payload) render(); });
    bulk.addEventListener('toggle', renderBulk);
    setShow(show, false);
    poll();
    setInterval(() => { if (!document.hidden) poll(); }, refreshMs);
})();
