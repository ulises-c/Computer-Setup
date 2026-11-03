#!/bin/sh
# Copies world 1's data dir into an isolated test world's own data dir
# (`world.sh test up --isolated`). Runs as root in a throwaway container of the
# image the test world is about to run (it ships sqlite3), with world 1's data
# mounted READ-ONLY:
#   isolated-copy.sh SRC DST_PARENT
#
# Consistent while world 1 runs:
#   - db.sqlite and market.sqlite through SQLite's online backup (.backup), which
#     reads a consistent snapshot including the WAL, never the raw file;
#   - players/ with cp -a, then once more for every save written during the copy.
# The copy is built as DST_PARENT/data.new and renamed to DST_PARENT/data only
# when complete, with a marker file the isolated entrypoint insists on (it never
# starts on a directory without it, i.e. never on world 1's own data).
# In the copy, nobody is logged in: the login table still shows world 1's
# sessions (node 10) at the moment of the copy, and the copy's own login server
# would otherwise treat each account as online elsewhere.
set -eu

src="${1:?usage: isolated-copy.sh SRC DST_PARENT}"
parent="${2:?usage: isolated-copy.sh SRC DST_PARENT}"
new="$parent/data.new"

[ -f "$src/db.sqlite" ] || { echo "isolated-copy: no db.sqlite in $src" >&2; exit 1; }
rm -rf "$new"
mkdir -p "$new"
stamp="$parent/.copy-start"
: >"$stamp"

sqlite3 "$src/db.sqlite" ".backup '$new/db.sqlite'"
if [ -f "$src/market.sqlite" ]; then
    sqlite3 "$src/market.sqlite" ".backup '$new/market.sqlite'"
fi
saves=0
if [ -d "$src/players" ]; then
    cp -a "$src/players" "$new/players"
    # A save written while cp ran may be torn in the copy: take those once more.
    (cd "$src" && find players -type f -newer "$stamp") | while IFS= read -r file; do
        cp -p "$src/$file" "$new/$file"
    done
    saves=$(find "$new/players" -type f -name '*.sav' | wc -l | tr -d ' ')
fi
rm -f "$stamp"

sqlite3 "$new/db.sqlite" "UPDATE account_login SET logged_in = 0, login_time = NULL WHERE logged_in != 0;"
for db in "$new/db.sqlite" "$new/market.sqlite"; do
    [ -f "$db" ] || continue
    check=$(sqlite3 "$db" 'PRAGMA integrity_check;')
    [ "$check" = ok ] || { echo "isolated-copy: integrity check of $db: $check" >&2; exit 1; }
done
accounts=$(sqlite3 "$new/db.sqlite" 'SELECT count(*) FROM account;')

cat >"$new/ISOLATED-COPY" <<EOF
This is a throwaway copy of world 1's data for an isolated test world.
Nothing here is ever copied back to world 1.
copied_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
accounts=$accounts
saves=$saves
EOF
rm -rf "$parent/data"
mv "$new" "$parent/data"
echo "isolated-copy: $accounts accounts, $saves saves, db.sqlite$([ -f "$parent/data/market.sqlite" ] && echo ' + market.sqlite') copied"
