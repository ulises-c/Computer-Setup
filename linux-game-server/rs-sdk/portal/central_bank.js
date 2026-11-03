// Central bank page (/rs-sdk/central-bank/): polls /rs-sdk/api/central-bank and lets the owner decide per item the
// central bank account holds: Sell, Keep or Alch (a placeholder the bots treat as Keep until an alcher exists).
// Served as a static file so the page CSP stays `script-src 'self'` (no inline JS). All data goes into the DOM as text
// nodes and attributes, never as HTML.

// Pure helpers (DOM-free, exercised by test_central_bank.py with node when it is installed).
const CentralBankLogic = (() => {
    'use strict';
    const POLICIES = ['sell', 'keep', 'alch'];
    const LABEL = { sell: 'Sell', keep: 'Keep', alch: 'Alch' };
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
        const c = { all: items.length, sell: 0, keep: 0, alch: 0 };
        for (const i of items) c[effective(i)] += 1;
        return c;
    };
    const visible = (items, show) => (POLICIES.includes(show) ? items.filter(i => effective(i) === show) : items);
    const summary = items => {
        let total = 0, unknown = 0;
        const by = { sell: [0, 0], alch: [0, 0] };
        for (const i of items) {
            if (i.value === null || i.value === undefined) { if (i.count > 0) unknown += 1; continue; }
            total += i.count * i.value;
            const e = effective(i);
            if (by[e]) { by[e][0] += 1; by[e][1] += i.count * i.value; }
        }
        const held = items.filter(i => i.count > 0).length;
        return `${held} kinds held, worth ${gp(total)} at store value${unknown ? ` (+${unknown} without a known value)` : ''}; marked Sell: ${by.sell[0]} kinds (${gp(by.sell[1])}); marked Alch: ${by.alch[0]} kinds (${gp(by.alch[1])}).`;
    };
    // Sorting: the column keys the page offers; numbers sort high first, names A-Z. null/unknown always last.
    const SORT = {
        name: i => i.name.toLowerCase(), count: i => i.count, value: i => i.value, total: i => i.total,
        buy: i => i.buy, sell: i => (i.sell ? i.sell.price : null), lowAlch: i => i.lowAlch, highAlch: i => i.highAlch,
    };
    const sortItems = (items, key, dir) => {
        const get = SORT[key] || SORT.value;
        const sign = dir === 'asc' ? 1 : -1;
        return [...items].sort((a, b) => {
            const x = get(a), y = get(b);
            if (x === null || x === undefined) return (y === null || y === undefined) ? a.name.localeCompare(b.name) : 1;
            if (y === null || y === undefined) return -1;
            if (x < y) return -sign;
            if (x > y) return sign;
            return a.name.localeCompare(b.name);
        });
    };
    const defaultDir = key => (key === 'name' ? 'asc' : 'desc');
    // "Best sell now": the price and where; a note when an unrouted shop would pay more.
    const sellText = item => {
        const s = item.sell;
        if (!s) return { price: item.value === null || item.value === undefined ? '?' : 'no shop', where: '', title: 'No shop on the merchant’s route buys it.' };
        const where = `${s.shopName}${s.stock !== null && s.stock !== undefined ? ` (stock ${s.stock})` : ''}`;
        let title = `${s.shopName} pays ${gp(s.price)} for one unit now, at its current stock of ${s.stock ?? '?'}.`;
        const b = item.bestAnywhere;
        if (b) title += ` More elsewhere: ${b.shopName} pays ${gp(b.price)}${b.routed ? '' : ' (not on the merchant’s route yet)'}.`;
        return { price: gp(s.price), where, title };
    };
    // Alchemy: gross value, and net of runes when the cast cost is known.
    const alchText = (gross, cost) => {
        if (gross === null || gross === undefined) return { price: '?', net: '' };
        return { price: gp(gross), net: cost === null || cost === undefined ? '' : `net ${Number(gross - cost).toLocaleString('en-US')}` };
    };
    const alchNote = alch => {
        const c = (alch && alch.castCost) || {};
        if (c.low === null || c.low === undefined) return 'Alch values are gross (40 % / 60 % of the value).';
        return `Alch values are gross; “net” subtracts the runes per cast at shop prices (low ${gp(c.low)}: 3 fire + 1 nature; high ${gp(c.high)}: 5 fire + 1 nature).${alch.natureBuyable ? '' : ' Nature runes are not buyable by the fleet yet, so Alch is a placeholder: those items stay in the bank.'}`;
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
    return { POLICIES, LABEL, effective, gp, ago, kindText, counts, visible, summary, sortItems, defaultDir, sellText, alchText, alchNote, bankLine };
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
    let data = null, show = 'all', busy = new Set(), lastResultRev = 0, sortKey = 'value', sortDir = 'desc';
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
    const HELP = {
        sell: 'the bank hands it to the traders, who sell it at the shop that pays best',
        keep: 'it stays in the central bank',
        alch: 'set aside for High Level Alchemy; a placeholder for now (no bot alchs yet), so it stays in the bank like Keep',
    };

    async function mark(item, policy) {
        if (!data || !data.auth || !data.auth.canWrite) return;
        busy.add(item.name); render();
        try {
            const r = await fetch(post, { method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': data.auth.csrf || '' },
                body: JSON.stringify({ item: item.name, policy, expectAt: item.policyAt || 0 }) });
            const body = await r.json().catch(() => ({}));
            if (!r.ok) flash(`${item.name}: ${body.error || `HTTP ${r.status}`}`, true);
            else { waiting.set(item.name, policy); flash(`${item.name} → ${L.LABEL[policy]}: pending until the workstation applies it (usually within 10 s).`, false); }
        } catch (e) { flash(`${item.name}: could not reach the portal (${e.message}).`, true); }
        busy.delete(item.name);
        await load();
    }

    function toggle(item) {
        const can = data.auth && data.auth.canWrite;
        const eff = L.effective(item);
        const wrap = el('div', { class: 'cb-toggle', role: 'group', 'aria-label': `Sell, keep or alch ${item.name}` });
        for (const policy of L.POLICIES) {
            const label = L.LABEL[policy];
            wrap.append(el('button', { type: 'button', 'aria-pressed': String(eff === policy), class: `cb-${policy}`, disabled: !can || busy.has(item.name) || eff === policy,
                title: can ? `${label}: ${HELP[policy]}` : (data.auth && data.auth.reason) || 'Read-only',
                onclick: () => mark(item, policy) }, label));
        }
        const note = item.pending ? el('span', { class: 'cb-pending', text: 'pending…' })
            : item.policyBy ? el('span', { class: 'cb-by', text: `${L.LABEL[item.policy] || item.policy} since ${time(item.policyAt)}`, title: `by ${item.policyBy}` }) : el('span', { class: 'cb-by', text: 'default (Keep)' });
        return el('td', { class: 'cb-decide' }, wrap, note);
    }

    function nameCell(i) {
        const letter = () => el('span', { class: 'cb-icon cb-noicon', 'aria-hidden': 'true', text: i.name.slice(0, 1) });
        const icon = i.icon ? el('img', { class: 'cb-icon', src: i.icon, alt: '', width: 32, height: 32, decoding: 'async' }) : null;
        if (icon) icon.addEventListener('error', () => { icon.replaceWith(letter()); });
        const link = el('a', { class: 'cb-item', href: i.wiki, target: '_blank', rel: 'noopener noreferrer', title: `${i.name}: open its 2004Scape wiki page (new tab)` },
            icon || letter(), el('span', { text: i.name }));
        return el('th', { scope: 'row', title: i.count > 0 ? null : 'Not in the bank now (marked earlier)' }, link);
    }

    function priceCell(main, sub, title) {
        return el('td', { class: 'num', title: title || null }, el('span', { class: 'cb-price', text: main }), sub ? el('span', { class: 'cb-sub', text: sub }) : null);
    }

    function table(headers, rows) {
        if (!rows.length) return el('p', { class: 'note', text: 'Nothing yet.' });
        return el('table', {}, el('thead', {}, el('tr', {}, ...headers.map(h => el('th', { scope: 'col', text: h })))),
            el('tbody', {}, ...rows.map(r => el('tr', {}, ...r.map(c => (c instanceof Node ? c : el('td', { text: c })))))));
    }

    function renderHeaders() {
        for (const th of document.querySelectorAll('table.cb-items th[data-sort]')) {
            const key = th.dataset.sort;
            th.setAttribute('aria-sort', key === sortKey ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none');
            th.classList.toggle('cb-sorted', key === sortKey);
        }
    }

    function render() {
        if (!data) return;
        const now = Date.now();
        const line = L.bankLine(data, now);
        const st = $('cb-status'); st.textContent = line.text; st.classList.toggle('stale', line.warn);
        $('cb-auth').textContent = data.auth && data.auth.canWrite ? `Signed in as ${data.auth.login}: you can change the decisions.` : `Read-only. ${(data.auth && data.auth.reason) || ''}`;
        const c = L.counts(data.items);
        for (const b of $('cb-filter').querySelectorAll('button')) {
            b.setAttribute('aria-pressed', String(b.dataset.show === show));
            b.querySelector('.n').textContent = c[b.dataset.show];
        }
        $('cb-summary').textContent = L.summary(data.items);
        renderHeaders();
        const cost = (data.alch && data.alch.castCost) || {};
        const rows = L.sortItems(L.visible(data.items, show), sortKey, sortDir).map(i => {
            const sell = L.sellText(i), low = L.alchText(i.lowAlch, cost.low), high = L.alchText(i.highAlch, cost.high);
            return el('tr', { class: `${i.count > 0 ? '' : 'cb-gone'} cb-row-${L.effective(i)}` },
                nameCell(i),
                el('td', { class: 'num', text: i.count.toLocaleString('en-US') }),
                el('td', { class: 'num', text: L.gp(i.value) }),
                el('td', { class: 'num', text: i.total === null || i.total === undefined ? '?' : L.gp(i.total) }),
                priceCell(L.gp(i.buy), '', 'A shop charges the value at its normal stock'),
                priceCell(sell.price, sell.where, sell.title),
                priceCell(low.price, low.net, 'Low Level Alchemy (Magic 21): 40 % of the value'),
                priceCell(high.price, high.net, 'High Level Alchemy (Magic 55): 60 % of the value'),
                el('td', { text: L.kindText(i.class) }),
                toggle(i));
        });
        $('cb-items').replaceChildren(...rows);
        $('cb-alch-note').textContent = L.alchNote(data.alch);
        const empty = $('cb-empty');
        empty.hidden = rows.length > 0;
        empty.textContent = data.items.length ? 'No items with this decision.' : 'The central bank holds nothing yet.';
        $('cb-traders').replaceChildren(table(['Trader', 'State', 'Heartbeat', 'Stock to sell', 'Coins banked'],
            (data.traders || []).map(t => [t.bot, t.state, L.ago(now - t.at), itemsText(t.stock), L.gp(t.coins)])));
        const shopName = id => ((data.shops || []).find(s => s.id === id) || {}).name || id || '?';
        const totals = (data.soldTotals || []).map(t => `${t.item} ×${t.count} for ${L.gp(t.coins)}`).join(' · ');
        $('cb-sales').replaceChildren(...(totals ? [el('p', { class: 'note', text: `Totals (recent journal): ${totals}` })] : []),
            table(['When', 'Trader', 'Item', 'Price', 'Shop'], (data.sales || []).map(s => [time(s.at), s.bot || '?', s.item, L.gp(s.price), shopName(s.store)])));
        $('cb-moves').replaceChildren(table(['When', 'Direction', 'Account', 'Items'], [
            ...(data.received || []).map(r => [r.at, 'received from', r.from, r.items]),
            ...(data.handedOut || []).map(r => [r.at, 'handed to', r.to, r.items]),
        ].sort((a, b) => b[0] - a[0]).map(([at, dir, who, items]) => [time(at), dir, who, itemsText(items)])));
        const done = [];
        for (const [name, policy] of waiting) {
            const i = data.items.find(x => x.name === name);
            if (!i || i.pending) continue;
            waiting.delete(name);
            if (i.policy === policy) done.push(`${name} is now marked ${L.LABEL[policy]}`);
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
    for (const th of document.querySelectorAll('table.cb-items th[data-sort]')) {
        th.tabIndex = 0;
        const sortBy = () => {
            const key = th.dataset.sort;
            if (key === sortKey) sortDir = sortDir === 'asc' ? 'desc' : 'asc';
            else { sortKey = key; sortDir = L.defaultDir(key); }
            render();
        };
        th.addEventListener('click', sortBy);
        th.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); sortBy(); } });
    }
    load();
    setInterval(load, refreshMs);
})();
