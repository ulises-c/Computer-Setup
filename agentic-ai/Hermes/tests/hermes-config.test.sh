#!/usr/bin/env bash
# End-to-end test for bin/hermes-config against a throwaway HERMES_HOME, local
# bare repos standing in for the Forgejo remotes, a fake Bitbucket API
# (file://), a fake Hermes source repo, a fake state.db + curator ledger, and
# the real `hermes` CLI (so skills.external_dirs is written by Hermes itself).
# Touches nothing under the real ~/.hermes.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO_DIR/bin/hermes-config"
command -v hermes >/dev/null || { printf 'skip: hermes not on PATH\n'; exit 0; }
command -v python3 >/dev/null || { printf 'skip: python3 not on PATH\n'; exit 0; }

# Fake credentials, assembled at runtime so no scanner flags this file.
FAKE_AWS="AKIA""ABCDEFGHIJKLMNOP"
FAKE_SLACK="xoxb""-1234567890-abcdefghij"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GIT_CEILING_DIRECTORIES="$T"
export XDG_RUNTIME_DIR="$T"  # private sync lock: never contend with a real or parallel run
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
  if "$@" >/dev/null; then pass "$desc"; else fail "$desc"; fi
}
expect_out() { if grep -qE -- "$1" "$T/out"; then pass "$2"; else fail "$2"; sed 's/^/       /' "$T/out" >&2; fi; }
reject_out() { if grep -qE -- "$1" "$T/out"; then fail "$2"; sed 's/^/       /' "$T/out" >&2; else pass "$2"; fi; }

skill() {
  local dir="$1" name="$2" body="${3:-plain procedure}"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: test skill %s\n---\n\n%s\n' "$name" "$name" "$body" > "$dir/SKILL.md"
}
fake_repo() {  # dir origin email
  git init -q "$1"
  git -C "$1" remote add origin "$2"
  git -C "$1" config user.email "$3"
}

export HERMES_HOME="$T/hermes"
export HERMES_CONFIG_SYNC_ENV="$T/env"
export PATH="$REPO_DIR/bin:$PATH"
S="$HERMES_HOME/skills"
mkdir -p "$S/.hub"
printf 'stock-skill:abc\n' > "$S/.bundled_manifest"
printf '{"installed":{"hub-skill":{}}}\n' > "$S/.hub/lock.json"
skill "$S/general/stock-skill" stock-skill
skill "$S/hub-skill" hub-skill
skill "$S/general/retired-upstream" retired-upstream
skill "$S/general/tidy-notes" tidy-notes
skill "$S/dev/acme-deploy" acme-deploy "Deploy the Acmecorp service."
skill "$S/dev/leaky" leaky "token: $FAKE_SLACK"
skill "$S/.archive/old" old
# content markers: generated terms, excluded terms, Jira refs (case-sensitive)
skill "$S/dev/widget-notes" widget-notes "Restart widget-server after deploy."
skill "$S/dev/embedded-notes" embedded-notes "Notes on embedded Linux."
skill "$S/dev/jira-notes" jira-notes "Tracked in OPS-7."
skill "$S/dev/prose-notes" prose-notes "Compare the ai-1 and ops-2 variants."
# provenance-only skills (clean content)
for n in ci-helper oss-helper fork-helper ticket-helper child-helper notes-helper terms-helper tie-helper; do
  skill "$S/dev/$n" "$n"
done

# A Hermes source tree that once shipped retired-upstream, then dropped it.
git init -q "$T/hsrc"
skill "$T/hsrc/skills/general/retired-upstream" retired-upstream
git -C "$T/hsrc" add -A && git -C "$T/hsrc" -c commit.gpgsign=false commit -qm add
git -C "$T/hsrc" rm -rq skills && git -C "$T/hsrc" -c commit.gpgsign=false commit -qm drop

