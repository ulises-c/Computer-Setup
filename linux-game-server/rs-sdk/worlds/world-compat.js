// Prints a JSON fingerprint of what an RS-SDK image does to shared accounts.
// Run with bun inside the image (world.sh compares two images):
//   docker run --rm --network none --entrypoint bun IMAGE -e "$(cat world-compat.js)"
// Worlds share one login server, one set of saves and one Grand Exchange ledger,
// so an extra world must level, save and migrate exactly like world 1:
//   xp        the level table the engine computes (getExpByLevel/getLevelByExp),
//             evaluated, not compared as text
//   save      SAV_MAGIC/SAV_VERSION and a hash of the save writer and reader
//   migrations the SQLite migrations (an extra world never migrates world 1's DB)
//   content   hashes of the server packs that ids in a save refer to
//             (obj, inv, varp, npc, loc, ...): a save that names an object world 1
//             does not have can stop that account loading there
//   entrypoint a hash of the image's entrypoint (world-entrypoint.sh mirrors it)
'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const ENGINE = process.env.COMPAT_ENGINE_DIR || '/opt/server/engine';
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const read = rel => fs.readFileSync(`${ENGINE}/${rel}`, 'utf8');
const out = {};

try {
    const src = read('src/engine/entity/Player.ts');
    const start = src.search(/^(?:export )?const levelExperience\b/m);
    const end = src.indexOf('export default class Player');
    if (start < 0 || end < 0) throw new Error('levelExperience block not found');
    const block = src.slice(start, end).replace(/^export /gm, '').replace(/:\s*number(\[\])?/g, '');
    const fn = new Function(`${block}\nreturn { getExpByLevel, getLevelByExp };`);
    const { getExpByLevel, getLevelByExp } = fn();
    const table = [];
    for (let level = 2; level <= 99; level++) table.push(getExpByLevel(level));
    const probes = [0, 830, 1000, 13363, 101333, 1000000, 13034431, 200000000].map(getLevelByExp);
    out.xp = sha(JSON.stringify({ table, probes }));
    out.xpLevel99 = getExpByLevel(99);
} catch (err) {
    out.xp = `error: ${err.message}`;
}

try {
    const loading = read('src/engine/entity/PlayerLoading.ts');
    const magic = /SAV_MAGIC: number = (0x[0-9a-f]+|\d+)/i.exec(loading)?.[1];
    const version = /SAV_VERSION: number = (\d+)/.exec(loading)?.[1];
    const player = read('src/engine/entity/Player.ts');
    const saveStart = player.search(/^\s+save\(/m);
    const saveEnd = player.indexOf('Packet.getcrc(sav.data, 0, sav.pos)', saveStart);
    if (!magic || !version || saveStart < 0 || saveEnd < 0) throw new Error('save format markers not found');
    out.save = `${magic}/v${version}/${sha(loading).slice(0, 16)}/${sha(player.slice(saveStart, saveEnd)).slice(0, 16)}`;
} catch (err) {
    out.save = `error: ${err.message}`;
}

try {
    out.migrations = fs.readdirSync(`${ENGINE}/prisma/singleworld/migrations`).filter(name => !name.endsWith('.toml')).sort();
} catch (err) {
    out.migrations = `error: ${err.message}`;
}

try {
    const dir = `${ENGINE}/data/pack/server`;
    const hashes = {};
    for (const name of fs.readdirSync(dir).filter(name => name.endsWith('.dat')).sort()) {
        hashes[name.replace(/\.dat$/, '')] = sha(fs.readFileSync(`${dir}/${name}`)).slice(0, 16);
    }
    out.content = hashes;
} catch (err) {
    out.content = `error: ${err.message}`;
}

try {
    out.entrypoint = sha(fs.readFileSync('/opt/server/entrypoint.sh')).slice(0, 16);
} catch (err) {
    out.entrypoint = `error: ${err.message}`;
}

console.log(JSON.stringify(out));
