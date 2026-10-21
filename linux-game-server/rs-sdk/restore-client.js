const fs = require('node:fs');
const path = require('node:path');

const root = process.argv[2] ?? '/opt';
const shellPath = path.join(root, 'server/webclient/src/client/GameShell.ts');
const clientPath = path.join(root, 'server/webclient/src/client/Client.ts');
const shell = fs.readFileSync(shellPath, 'utf8');
const client = fs.readFileSync(clientPath, 'utf8');
const delayPattern = /protected deltime: number = (?:14|20);(?: \/\/ 30% faster than original 20ms)?/g;
if ([...shell.matchAll(delayPattern)].length !== 1) {
    throw new Error('Unexpected client logic delay; review upstream before rebuilding');
}
const forcedRunPattern = /\/\/ Always run \(previously: this\.keyHeld\[5\] === 1\)\r?\n[ \t]*this\.out\.p1\(1\);/g;
const requestedRun = 'this.out.p1(this.keyHeld[5] === 1 ? 1 : 0);';
const forcedCount = [...client.matchAll(forcedRunPattern)].length;
if (forcedCount !== 1 && !(forcedCount === 0 && client.split(requestedRun).length === 2)) {
    throw new Error('Unexpected movement packet run encoding; review upstream before rebuilding');
}
const updatedShell = shell.replace(delayPattern, 'protected deltime: number = 20;');
const updatedClient = client.replace(forcedRunPattern, requestedRun);
fs.writeFileSync(shellPath, updatedShell);
fs.writeFileSync(clientPath, updatedClient);
console.log('Original 20ms client logic and requested movement run bit restored');