# Repos the fake sessions ran in.
fake_repo "$T/src/work-app" git@bitbucket.org:acmecorp/app.git me@acme.example
fake_repo "$T/src/oss-tool" https://github.com/other/tool.git me@acme.example
fake_repo "$T/src/fork" git@bitbucket.org:acmecorp/fork.git me@home.example
mkdir -p "$T/src/plain"

python3 - "$HERMES_HOME/state.db" "$S/.curator_ledger.jsonl" "$T/src" <<'EOF'
import json, sqlite3, sys
db_path, ledger, src = sys.argv[1:]
db = sqlite3.connect(db_path)
db.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, git_repo_root TEXT, parent_session_id TEXT)")
db.execute("CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT)")
sessions = {
    "s_work": (f"{src}/work-app", f"{src}/work-app", None),
    "s_oss": (f"{src}/oss-tool", f"{src}/oss-tool", None),
    "s_fork": (f"{src}/fork", f"{src}/fork", None),
    "s_gone": ("/nonexistent/wt", None, None),
    "s_gone_plain": ("/nonexistent/wt2", None, None),
    "s_child": (None, None, "s_work"),
    "s_terms": (f"{src}/plain", None, None),
}
for sid, (cwd, root, parent) in sessions.items():
    db.execute("INSERT INTO sessions VALUES (?, ?, ?, ?)", (sid, cwd, root, parent))
for sid, text in [("s_gone", "please fix ACME-12"), ("s_gone_plain", "tidy my notes, ai-3 style"),
                  ("s_terms", "update the Widget-Server config")]:
    db.execute("INSERT INTO messages VALUES (?, 'user', ?)", (sid, text))
db.commit()
edits = {
    "ci-helper": ["s_work"] * 3 + ["s_oss"],
    "oss-helper": ["s_oss", "s_oss", "s_work"],
    "fork-helper": ["s_fork"] * 3,
    "ticket-helper": ["s_gone"],
    "child-helper": ["s_child", "s_child"],
    "notes-helper": ["s_gone_plain", "s_gone_plain"],
    "terms-helper": ["s_terms"],
    "tie-helper": ["s_work", "s_oss"],
}
with open(ledger, "w") as fh:
    for skill, sids in edits.items():
        for sid in sids:
            fh.write(json.dumps({"actor": "curator", "action": "patch", "skill": skill, "evidence": {"session_id": sid}}) + "\n")
EOF

# Fake Bitbucket API, two pages.
mkdir -p "$T/bbapi/repositories"
printf '{"values":[{"slug":"widget-server"}],"next":"file://%s/bbapi/page2"}\n' "$T" > "$T/bbapi/repositories/acmecorp"
printf '{"values":[{"slug":"Embedded"}]}\n' > "$T/bbapi/page2"
printf 'machine example.invalid login a password b\n' > "$T/netrc"

for k in work personal; do git init -q --bare "$T/remote-$k.git"; done
cat > "$T/env" <<EOF
HERMES_CONFIG_SYNC_WORK_REMOTE=$T/remote-work.git
HERMES_CONFIG_SYNC_WORK_DIR=$T/clones/work
HERMES_CONFIG_SYNC_PERSONAL_REMOTE=$T/remote-personal.git
HERMES_CONFIG_SYNC_PERSONAL_DIR=$T/clones/personal
HERMES_CONFIG_SYNC_WORK_MARKERS='acmecorp'
HERMES_CONFIG_SYNC_JIRA_KEYS='ACME OPS'
HERMES_CONFIG_SYNC_TERMS_FILE=$T/terms
HERMES_CONFIG_SYNC_BITBUCKET_WORKSPACE=acmecorp
HERMES_CONFIG_SYNC_BITBUCKET_NETRC=$T/netrc
HERMES_CONFIG_SYNC_BITBUCKET_API=file://$T/bbapi
HERMES_CONFIG_SYNC_EXTRA_TERMS='gadgetron'
HERMES_CONFIG_SYNC_TERM_EXCLUDE='embedded'
HERMES_CONFIG_SYNC_WORK_EMAIL_DOMAINS='acme.example'
HERMES_CONFIG_SYNC_WORK_REMOTE_PATTERNS='bitbucket\.org[:/]acmecorp/'
HERMES_CONFIG_SYNC_HERMES_SRC=$T/hsrc
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

