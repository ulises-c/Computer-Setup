const fs = require('node:fs');
const path = require('node:path');

const root = process.argv[2] ?? '/opt';
const files = [
    ['server/engine/src/engine/entity/Player.ts', 'level / 10.0', 'level / 7.0'],
    ['server/webclient/src/client/Client.ts', 'level / 10.0', 'level / 7.0'],
    ['server/webclient/src/lite/LiteClient.ts', 'level / 10.0', 'level / 7.0'],
    ['server/webclient/src/lite/actions.ts', 'level / 10.0', 'level / 7.0'],
    ['sdk/test/utils/save-generator.ts', 'i / 10', 'i / 7'],
];

const updates = files.map(([name, oldFormula, originalFormula]) => {
    const filename = path.join(root, name);
    const text = fs.readFileSync(filename, 'utf8');
    const formulaLines = text.split('\n').filter(line => line.includes('Math.pow') && line.includes('300'));
    if (formulaLines.length !== 1 ||
        (!formulaLines[0].includes(oldFormula) && !formulaLines[0].includes(originalFormula))) {
        throw new Error(`Unexpected XP formula in ${name}; review upstream before rebuilding`);
    }
    let updated = text.replace(formulaLines[0], formulaLines[0].replace(oldFormula, originalFormula));
    updated = updated.replace('Player.ts uses level/10.0, our custom curve', 'Player.ts uses level/7.0, the original curve');
    updated = updated.replace('Custom rs-sdk curve; must stay in sync', 'Original XP curve; must stay in sync');
    return [filename, updated];
});

for (const [filename, updated] of updates) {
    fs.writeFileSync(filename, updated);
}
console.log('Original XP curve verified in engine, browser, lite client and save generator');
