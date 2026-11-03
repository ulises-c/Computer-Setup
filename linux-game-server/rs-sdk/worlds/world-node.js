// Runtime patch for an extra RS-SDK world (a node that is not world 1).
//
// Run by world-entrypoint.sh inside the extra world's container, on the
// container's own copy of the engine source, before the engine starts. World 1's
// image and container are never touched: the patched files live in the extra
// world's writable layer and are rebuilt from the image at every start.
//
// Every edit is anchored on upstream text that must match exactly once; if
// upstream moved on, the patch throws and the world refuses to start.
//
//   1. web/websocket.ts: the browser client's /gateway relay dials
//      ws://localhost:7780, which on the shared host network is world 1's
//      gateway. It now dials this world's own AGENT_PORT.
//   2. server/login/LoginThread.ts: before asking world 1's login server, an
//      optional allowlist (WORLD_ALLOWLIST_ENABLED / WORLD_LOGIN_ALLOWLIST) and an
//      exclusive-login check (WORLD_EXCLUSIVE_LOGIN): an account that the login
//      server shows on another world is refused ("already logged in") instead of
//      taking that session over. Errors refuse the login (fail closed).
//   3. engine/World.ts: every login on this world first copies the save it is
//      about to load (the login server's .sav and, if present, the Grand Exchange
//      ledger checkpoint that the engine prefers) to WORLD_SAVE_BACKUP_DIR. A
//      failed backup refuses the login. WORLD_TAKEOVER_WATCH polls the login
//      table: a player whose account another world took over is removed from
//      this world WITHOUT saving, so the two sessions never overwrite each other.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const root = process.argv[2] ?? '/opt';
const MARK = 'computer-setup: world-node.js';

function patch(rel, edits) {
    const file = path.join(root, 'server/engine/src', rel);
    let text = fs.readFileSync(file, 'utf8');
    if (text.includes(MARK)) {
        return 'already patched';
    }
    for (const [anchor, replacement] of edits) {
        const count = text.split(anchor).length - 1;
        if (count !== 1) {
            throw new Error(`${rel}: expected exactly one match of ${JSON.stringify(anchor.slice(0, 80))}, found ${count}; review upstream before starting an extra world`);
        }
        text = text.replace(anchor, () => replacement(anchor));
    }
    fs.writeFileSync(file, text);
    return 'patched';
}

const results = {};

results['web/websocket.ts'] = patch('web/websocket.ts', [
    ["new WebSocket(`ws://localhost:7780/${ws.data.agentLabel ?? ''}`)",
        () => "new WebSocket(`ws://localhost:${process.env.AGENT_PORT || '7780'}/${ws.data.agentLabel ?? ''}`) /* " + MARK + ': own gateway */'],
]);

results['server/login/LoginThread.ts'] = patch('server/login/LoginThread.ts', [
    ['const { socket, remoteAddress, username, password, uid, lowMemory, reconnecting, hasSave } = msg;\n',
        anchor => anchor + [
            `            // ${MARK}: allowlist and exclusive login, checked before the login server is asked.`,
            '            const worldGuardReply = await worldGuardRefusal(username);',
            '            if (worldGuardReply !== null) {',
            "                parentPort.postMessage({ type: 'player_login', socket, username, lowMemory, reconnecting, reply: worldGuardReply, staffmodlevel: 0, save: null, account_id: -1, members: false } as any);",
            '                break;',
            '            }',
            '',
        ].join('\n')],
]);
fs.appendFileSync(path.join(root, 'server/engine/src/server/login/LoginThread.ts'), results['server/login/LoginThread.ts'] === 'patched' ? `
// ${MARK}
function worldGuardName(name: string): string {
    return String(name).trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}

// null = go ahead; 7 = rejected (client: "login rejected"); 3 = already logged in (client: code 5).
async function worldGuardRefusal(username: string): Promise<number | null> {
    try {
        const name = worldGuardName(username);
        if (process.env.WORLD_ALLOWLIST_ENABLED === 'true') {
            const allowed = (process.env.WORLD_LOGIN_ALLOWLIST ?? '').split(',').map(worldGuardName).filter(Boolean);
            if (!allowed.includes(name)) {
                console.warn('[world-guard] ' + name + ' is not on this world\\'s allowlist; login refused');
                return 7;
            }
        }
        if (process.env.WORLD_EXCLUSIVE_LOGIN === 'true') {
            const { db } = await import('#/db/query.js');
            const row = await db
                .selectFrom('account')
                .innerJoin('account_login', 'account_login.account_id', 'account.id')
                .select(['account_login.logged_in'])
                .where('account.username', '=', username)
                .where('account_login.profile', '=', Environment.node.profile)
                .executeTakeFirst();
            if (row && row.logged_in && row.logged_in !== Environment.node.id) {
                console.warn('[world-guard] ' + name + ' is logged in on world ' + row.logged_in + '; login refused, no takeover');
                return 3;
            }
        }
        return null;
    } catch (err) {
        console.error('[world-guard] check failed; login refused', err);
        return 7;
    }
}
` : '');

