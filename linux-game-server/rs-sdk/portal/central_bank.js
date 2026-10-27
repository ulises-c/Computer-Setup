// Central bank page (/rs-sdk/central-bank/): polls /rs-sdk/api/central-bank and lets the owner mark each item
// the central bank account holds as Sell or Keep. Served as a static file so the page CSP stays
// `script-src 'self'` (no inline JS). All data goes into the DOM as text nodes, never as HTML.

// Pure helpers (DOM-free, exercised by test_central_bank.py with node when it is installed).
const CentralBankLogic = (() => {
    'use strict';
    const effective = item => item.pending || item.policy || 'keep';
    const gp = n => (n === null || n === undefined ? '?' : `${Number(n).toLocaleString('en-US')} gp`);
    const ago = ms => {
        if (ms === null || ms === undefined || ms < 0) return 'never';
        const s = Math.round(ms / 1000);
        if (s < 90) return `${s} s ago`;
        if (s < 5400) return `${Math.round(s / 60)} min ago`;
        return `${Math.round(s / 3600)} h ago`;
    };
    const KIND = { surplus: 'Surplus product', material: 'Material', consumable: 'Consumable' };
    const kindText = cls => KIND[cls] || 'Other';
    const counts = items => {
        const c = { all: items.length, sell: 0, keep: 0 };
        for (const i of items) c[effective(i)] += 1;
        return c;
    };
    const visible = (items, show) => (show === 'sell' || show === 'keep' ? items.filter(i => effective(i) === show) : items);
    const summary = items => {
        let total = 0, sellKinds = 0, sellTotal = 0, unknown = 0;
        for (const i of items) {
            if (i.value === null || i.value === undefined) { if (i.count > 0) unknown += 1; continue; }
            total += i.count * i.value;
            if (effective(i) === 'sell') { sellKinds += 1; sellTotal += i.count * i.value; }
        }
        const held = items.filter(i => i.count > 0).length;
        return `${held} kinds held, worth ${gp(total)} at store value${unknown ? ` (+${unknown} without a known value)` : ''}; marked Sell: ${sellKinds} kinds (${gp(sellTotal)}).`;
    };
    const bankLine = (data, now) => {
        if (!data.available) return { text: 'No data from the workstation yet: its central bank bridge has not reported.', warn: true };
        const b = data.bank || {};
        const parts = [];
        if (!b.bot || b.state === 'absent' || !b.at) parts.push('The central bank account has not reported yet.');
        else {
            const beat = now - b.at;
            const online = b.state === 'collecting' && beat < 180000;
            parts.push(`${b.bot} ${online ? `is at the ${b.hub || 'hub'} bank, receiving` : `is ${b.state === 'away' ? 'logged out or busy' : b.state}`} (heartbeat ${ago(beat)}).`);
            if (b.holdingsAt) parts.push(`Bank counted ${ago(now - b.holdingsAt)}.`);
            if (b.coins) parts.push(`Coins: ${gp(b.coins)}.`);
        }
        if (data.stale) parts.push(`Workstation data is ${ago(data.ageMs)}: the bridge may be stopped.`);
        return { text: parts.join(' '), warn: !!data.stale };
    };
    return { effective, gp, ago, kindText, counts, visible, summary, bankLine };
})();
if (typeof module !== 'undefined') module.exports = CentralBankLogic;