printf 'refresh-markers\n'
check "terms fetched across pages" grep -qx widget-server "$T/terms"
check "extra terms added" grep -qx gadgetron "$T/terms"
if grep -qix embedded "$T/terms"; then fail "excluded term dropped"; else pass "excluded term dropped"; fi
check "terms file is private" test "$(stat -c %a "$T/terms")" = 600
cp "$T/terms" "$T/terms.before"
sed "s#^HERMES_CONFIG_SYNC_BITBUCKET_API=.*#HERMES_CONFIG_SYNC_BITBUCKET_API=file://$T/missing#" "$T/env" > "$T/env-badapi"
expect_rc 1 "refresh fails on API error" env HERMES_CONFIG_SYNC_ENV="$T/env-badapi" "$TOOL" refresh-markers
check "failed refresh keeps the old terms" cmp -s "$T/terms" "$T/terms.before"

printf 'migrate plan\n'
expect_rc 0 "migrate dry run" "$TOOL" migrate
expect_out 'tidy-notes +general/tidy-notes +personal' "general skill → personal"
expect_out 'acme-deploy +dev/acme-deploy +work' "hand-written marker → work"
expect_out 'leaky +dev/leaky +SKIP:possible-secret' "secret skill skipped"
reject_out 'stock-skill|hub-skill|old|retired-upstream' "bundled/hub/archived/historical-upstream excluded"
expect_out "widget-notes .*work .*content names 'widget-server'" "generated term → work"
expect_out 'embedded-notes .*personal' "excluded term does not mark work"
expect_out 'jira-notes .*work' "Jira ref → work"
expect_out 'prose-notes .*personal' "lowercase key-like prose is not a Jira ref"
expect_out 'ci-helper .*work .*edits: 3/4' "majority work edits → work"
expect_out 'oss-helper .*personal .*edits: 1/3' "work email in an OSS repo is not work"
expect_out 'fork-helper .*personal .*edits: 0/3' "non-work email is definitive even on a work remote"
expect_out 'ticket-helper .*work .*edits: 1/1' "no-repo session typed a Jira ref → work"
expect_out 'child-helper .*work .*edits: 2/2' "subagent inherits parent session"
expect_out 'notes-helper .*personal .*edits: 0/2' "no-repo session without markers → personal"
expect_out 'terms-helper .*work .*edits: 1/1' "no-repo session typed a generated term → work"
expect_out 'tie-helper .*personal .*edits: 1/2' "a tie goes to personal"
if [[ -d "$S/general/tidy-notes" ]]; then pass "dry run moved nothing"; else fail "dry run moved nothing"; fi
expect_rc 0 "classify explains" "$TOOL" classify widget-notes
expect_out 'marker +dev/widget-notes/SKILL.md:[0-9]+:widget-server' "classify shows marker file:line"

printf 'single-repo setups\n'
grep -v '^HERMES_CONFIG_SYNC_WORK_\(REMOTE\|DIR\)=' "$T/env" > "$T/env-personal"
expect_rc 0 "personal-only plan" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" migrate
expect_out 'acme-deploy +dev/acme-deploy +SKIP:work' "personal-only setup leaves work skills local"
expect_out 'tidy-notes +general/tidy-notes +personal' "personal-only setup still adopts personal skills"
grep -v '^HERMES_CONFIG_SYNC_PERSONAL_' "$T/env" > "$T/env-work"
expect_rc 0 "work-only plan" env HERMES_CONFIG_SYNC_ENV="$T/env-work" "$TOOL" migrate
expect_out 'tidy-notes +general/tidy-notes +work' "work-only setup sends everything to work"
expect_rc 1 "adopt into a disabled repo is refused" env HERMES_CONFIG_SYNC_ENV="$T/env-work" "$TOOL" adopt tidy-notes personal
expect_out 'not enabled' "refused because the repo is not enabled"

