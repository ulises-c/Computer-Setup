const fs = require('node:fs');
const path = require('node:path');

// The login server keeps a 45 s hop timer between worlds. It stores logout_time as
// UTC text ('YYYY-MM-DD HH:MM:SS', db/query.ts toDbDate) but reads it back with
// `new Date(text)`, which parses that format as LOCAL time. The container runs with
// TZ=America/Los_Angeles, so the timer lasted 7-8 hours instead of 45 seconds and
// an account could not move to another world the same day (measured on world 100,
// 2026-10-26: refused with the hop-timer reply, 419 minutes left). The timer now
// reads the stored text as UTC; dates that already carry a zone are unchanged.
const root = process.argv[2] ?? '/opt';
const name = 'server/engine/src/server/login/LoginServer.ts';
const filename = path.join(root, name);
const text = fs.readFileSync(filename, 'utf8');
const marker = 'computer-setup: hop-timer-utc.js';
const original = 'const remaining = new Date(account.logout_time).getTime() - new Date(Date.now() - Environment.node.hopTime).getTime();';
const fixed = "const remaining = new Date(typeof account.logout_time === 'string' && !/(?:[zZ]|[+-]\\d\\d:?\\d\\d)$/.test(account.logout_time) ? account.logout_time.replace(' ', 'T') + 'Z' : account.logout_time).getTime() - new Date(Date.now() - Environment.node.hopTime).getTime(); // " + marker + ': stored as UTC text';

if (text.includes(marker)) {
    if (text.split(original).length !== 1 || text.split(fixed).length !== 2) {
        throw new Error(`Unexpected hop timer in ${name} (partially patched); review upstream before rebuilding`);
    }
} else {
    if (text.split(original).length !== 2) {
        throw new Error(`Unexpected hop timer in ${name}; review upstream before rebuilding`);
    }
    fs.writeFileSync(filename, text.replace(original, () => fixed));
}
console.log('The hop timer reads logout_time as UTC (45 s between worlds, not hours)');
