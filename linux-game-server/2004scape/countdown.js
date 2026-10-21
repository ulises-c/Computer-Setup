// Runs inside a 2004Scape engine container (`bun -e`, started by update.sh).
// Announces a system update through the friend server's relay: the client's
// "System update in m:ss" timer plus chat broadcasts, kept in step until
// COUNTDOWN_DEADLINE_MS. Prints "announced" once the first messages are sent.
//
// The client always counts the timer down at 600 ms per tick. RS-SDK's engine
// ticks faster (NODE_TICKRATE), so its own shutdown would fire early; re-sending
// the remaining time every couple of seconds keeps the engine and the display
// within a tick of the deadline. The engine shuts down by itself at zero: it
// saves, logs everyone out and exits.

const fs = require('fs');

const ENGINE = process.env.COUNTDOWN_ENGINE_DIR || '/opt/server/engine';
const fail = (code, message) => {
    console.error(`countdown: ${message}`);
    process.exit(code);
};

function envFileValue(key) {
    let text;
    try {
        text = fs.readFileSync(`${ENGINE}/.env`, 'utf8');
    } catch {
        return undefined;
    }
    let value;
    for (const line of text.split(/\r?\n/)) {
        const match = /^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
        if (match && match[1] === key) {
            value = match[2].replace(/^(['"])(.*)\1$/, '$2');
        }
    }
    return value;
}

function setting(key, fallback) {
    const raw = process.env[key] ?? envFileValue(key) ?? fallback;
    const value = Number(raw);
    if (!Number.isInteger(value) || value <= 0) {
        fail(2, `invalid ${key}: ${raw}`);
    }
    return value;
}

// The relay opcodes are a const enum in the engine, so read their positions from
// the source rather than hardcoding numbers that an upstream reorder would shift.
function relayOpcodes() {
    const source = fs.readFileSync(`${ENGINE}/src/server/friend/FriendServer.ts`, 'utf8');
    const body = /export const enum FriendsClientOpcodes\s*\{([^}]*)\}/.exec(source)?.[1];
    if (body === undefined) {
        fail(2, 'FriendsClientOpcodes not found in the engine source');
    }
    const names = body
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\/\/[^\n]*/g, '')
        .split(',')
        .map(name => name.trim())
        .filter(Boolean);
    if (names.some(name => !/^[A-Z][A-Z0-9_]*$/.test(name))) {
        fail(2, 'FriendsClientOpcodes has explicit values or unexpected entries');
    }
    const index = name => {
        const i = names.indexOf(name);
        if (i < 0) {
            fail(2, `${name} not found in FriendsClientOpcodes`);
        }
        return i;
    };
    return { shutdown: index('RELAY_SHUTDOWN'), broadcast: index('RELAY_BROADCAST') };
}

const deadline = Number(process.env.COUNTDOWN_DEADLINE_MS);
if (!Number.isSafeInteger(deadline) || deadline - Date.now() < 10_000) {
    fail(2, 'COUNTDOWN_DEADLINE_MS must be at least 10 seconds in the future');
}
const port = setting('FRIEND_PORT', '45099');
const nodeId = setting('NODE_ID', '10');
const tickMs = setting('COUNTDOWN_TICK_MS', process.env.NODE_TICKRATE ?? '600');
const op = relayOpcodes();
const CLIENT_TICK_MS = 600;
const resendMs = tickMs < CLIENT_TICK_MS ? 2_000 : 30_000;
const checkpoints = [3600, 1800, 900, 600, 300, 120, 60, 30, 10];

const remainingMs = () => deadline - Date.now();

function describe(seconds) {
    if (seconds >= 60) {
        const minutes = Math.round(seconds / 60);
        return `${minutes} minute${minutes === 1 ? '' : 's'}`;
    }
    return `${seconds} seconds`;
}

const ws = new WebSocket(`ws://127.0.0.1:${port}`);
const send = message => ws.send(JSON.stringify({ nodeId, ...message }));

function syncTimer() {
    const ms = remainingMs();
    if (ms <= 0) {
        return;
    }
    // Display-accurate ticks when the engine is faster than the client; otherwise
    // engine-accurate ticks, so the engine never shuts down after the deadline.
    const duration = Math.max(1, Math.ceil(ms / Math.max(CLIENT_TICK_MS, tickMs)));
    send({ type: op.shutdown, duration });
}

function broadcast(seconds) {
    send({ type: op.broadcast, broadcast: `System update: the server goes down for a backup and update in ${describe(seconds)}.` });
}

const openTimeout = setTimeout(() => fail(3, `friend server on port ${port} did not answer`), 10_000);
ws.onerror = () => fail(3, `cannot reach the friend server on port ${port}`);
ws.onopen = () => {
    clearTimeout(openTimeout);
    let announced = Math.round(remainingMs() / 1000);
    syncTimer();
    broadcast(announced);
    console.log('announced');

    // Checkpoint broadcasts need 1 s resolution; the timer resync does not.
    const timer = setInterval(() => {
        const left = Math.round(remainingMs() / 1000);
        if (left <= 0) {
            clearInterval(timer);
            clearInterval(resync);
            ws.onclose = null;
            ws.close();
            process.exit(0);
        }
        const due = checkpoints.find(mark => mark < announced && mark >= left);
        if (due !== undefined) {
            announced = due;
            broadcast(due);
        }
    }, 1_000);
    const resync = setInterval(syncTimer, resendMs);
    ws.onclose = () => {
        clearInterval(timer);
        clearInterval(resync);
        fail(4, 'friend server closed the connection before the deadline');
    };
};