results['engine/World.ts'] = patch('engine/World.ts', [
    ['            const save = msg.save ?? new Uint8Array();\n',
        anchor => anchor + [
            `            // ${MARK}: keep a copy of what this world is about to load.`,
            '            if (!worldGuardBackup(username, save)) {',
            '                client.send(Uint8Array.from([11]));',
            '                client.close();',
            "                this.loginThread.postMessage({ type: 'player_force_logout', username });",
            '                return;',
            '            }',
            '',
        ].join('\n')],
    ['    private processLogouts(): void {\n',
        anchor => anchor + `        worldGuardWatch(this); // ${MARK}\n`],
]);
if (results['engine/World.ts'] === 'patched') {
    fs.appendFileSync(path.join(root, 'server/engine/src/engine/World.ts'), `
// ${MARK}
function worldGuardBackup(username: string, save: Uint8Array): boolean {
    const dir = process.env.WORLD_SAVE_BACKUP_DIR;
    if (!dir || !save || save.length < 2) {
        return true;
    }
    try {
        const stamp = new Date().toISOString().replace(/[:.]/g, '-');
        const target = dir + '/' + username;
        fs.mkdirSync(target, { recursive: true });
        fs.writeFileSync(target + '/' + stamp + '-login.sav', save);
        const ledger = playerSaveStore()?.saved(username);
        if (ledger) {
            fs.writeFileSync(target + '/' + stamp + '-ledger.sav', ledger);
        }
        console.log('[world-guard] backed up ' + username + ' before login' + (ledger ? ' (save + ledger checkpoint)' : ''));
        return true;
    } catch (err) {
        console.error('[world-guard] save backup failed for ' + username + '; login refused', err);
        return false;
    }
}

const worldGuardStrikes = new Map<string, number>();
let worldGuardBusy = false;
let worldGuardLast = 0;
function worldGuardWatch(world: any): void {
    if (process.env.WORLD_TAKEOVER_WATCH !== 'true') {
        return;
    }
    // Act on what the last poll found: two polls in a row that show the account on
    // another world (or on none) while it is still here = taken over.
    for (const [name, strikes] of worldGuardStrikes) {
        if (strikes < 2) {
            continue;
        }
        worldGuardStrikes.delete(name);
        const player = world.getPlayerByUsername(name);
        if (player && !world.logoutRequests.has(name)) {
            console.warn('[world-guard] ' + name + ' was taken over by another world; removed here without saving');
            world.removePlayerWithoutSave(player);
        }
    }
    const now = Date.now();
    if (worldGuardBusy || now - worldGuardLast < 2000) {
        return;
    }
    worldGuardLast = now;
    const names: string[] = [];
    for (const player of world.playerLoop.all()) {
        if (!world.logoutRequests.has(player.username)) {
            names.push(player.username);
        }
    }
    if (names.length === 0) {
        worldGuardStrikes.clear();
        return;
    }
    worldGuardBusy = true;
    (async () => {
        try {
            const { db } = await import('#/db/query.js');
            const rows = await db
                .selectFrom('account')
                .innerJoin('account_login', 'account_login.account_id', 'account.id')
                .select(['account.username', 'account_login.logged_in'])
                .where('account.username', 'in', names)
                .where('account_login.profile', '=', Environment.node.profile)
                .execute();
            const seen = new Set<string>();
            for (const row of rows) {
                seen.add(row.username);
                if (row.logged_in === Environment.node.id) {
                    worldGuardStrikes.delete(row.username);
                } else {
                    worldGuardStrikes.set(row.username, (worldGuardStrikes.get(row.username) ?? 0) + 1);
                }
            }
            for (const name of [...worldGuardStrikes.keys()]) {
                if (!names.includes(name)) {
                    worldGuardStrikes.delete(name);
                }
            }
        } catch (err) {
            console.error('[world-guard] takeover check failed', err);
        } finally {
            worldGuardBusy = false;
        }
    })();
}
`);
}

console.log(JSON.stringify({ worldNode: results }));