printf 'adopt guards\n'
expect_rc 1 "work skill refused by personal repo" "$TOOL" adopt acme-deploy personal
expect_out 'contains work markers' "refused for the marker reason"
expect_rc 1 "generated-term skill refused by personal repo" "$TOOL" adopt widget-notes personal
expect_rc 1 "secret skill refused" "$TOOL" adopt leaky work
expect_out 'possible secret in .*leaky/SKILL.md:[0-9]+' "refused for the secret reason, by file:line"
if grep -qF "$FAKE_SLACK" "$T/out"; then fail "adopt does not echo the secret"; else pass "adopt does not echo the secret"; fi
expect_rc 1 "bundled skill refused" "$TOOL" adopt stock-skill personal
expect_out 'not an unadopted local skill' "refused because Hermes owns it"
expect_rc 0 "provenance suggestion can be overridden" "$TOOL" adopt ci-helper personal

printf 'migrate apply\n'
expect_rc 0 "migrate --apply" "$TOOL" migrate --apply
if [[ -f "$T/clones/personal/skills/general/tidy-notes/SKILL.md" ]]; then pass "tidy-notes in personal repo"; else fail "tidy-notes in personal repo"; fi
if [[ -f "$T/clones/work/skills/dev/acme-deploy/SKILL.md" ]]; then pass "acme-deploy in work repo"; else fail "acme-deploy in work repo"; fi
if [[ -f "$T/clones/work/skills/dev/child-helper/SKILL.md" ]]; then pass "child-helper in work repo"; else fail "child-helper in work repo"; fi
if [[ -f "$T/clones/personal/skills/dev/ci-helper/SKILL.md" ]]; then pass "override kept"; else fail "override kept"; fi
if [[ ! -e "$S/general/tidy-notes" ]]; then pass "local copy removed (no collision)"; else fail "local copy removed (no collision)"; fi
if [[ -d "$S/dev/leaky" ]]; then pass "skipped skill left in place"; else fail "skipped skill left in place"; fi
if [[ -d "$S/general/retired-upstream" ]]; then pass "historical upstream skill left in place"; else fail "historical upstream skill left in place"; fi
if git -C "$T/clones/work" diff --cached --name-only | grep -q acme-deploy; then pass "adoption staged"; else fail "adoption staged"; fi

printf 'commit guards\n'
for k in work personal; do check "$k commit passes guard" git -C "$T/clones/$k" -c commit.gpgsign=false commit -qm "feat: adopt skills"; done
printf 'Acmecorp internal notes\n' > "$T/clones/personal/skills/general/tidy-notes/extra.md"
git -C "$T/clones/personal" add -A
expect_rc 1 "guard blocks hand-written marker in personal repo" git -C "$T/clones/personal" -c commit.gpgsign=false commit -qm leak
git -C "$T/clones/personal" reset -q --hard
printf 'see gadgetron runbook\n' > "$T/clones/personal/skills/general/tidy-notes/extra.md"
git -C "$T/clones/personal" add -A
expect_rc 1 "guard blocks generated term in personal repo" git -C "$T/clones/personal" -c commit.gpgsign=false commit -qm leak
git -C "$T/clones/personal" reset -q --hard
printf 'follow up in ACME-99\n' > "$T/clones/personal/skills/general/tidy-notes/extra.md"
git -C "$T/clones/personal" add -A
expect_rc 1 "guard blocks Jira ref in personal repo" git -C "$T/clones/personal" -c commit.gpgsign=false commit -qm leak
git -C "$T/clones/personal" reset -q --hard
printf 'key %s\n' "$FAKE_AWS" > "$T/clones/work/skills/dev/acme-deploy/creds.md"
git -C "$T/clones/work" add -A
expect_rc 1 "guard blocks secret in work repo" git -C "$T/clones/work" -c commit.gpgsign=false commit -qm leak
if grep -qF "$FAKE_AWS" "$T/out"; then fail "secret value not echoed"; else pass "secret value not echoed"; fi
git -C "$T/clones/work" reset -q --hard
rm -f "$T/clones/work/skills/dev/acme-deploy/creds.md"

