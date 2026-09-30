#!/usr/bin/env bash
set -euo pipefail

# Print the world name stored inside a Dragonwilds .sav — the value
# DefaultWorldName has to match for the server to load it.
#
# strings(1) is no use here: a world name is usually a slot number ("1"), far
# below any minimum-length threshold, and the header lists its field names before
# its values, so the first readable text looks like a schema rather than data.

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <save.sav>\n' "$0" >&2
  exit 1
fi
[[ -r "$1" ]] || { printf 'error: cannot read %s\n' "$1" >&2; exit 1; }

python3 - "$1" <<'PY'
import struct, sys

data = open(sys.argv[1], 'rb').read(4096)

# UE FString: int32 byte length (including the NUL) followed by the characters.
values, i = [], 0
while i < len(data) - 4:
    (n,) = struct.unpack_from('<i', data, i)
    if 2 <= n <= 128 and i + 4 + n <= len(data):
        s = data[i + 4:i + 4 + n]
        if s.endswith(b'\x00') and all(32 <= c < 127 for c in s[:-1]):
            values.append(s[:-1].decode())
            i += 4 + n
            continue
    i += 1

# The map name anchors the value block; the world name sits immediately before it.
if 'L_World' not in values:
    sys.exit('error: could not locate the value block — unexpected save format')
k = values.index('L_World')
if k == 0:
    sys.exit('error: value block malformed — no world name before the map name')

print(f'world name : {values[k - 1]}')
print(f'map        : {values[k]}')
if k + 1 < len(values):
    print(f'owner      : {values[k + 1]}')
if values and values[0][:2] == '20':
    print(f'saved at   : {values[0]}')
print()
print(f'set DefaultWorldName={values[k - 1]} and name the file {values[k - 1]}.sav')
PY
