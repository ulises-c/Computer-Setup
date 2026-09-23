#!/usr/bin/env bash
# End-to-end test for bin/hermes-skills against a throwaway HERMES_HOME, local
# bare repos standing in for the Forgejo remotes, and the real `hermes` CLI (so
# skills.external_dirs is written by Hermes itself). Touches nothing under the
# real ~/.hermes.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO_DIR/bin/hermes-skills"
command -v hermes >/dev/null || { printf 'skip: hermes not on PATH\n'; exit 0; }

# Fake credentials, assembled at runtime so no scanner flags this file.
FAKE_AWS="AKIA""ABCDEFGHIJKLMNOP"
FAKE_SLACK="xoxb""-1234567890-abcdefghij"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILS=$(( FAILS + 1 )); }
expect_rc() {
  local want="$1" desc="$2" rc=0
  shift 2
  "$@" >"$T/out" 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then pass "$desc"; else fail "$desc (rc=$rc, want $want)"; sed 's/^/       /' "$T/out" >&2; fi
}
check() {
  local desc="$1"
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}
expect_out() { if grep -qE -- "$1" "$T/out"; then pass "$2"; else fail "$2"; sed 's/^/       /' "$T/out" >&2; fi; }

skill() {
  local dir="$1" name="$2" body="${3:-plain procedure}"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: test skill %s\n---\n\n%s\n' "$name" "$name" "$body" > "$dir/SKILL.md"
}

export HERMES_HOME="$T/hermes"
export HERMES_SKILLS_ENV="$T/env"
export PATH="$REPO_DIR/bin:$PATH"
mkdir -p "$HERMES_HOME/skills/.hub"
printf 'stock-skill:abc\n' > "$HERMES_HOME/skills/.bundled_manifest"
printf '{"installed":{"hub-skill":{}}}\n' > "$HERMES_HOME/skills/.hub/lock.json"
skill "$HERMES_HOME/skills/general/stock-skill" stock-skill
skill "$HERMES_HOME/skills/hub-skill" hub-skill
skill "$HERMES_HOME/skills/general/tidy-notes" tidy-notes
skill "$HERMES_HOME/skills/dev/acme-deploy" acme-deploy "Deploy the Acmecorp service."
skill "$HERMES_HOME/skills/dev/leaky" leaky "token: $FAKE_SLACK"
skill "$HERMES_HOME/skills/.archive/old" old

for k in work personal; do git init -q --bare "$T/remote-$k.git"; done
cat > "$T/env" <<EOF
HERMES_SKILLS_WORK_REMOTE=$T/remote-work.git
HERMES_SKILLS_WORK_DIR=$T/clones/work
HERMES_SKILLS_PERSONAL_REMOTE=$T/remote-personal.git
HERMES_SKILLS_PERSONAL_DIR=$T/clones/personal
HERMES_SKILLS_WORK_MARKERS='acmecorp'
EOF
hermes config set skills.external_dirs '["~/.agents/skills"]' >/dev/null

printf 'install\n'
expect_rc 0 "install clones both repos" "$TOOL" install
if [[ -x "$T/clones/work/.git/hooks/pre-commit" ]]; then pass "work guard hook written"; else fail "work guard hook written"; fi
ext="$(hermes config get skills.external_dirs)"
if grep -qF -- "- ~/.agents/skills" <<< "$ext"; then pass "pre-existing external dir kept"; else fail "pre-existing external dir kept"; fi
if grep -qF -- "$T/clones/personal/skills" <<< "$ext"; then pass "personal repo in external_dirs"; else fail "personal repo in external_dirs"; fi
expect_rc 0 "install is idempotent" "$TOOL" install
if (( $(hermes config get skills.external_dirs | grep -c clones) == 2 )); then pass "no duplicate external_dirs entries"; else fail "no duplicate external_dirs entries"; fi

printf 'migrate plan\n'
expect_rc 0 "migrate dry run" "$TOOL" migrate
expect_out 'tidy-notes +general/tidy-notes +personal' "general skill → personal"
expect_out 'acme-deploy +dev/acme-deploy +work' "work-marked skill → work"
expect_out 'leaky +dev/leaky +SKIP:possible-secret' "secret skill skipped"
if grep -qE 'stock-skill|hub-skill|old' "$T/out"; then fail "bundled/hub/archived excluded"; else pass "bundled/hub/archived excluded"; fi
if [[ -d "$HERMES_HOME/skills/general/tidy-notes" ]]; then pass "dry run moved nothing"; else fail "dry run moved nothing"; fi