printf 'verify / collisions / push / pull\n'
rm -rf "$S/dev/leaky"
expect_rc 0 "verify passes on a clean setup" "$TOOL" verify
skill "$S/general/tidy-notes" tidy-notes
expect_rc 1 "verify fails on a local/repo name collision" "$TOOL" verify
expect_out 'tidy-notes: in personal repo' "collision is named"
rm -rf "$S/general/tidy-notes"
touch -d '40 days ago' "$T/terms"
expect_rc 0 "verify still passes with stale terms" "$TOOL" verify
expect_out 'work terms are [0-9]+ days old' "stale terms are flagged"
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

printf 'sync (nightly cron entry point)\n'
export HERMES_CONFIG_SYNC_CRON_BACKUP=off  # cron backup has its own section below
check "install wrote the cron script" test -x "$HERMES_HOME/scripts/hermes-config-sync.sh"
expect_rc 0 "sync with nothing to do" "$HERMES_HOME/scripts/hermes-config-sync.sh"
if [[ -s "$T/out" ]]; then fail "sync is silent when idle"; sed 's/^/       /' "$T/out" >&2; else pass "sync is silent when idle"; fi
printf '\nA new step.\n' >> "$T/clones/work/skills/dev/acme-deploy/SKILL.md"
skill "$T/clones/personal/skills/general/fresh" fresh
expect_rc 0 "sync commits and pushes edits and new skills" "$TOOL" sync
expect_out 'work: committed [0-9a-f]+ — chore: sync skills \(acme-deploy\)' "work commit names the skill"
expect_out 'personal: committed [0-9a-f]+ — chore: sync skills \(fresh\)' "personal commit names the skill"
expect_out 'personal: pushed 1 commit' "personal pushed"
check "work remote has the edit" test "$(git -C "$T/clones/work" rev-parse HEAD)" = "$(git --git-dir="$T/remote-work.git" rev-parse HEAD)"
check "commit body lists changed files" bash -c "git -C '$T/clones/personal' log -1 --format=%b | grep -q 'A.skills/general/fresh/SKILL.md'"
expect_rc 0 "second sync is a no-op" "$TOOL" sync
if [[ -s "$T/out" ]]; then fail "second sync is silent"; else pass "second sync is silent"; fi
printf 'follow up in ACME-5\n' > "$T/clones/personal/skills/general/fresh/notes.md"
before="$(git -C "$T/clones/personal" rev-parse HEAD)"
expect_rc 1 "sync refuses a guard hit" "$TOOL" sync
expect_out 'personal: commit blocked' "guard hit is reported"
check "blocked change not committed" test "$(git -C "$T/clones/personal" rev-parse HEAD)" = "$before"
check "blocked change left in the working tree, unstaged" bash -c "[[ -f '$T/clones/personal/skills/general/fresh/notes.md' ]] && git -C '$T/clones/personal' diff --cached --quiet"
rm -f "$T/clones/personal/skills/general/fresh/notes.md"
git -C "$T/other" pull -q --ff-only
printf '\nupstream edit\n' >> "$T/other/skills/dev/second/SKILL.md"
git -C "$T/other" -c commit.gpgsign=false commit -qam "feat: upstream edit" && git -C "$T/other" push -q
skill "$T/clones/work/skills/dev/third" third
expect_rc 0 "sync fast-forwards upstream first, then commits" "$TOOL" sync
check "upstream edit pulled" grep -q 'upstream edit' "$T/clones/work/skills/dev/second/SKILL.md"
check "local commit pushed on top" test "$(git -C "$T/clones/work" rev-parse HEAD)" = "$(git --git-dir="$T/remote-work.git" rev-parse HEAD)"
git -C "$T/other" pull -q --ff-only
printf '\nother side\n' >> "$T/other/skills/dev/third/SKILL.md"
git -C "$T/other" -c commit.gpgsign=false commit -qam "feat: other side" && git -C "$T/other" push -q
printf '\nthis side\n' >> "$T/clones/work/skills/dev/third/SKILL.md"
git -C "$T/clones/work" -c commit.gpgsign=false commit -qam "feat: this side"
expect_rc 1 "sync refuses diverged history" "$TOOL" sync
expect_out 'work: local and origin have diverged' "divergence is reported"
check "nothing force-pushed" bash -c "git --git-dir='$T/remote-work.git' log -1 --format=%s | grep -q 'other side'"

