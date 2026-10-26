// Releases a stopped world's accounts in the shared login server: sends the
// same `world_startup` message a world sends when it boots, which makes world
// 1's login server clear `logged_in` for every account it still shows on that
// node. world.sh runs it only after the world's container has exited, when
// accounts are still recorded there (the engine was killed before it could log
// everyone out). Run with bun on the host network:
//   docker run --rm --network host -e RELEASE_NODE_ID=100 --entrypoint bun IMAGE -e "$(cat login-release.js)"
const node = Number(process.env.RELEASE_NODE_ID);
const port = Number(process.env.LOGIN_PORT || 43510);
const profile = process.env.NODE_PROFILE || 'main';
if (!Number.isInteger(node) || node <= 0 || node === 10) {
    console.error('login-release: RELEASE_NODE_ID must be an extra world\'s node (never 10, world 1)');
    process.exit(2);
}
const ws = new WebSocket(`ws://127.0.0.1:${port}`);
const timeout = setTimeout(() => {
    console.error(`login-release: login server on ${port} did not answer`);
    process.exit(3);
}, 10_000);
ws.onerror = () => {
    console.error(`login-release: cannot reach the login server on ${port}`);
    process.exit(3);
};
ws.onopen = () => {
    clearTimeout(timeout);
    ws.send(JSON.stringify({ type: 'world_startup', nodeId: node, nodeTime: Date.now(), profile }));
    // The login server answers nothing to world_startup; give it time to run the update.
    setTimeout(() => {
        ws.close();
        console.log(`released node ${node}`);
        process.exit(0);
    }, 2_000);
};