printf 'adopt guards\n'
expect_rc 1 "work skill refused by personal repo" "$TOOL" adopt acme-deploy personal
expect_out 'contains work markers' "refused for the marker reason"
expect_rc 1 "secret skill refused" "$TOOL" adopt leaky work
expect_out 'possible secret in .*leaky/SKILL.md:[0-9]+' "refused for the secret reason, by file:line"
if grep -qF "$FAKE_SLACK" "$T/out"; then fail "adopt does not echo the secret"; else pass "adopt does not echo the secret"; fi
expect_rc 1 "bundled skill refused" "$TOOL" adopt stock-skill personal
expect_out 'not an unadopted local skill' "refused because Hermes owns it"

printf 'migrate apply\n'
expect_rc 0 "migrate --apply" "$TOOL" migrate --apply
if [[ -f "$T/clones/personal/skills/general/tidy-notes/SKILL.md" ]]; then pass "tidy-notes in personal repo"; else fail "tidy-notes in personal repo"; fi
if [[ -f "$T/clones/work/skills/dev/acme-deploy/SKILL.md" ]]; then pass "acme-deploy in work repo"; else fail "acme-deploy in work repo"; fi
if [[ ! -e "$HERMES_HOME/skills/general/tidy-notes" ]]; then pass "local copy removed (no collision)"; else fail "local copy removed (no collision)"; fi
if [[ -d "$HERMES_HOME/skills/dev/leaky" ]]; then pass "skipped skill left in place"; else fail "skipped skill left in place"; fi
if git -C "$T/clones/work" diff --cached --name-only | grep -q acme-deploy; then pass "adoption staged"; else fail "adoption staged"; fi

printf 'commit guards\n'
for k in work personal; do check "$k commit passes guard" git -C "$T/clones/$k" -c commit.gpgsign=false commit -qm "feat: adopt skills"; done
printf 'Acmecorp internal notes\n' > "$T/clones/personal/skills/general/tidy-notes/extra.md"
git -C "$T/clones/personal" add -A
expect_rc 1 "guard blocks work marker in personal repo" git -C "$T/clones/personal" -c commit.gpgsign=false commit -qm leak
git -C "$T/clones/personal" reset -q --hard
printf 'key %s\n' "$FAKE_AWS" > "$T/clones/work/skills/dev/acme-deploy/creds.md"
git -C "$T/clones/work" add -A
expect_rc 1 "guard blocks secret in work repo" git -C "$T/clones/work" -c commit.gpgsign=false commit -qm leak
if grep -qF "$FAKE_AWS" "$T/out"; then fail "secret value not echoed"; else pass "secret value not echoed"; fi
git -C "$T/clones/work" reset -q --hard
rm -f "$T/clones/work/skills/dev/acme-deploy/creds.md"

printf 'verify / collisions / push / pull\n'
expect_rc 0 "verify passes on a clean setup" "$TOOL" verify
skill "$HERMES_HOME/skills/general/tidy-notes" tidy-notes
expect_rc 1 "verify fails on a local/repo name collision" "$TOOL" verify
expect_out 'tidy-notes: in personal repo' "collision is named"
rm -rf "$HERMES_HOME/skills/general/tidy-notes"
printf 'dirty\n' > "$T/clones/work/skills/dev/acme-deploy/wip.md"
expect_rc 1 "push refuses uncommitted changes" "$TOOL" push
rm -f "$T/clones/work/skills/dev/acme-deploy/wip.md"
expect_rc 0 "push" "$TOOL" push
check "personal remote received commits" git --git-dir="$T/remote-personal.git" rev-parse --verify --quiet HEAD
git clone -q "$T/remote-work.git" "$T/other"
skill "$T/other/skills/dev/second" second
git -C "$T/other" add -A && git -C "$T/other" -c commit.gpgsign=false commit -qm "feat: second" && git -C "$T/other" push -q
expect_rc 0 "pull fast-forwards" "$TOOL" pull
if [[ -f "$T/clones/work/skills/dev/second/SKILL.md" ]]; then pass "pulled skill present"; else fail "pulled skill present"; fi

printf 'hermes sees the repo skills\n'
list="$(hermes skills list 2>&1 || true)"
for n in tidy-notes acme-deploy second; do
  if grep -q "$n" <<< "$list"; then pass "hermes skills list shows $n"; else fail "hermes skills list shows $n"; fi
done

printf '\n'
if (( FAILS )); then printf '%d failure(s)\n' "$FAILS" >&2; exit 1; fi
printf 'all tests passed\n'