printf 'cron backup\n'
unset HERMES_CONFIG_SYNC_CRON_BACKUP
export HERMES_CONFIG_SYNC_CRON_HOST=testhost
mkdir -p "$HERMES_HOME/cron" "$HERMES_HOME/profiles/p1/cron" "$HERMES_HOME/scripts/lib" "$HERMES_HOME/scripts/.cache"
jq -n --arg aws "$FAKE_AWS" '{jobs: [
  {id: "j_clean", name: "clean", prompt: "", script: "clean.sh", no_agent: true, schedule: {kind: "cron", expr: "0 3 * * *"},
   deliver: "slack:D0TEST1234,local", origin: {platform: "slack", chat_id: "D0TEST1234"},
   next_run_at: "2030-01-01T03:00:00", last_run_at: "2029-12-31T03:00:00", last_status: "ok", repeat: {times: null, completed: 4}},
  {id: "j_work", name: "work", prompt: "check acmecorp deploys", schedule: {kind: "cron", expr: "0 4 * * *"}},
  {id: "j_secret", name: "leaky", prompt: ("use key " + $aws), schedule: {kind: "cron", expr: "0 5 * * *"}}
], updated_at: "x"}' > "$HERMES_HOME/cron/jobs.json"
jq -n '{jobs: [{id: "j_p1", name: "profile job", prompt: "summarize my notes", schedule: {kind: "interval", minutes: 60}}]}' > "$HERMES_HOME/profiles/p1/cron/jobs.json"
printf '#!/usr/bin/env bash\necho clean\n' > "$HERMES_HOME/scripts/clean.sh"; chmod 755 "$HERMES_HOME/scripts/clean.sh"
printf 'helper\n' > "$HERMES_HOME/scripts/lib/util.sh"
printf '#!/usr/bin/env bash\n# pages on ACME-9\n' > "$HERMES_HOME/scripts/work.sh"
printf 'cache\n' > "$HERMES_HOME/scripts/.cache/state"
P="$T/clones/personal/cron/testhost"
expect_rc 0 "backup-cron snapshots jobs" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" backup-cron
expect_out "job j_work \(work\): names 'acmecorp'" "work-named job left out, with the reason"
expect_out 'job j_secret \(leaky\): possible secret' "secret job left out"
expect_out 'script work.sh: names' "work-named script left out"
if grep -qF "$FAKE_AWS" "$T/out"; then fail "backup-cron does not echo the secret"; else pass "backup-cron does not echo the secret"; fi
check "clean job backed up" test "$(jq -r '[.jobs[].id] | join(",")' "$P/default/jobs.json")" = j_clean
check "delivery chat id redacted" test "$(jq -r '.jobs[0].deliver' "$P/default/jobs.json")" = "slack:<redacted>,local"
check "origin redacted" test "$(jq -r '.jobs[0].origin' "$P/default/jobs.json")" = "<redacted>"
if grep -rq D0TEST1234 "$P"; then fail "no chat id anywhere in the backup"; else pass "no chat id anywhere in the backup"; fi
check "runtime fields dropped" test "$(jq '.jobs[0] | has("next_run_at") or has("last_status") or (.repeat | has("completed"))' "$P/default/jobs.json")" = false
check "other profiles backed up" test "$(jq -r '.jobs[0].id' "$P/p1/jobs.json")" = j_p1
check "scripts backed up, mode kept" test -x "$P/default/scripts/clean.sh"
check "nested scripts backed up" test -f "$P/default/scripts/lib/util.sh"
if [[ -e "$P/default/scripts/work.sh" || -e "$P/default/scripts/.cache" ]]; then fail "work-named and hidden scripts not copied"; else pass "work-named and hidden scripts not copied"; fi
expect_rc 0 "sync commits the cron backup" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" sync
expect_out 'personal: cron backup left out:' "left-out jobs reported on first sync"
expect_out 'personal: committed [0-9a-f]+ — chore: sync cron backup' "cron commit message"
check "personal remote has the backup" git --git-dir="$T/remote-personal.git" cat-file -e HEAD:cron/testhost/default/jobs.json
jq '.jobs[0].next_run_at = "2031-01-01T03:00:00" | .jobs[0].last_status = "error" | .jobs[0].repeat.completed = 9' "$HERMES_HOME/cron/jobs.json" > "$T/j" && mv "$T/j" "$HERMES_HOME/cron/jobs.json"
expect_rc 0 "sync after a run" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" sync
if [[ -s "$T/out" ]]; then fail "run-only changes and the same left-out set stay silent"; sed 's/^/       /' "$T/out" >&2; else pass "run-only changes and the same left-out set stay silent"; fi
jq '.jobs |= map(select(.id != "j_clean"))' "$HERMES_HOME/cron/jobs.json" > "$T/j" && mv "$T/j" "$HERMES_HOME/cron/jobs.json"
rm -f "$HERMES_HOME/scripts/clean.sh"
expect_rc 0 "sync records a removed job" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" sync
expect_out 'chore: sync cron backup' "removal committed"
if [[ -e "$P/default/jobs.json" || -e "$P/default/scripts/clean.sh" ]]; then fail "removed job and script gone from the backup"; else pass "removed job and script gone from the backup"; fi
check "other host's backup untouched" bash -c "mkdir -p '$T/clones/personal/cron/otherhost' && touch '$T/clones/personal/cron/otherhost/keep' && env HERMES_CONFIG_SYNC_ENV='$T/env-personal' '$TOOL' backup-cron >/dev/null && test -f '$T/clones/personal/cron/otherhost/keep'"
rm -rf "$T/clones/personal/cron/otherhost"
expect_rc 0 "backup into the work repo" env HERMES_CONFIG_SYNC_ENV="$T/env-work" HERMES_CONFIG_SYNC_CRON_BACKUP=work "$TOOL" backup-cron
check "work repo keeps work-named jobs" test "$(jq -r '[.jobs[].id] | join(",")' "$T/clones/work/cron/testhost/default/jobs.json")" = j_work
check "work repo still blocks secrets" bash -c "! grep -rqF '$FAKE_AWS' '$T/clones/work/cron'"
rm -rf "$T/clones/work/cron"
expect_rc 1 "bad host label refused" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" HERMES_CONFIG_SYNC_CRON_HOST=../x "$TOOL" backup-cron
expect_rc 1 "backup off is explicit" env HERMES_CONFIG_SYNC_ENV="$T/env-work" "$TOOL" backup-cron
unset HERMES_CONFIG_SYNC_CRON_HOST

printf '\n'
if (( FAILS )); then printf '%d failure(s)\n' "$FAILS" >&2; exit 1; fi
printf 'all tests passed\n'
