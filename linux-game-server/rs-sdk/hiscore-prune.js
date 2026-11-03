const fs = require('node:fs');
const path = require('node:path');

// The login server only writes a skill's hiscore row while its base level is 15 or more and
// never removes one, so a row written at a higher level (another XP curve) outlived the drop.
// Below 15 the row is now deleted; everything else stays as upstream wrote it.
const root = process.argv[2] ?? '/opt';
const name = 'server/engine/src/server/login/LoginServer.ts';
const filename = path.join(root, name);
const text = fs.readFileSync(filename, 'utf8');
const marker = 'computer-setup: hiscore-prune.js';
const gate = /^([ \t]*)if \(player\.baseLevels\[stat\] >= 15\) \{\r?\n([ \t]*)const hiscoreType = stat \+ 1;/gm;
const prune = "await db.deleteFrom('hiscore').where('account_id', '=', account.id).where('type', '=', stat + 1).where('profile', '=', profile).execute();";

const matches = [...text.matchAll(gate)];
if (text.includes(marker)) {
    if (matches.length !== 0 || text.split(prune).length !== 2 || !text.includes('if (player.baseLevels[stat] < 15) {')) {
        throw new Error(`Unexpected hiscore level gate in ${name} (partially patched); review upstream before rebuilding`);
    }
} else {
    if (matches.length !== 1 || text.split(prune).length !== 1) {
        throw new Error(`Unexpected hiscore level gate in ${name}; review upstream before rebuilding`);
    }
    const updated = text.replace(gate, (_, outer, inner) => [
        `${outer}if (player.baseLevels[stat] < 15) {`,
        `${inner}// ${marker}: no row below level 15, so one left from a higher level`,
        `${inner}// (e.g. written under another XP curve) cannot stay on the board.`,
        `${inner}${prune}`,
        `${outer}} else {`,
        `${inner}const hiscoreType = stat + 1;`,
    ].join('\n'));
    fs.writeFileSync(filename, updated);
}
console.log('Hiscore rows below level 15 are deleted at save; rows at 15+ are written as upstream does');