(() => {
    'use strict';
    if (typeof document === 'undefined') return;
    const root = document.getElementById('cb');
    if (!root) return;
    const L = CentralBankLogic;
    const api = root.dataset.api, post = root.dataset.post, refreshMs = Number(root.dataset.refreshMs) || 5000;
    const $ = id => document.getElementById(id);
    let data = null, show = 'all', busy = new Set(), lastResultRev = 0;
    // Edits this page made that were still pending at the last refresh (item -> policy), to confirm them when applied.
    const waiting = new Map();
    const el = (tag, attrs = {}, ...kids) => {
        const e = document.createElement(tag);
        for (const [k, v] of Object.entries(attrs)) {
            if (k === 'class') e.className = v;
            else if (k === 'text') e.textContent = v;
            else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
            else if (v !== false && v !== null && v !== undefined) e.setAttribute(k, v === true ? '' : String(v));
        }
        for (const kid of kids) if (kid !== null && kid !== undefined) e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
        return e;
    };
    const flash = (text, warn) => { const f = $('cb-flash'); f.textContent = text; f.hidden = !text; f.classList.toggle('live-warning', !!warn); };
    const time = ms => (ms ? new Date(ms).toLocaleString() : '?');
    const itemsText = items => Object.entries(items || {}).map(([n, c]) => `${n} ×${c}`).join(', ') || 'nothing';

    async function mark(item, policy) {
        if (!data || !data.auth || !data.auth.canWrite) return;
        busy.add(item.name); render();
        try {
            const r = await fetch(post, { method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': data.auth.csrf || '' },
                body: JSON.stringify({ item: item.name, policy, expectAt: item.policyAt || 0 }) });
            const body = await r.json().catch(() => ({}));
            if (!r.ok) flash(`${item.name}: ${body.error || `HTTP ${r.status}`}`, true);
            else { waiting.set(item.name, policy); flash(`${item.name} → ${policy === 'sell' ? 'Sell' : 'Keep'}: pending until the workstation applies it (usually within 10 s).`, false); }
        } catch (e) { flash(`${item.name}: could not reach the portal (${e.message}).`, true); }
        busy.delete(item.name);
        await load();
    }

    function toggle(item) {
        const can = data.auth && data.auth.canWrite;
        const eff = L.effective(item);
        const wrap = el('div', { class: 'cb-toggle', role: 'group', 'aria-label': `Sell or keep ${item.name}` });
        for (const [policy, label] of [['sell', 'Sell'], ['keep', 'Keep']]) {
            wrap.append(el('button', { type: 'button', 'aria-pressed': String(eff === policy), class: `cb-${policy}`, disabled: !can || busy.has(item.name) || eff === policy,
                title: can ? `${label}: ${policy === 'sell' ? 'the bank hands it to the traders, who sell it' : 'it stays in the central bank'}` : (data.auth && data.auth.reason) || 'Read-only',
                onclick: () => mark(item, policy) }, label));
        }
        const note = item.pending ? el('span', { class: 'cb-pending', text: 'pending…' })
            : item.policyBy ? el('span', { class: 'cb-by', text: `${item.policy} since ${time(item.policyAt)}`, title: `by ${item.policyBy}` }) : el('span', { class: 'cb-by', text: 'default' });
        return el('td', {}, wrap, note);
    }

    function table(headers, rows) {
        if (!rows.length) return el('p', { class: 'note', text: 'Nothing yet.' });
        return el('table', {}, el('thead', {}, el('tr', {}, ...headers.map(h => el('th', { scope: 'col', text: h })))),
            el('tbody', {}, ...rows.map(r => el('tr', {}, ...r.map(c => (c instanceof Node ? c : el('td', { text: c })))))));
    }

    function render() {
        if (!data) return;
        const now = Date.now();
        const line = L.bankLine(data, now);
        const st = $('cb-status'); st.textContent = line.text; st.classList.toggle('stale', line.warn);
        $('cb-auth').textContent = data.auth && data.auth.canWrite ? `Signed in as ${data.auth.login}: you can change the marks.` : `Read-only. ${(data.auth && data.auth.reason) || ''}`;
        const c = L.counts(data.items);
        for (const b of $('cb-filter').querySelectorAll('button')) {
            b.setAttribute('aria-pressed', String(b.dataset.show === show));
            b.querySelector('.n').textContent = c[b.dataset.show];
        }
        $('cb-summary').textContent = L.summary(data.items);
        const rows = L.visible(data.items, show).map(i => el('tr', { class: i.count > 0 ? '' : 'cb-gone' },
            el('th', { scope: 'row', text: i.name, title: i.count > 0 ? '' : 'Not in the bank now (marked earlier)' }),
            el('td', { class: 'num', text: i.count.toLocaleString('en-US') }),
            el('td', { class: 'num', text: L.gp(i.value) }),
            el('td', { class: 'num', text: i.total === null ? '?' : L.gp(i.total) }),
            el('td', { text: L.kindText(i.class) }),
            toggle(i)));
        $('cb-items').replaceChildren(...rows);
        const empty = $('cb-empty');
        empty.hidden = rows.length > 0;
        empty.textContent = data.items.length ? 'No items with this mark.' : 'The central bank holds nothing yet.';
        $('cb-traders').replaceChildren(table(['Trader', 'State', 'Heartbeat', 'Stock to sell', 'Coins banked'],
            (data.traders || []).map(t => [t.bot, t.state, L.ago(now - t.at), itemsText(t.stock), L.gp(t.coins)])));
        const totals = (data.soldTotals || []).map(t => `${t.item} ×${t.count} for ${L.gp(t.coins)}`).join(' · ');
        $('cb-sales').replaceChildren(...(totals ? [el('p', { class: 'note', text: `Totals (recent journal): ${totals}` })] : []),
            table(['When', 'Trader', 'Item', 'Price', 'Store'], (data.sales || []).map(s => [time(s.at), s.bot || '?', s.item, L.gp(s.price), s.store || '?'])));
        $('cb-moves').replaceChildren(table(['When', 'Direction', 'Account', 'Items'], [
            ...(data.received || []).map(r => [r.at, 'received from', r.from, r.items]),
            ...(data.handedOut || []).map(r => [r.at, 'handed to', r.to, r.items]),
        ].sort((a, b) => b[0] - a[0]).map(([at, dir, who, items]) => [time(at), dir, who, itemsText(items)])));
        const done = [];
        for (const [name, policy] of waiting) {
            const i = data.items.find(x => x.name === name);
            if (!i || i.pending) continue;
            waiting.delete(name);
            if (i.policy === policy) done.push(`${name} is now marked ${policy === 'sell' ? 'Sell' : 'Keep'}`);
        }
        if (done.length) flash(`${done.join('; ')}.`, false);
        const failed = (data.results || []).filter(r => !r.ok && r.rev > lastResultRev);
        if (failed.length) { flash(`Not applied: ${failed.map(r => `${r.item} (${r.error})`).join('; ')}`, true); }
        lastResultRev = Math.max(lastResultRev, ...(data.results || []).map(r => r.rev), 0);
    }

    async function load() {
        try {
            const r = await fetch(api, { credentials: 'same-origin', cache: 'no-store' });
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            const first = data === null;
            data = await r.json();
            if (first) lastResultRev = Math.max(0, ...(data.results || []).map(x => x.rev));
            render();
        } catch (e) {
            const st = $('cb-status'); st.textContent = `Could not load the central bank (${e.message}); retrying.`; st.classList.add('stale');
        }
    }
    for (const b of $('cb-filter').querySelectorAll('button')) b.addEventListener('click', () => { show = b.dataset.show; render(); });
    load();
    setInterval(load, refreshMs);
})();
