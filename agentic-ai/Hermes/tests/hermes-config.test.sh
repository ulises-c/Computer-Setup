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
export XDG_CONFIG_HOME="$T/xdg"  # the state backup reads systemd user units from here, never the real ones
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
reject_out() {
  local rc=0
  grep -qE -- "$1" "$T/out" || rc=$?
  case "$rc" in 1) pass "$2" ;; 0) fail "$2"; sed 's/^/       /' "$T/out" >&2 ;; *) fail "$2 (grep failed, rc=$rc)" ;; esac
}
# absent <desc> <text> <command...>: passes only when the command succeeds and
# its full output (saved first, so grep -q cannot cut it short) lacks text.
absent() {
  local desc="$1" text="$2" rc=0
  shift 2
  "$@" > "$T/inspect" 2> "$T/inspect.err" || rc=$?
  if (( rc )); then fail "$desc (inspection failed, rc=$rc)"; sed 's/^/       /' "$T/inspect.err" >&2; return; fi
  grep -qF -- "$text" "$T/inspect" || rc=$?
  case "$rc" in 1) pass "$desc" ;; 0) fail "$desc (found)" ;; *) fail "$desc (grep failed, rc=$rc)" ;; esac
}
# absent_in <desc> <text> <dir>: no file under dir (outside .git) holds text.
absent_in() {
  local rc=0
  grep -rqF --exclude-dir=.git -- "$2" "$3" 2> "$T/inspect.err" || rc=$?
  case "$rc" in 1) pass "$1" ;; 0) fail "$1 (found)" ;; *) fail "$1 (grep failed, rc=$rc)"; sed 's/^/       /' "$T/inspect.err" >&2 ;; esac
}
# none_found <desc> <find args...>: passes only when find succeeds and
# prints nothing.
none_found() {
  local desc="$1" rc=0
  shift
  find "$@" -print > "$T/inspect" 2> "$T/inspect.err" || rc=$?
  if (( rc )); then fail "$desc (find failed, rc=$rc)"; sed 's/^/       /' "$T/inspect.err" >&2
  elif [[ -s "$T/inspect" ]]; then fail "$desc (found)"; sed 's/^/       /' "$T/inspect" >&2
  else pass "$desc"; fi
}

printf 'test helpers\n'
# A negative check must fail, not pass, when its inspection fails or the
# match sits early in a large output (grep -q would cut the pipe).
# helper_counts <n> <desc> <helper call...>: the call must record exactly n
# failures; they are then taken back, so only this check's result counts.
helper_counts() {
  local want="$1" desc="$2" before="$FAILS"
  shift 2
  "$@" >/dev/null 2>&1
  local got=$(( FAILS - before ))
  FAILS="$before"
  if (( got == want )); then pass "$desc"; else fail "$desc (recorded $got failures, want $want)"; fi
}
helper_fails() { helper_counts 1 "$@"; }
helper_fails "absent fails when the inspection fails" absent x needle false
helper_fails "absent fails on an early match in a large output" absent x needle bash -c 'echo needle; seq 1 300000'
helper_counts 0 "absent passes on clean output" absent x needle echo hay
helper_fails "absent_in fails when grep fails" absent_in x needle "$T/no-such-dir"
helper_fails "none_found fails when find fails" none_found x "$T/no-such-dir"

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
# Hermes prints a list it read back from config.yaml with indented items
# ("  - /path"); every one of them must still be parsed.
hermes config set skills.external_dirs "[\"~/.agents/skills\", \"~/more/skills\", \"$T/clones/work/skills\", \"$T/clones/personal/skills\"]" >/dev/null
check "hermes prints external_dirs items indented" grep -qE '^[[:space:]]+- ~/more/skills$' <(hermes config get skills.external_dirs)
expect_rc 0 "install with indented external_dirs" "$TOOL" install
ext="$(hermes config get skills.external_dirs)"
if grep -qF -- "- ~/.agents/skills" <<< "$ext" && grep -qF -- "- ~/more/skills" <<< "$ext"; then pass "every indented pre-existing dir kept"; else fail "every indented pre-existing dir kept"; fi
if (( $(grep -c clones <<< "$ext") == 2 )); then pass "indented repo entries not duplicated"; else fail "indented repo entries not duplicated"; fi
expect_rc 0 "verify config checks with indented external_dirs" "$TOOL" verify
expect_out '\[ OK \] external_dirs has work' "verify finds the work repo in indented external_dirs"
expect_out '\[ OK \] external_dirs has personal' "verify finds the personal repo in indented external_dirs"

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

printf 'push-time guard\n'
PC="$T/clones/personal" PR="$T/remote-personal.git" WC="$T/clones/work" F="$T/clones/personal/skills/general/fresh"
PB="$(git -C "$PC" symbolic-ref --short HEAD)"
PBASE="$(git -C "$PC" rev-parse HEAD)"
PREFS="$(git --git-dir="$PR" for-each-ref)"
psync() { env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" "$@"; }
published() { [[ "$(git --git-dir="$PR" for-each-ref)" != "$PREFS" ]]; }
# Puts the personal clone and its remote back where this section started.
preset() {
  local r
  git -C "$PC" checkout -qf "$PB"
  git -C "$PC" reset -q --hard "$PBASE"
  git -C "$PC" clean -qfd
  git -C "$PC" config --unset remote.origin.pushurl || true
  git -C "$PC" remote set-url origin "$PR"
  for r in $(git --git-dir="$PR" for-each-ref --format='%(refname)'); do
    if [[ "$r" != "refs/heads/$PB" ]]; then git --git-dir="$PR" update-ref -d "$r"; fi
  done
  git --git-dir="$PR" update-ref "refs/heads/$PB" "$PBASE"
  git -C "$PC" fetch -q --prune origin
  for r in $(git -C "$PC" for-each-ref --format='%(refname:short)' refs/heads); do
    if [[ "$r" != "$PB" ]]; then git -C "$PC" branch -qD "$r"; fi
  done
}
blocked() {  # a personal-only sync must fail and publish nothing
  expect_rc 1 "$1" psync sync
  if published; then fail "$1: nothing published"; else pass "$1: nothing published"; fi
  preset
}
check "install wrote the pre-push hook" test -x "$PC/.git/hooks/pre-push"
mkdir -p "$F/references" && printf 'plain notes\n' > "$F/references/widget-server.md"
blocked "sync blocks a marker in a file name"
skill "$PC/skills/acmecorp/tool" tool
blocked "sync blocks a marker in a directory name"
printf 'plain notes\n' > "$F/gadgetron.md"
git -C "$PC" add -A
expect_rc 1 "the commit guard checks staged file names" git -C "$PC" -c commit.gpgsign=false commit -qm "docs: notes"
preset
git -C "$PC" checkout -qb ACME-99-widget-server
skill "$PC/skills/general/branchy" branchy
blocked "sync blocks a marker in the branch name"
printf 'bin\0Acmecorp internal\n' > "$F/blob.bin"
blocked "sync blocks a marker in a file with a NUL byte"
printf '*.md -diff\n' > "$PC/.gitattributes"
printf 'see gadgetron runbook\n' > "$F/notes.md"
blocked "sync blocks a marker in a -diff file"
ln -s ../../acmecorp/runbook.md "$F/runbook.md"
blocked "sync blocks a symlink whose target names a marker"
jq -n '{summary: "Summary:\nACME-12 done"}' > "$F/data.json"
blocked 'sync blocks a \nACME-12 escape in JSON'
jq -n '{summary: "see:\twidget-server"}' > "$F/data.json"
blocked 'sync blocks a \twidget-server escape in JSON'
git clone -q -b "$PB" "$PR" "$T/pother"
printf 'old notes\n' > "$T/pother/gadgetron-notes.md"
git -C "$T/pother" add -A && git -C "$T/pother" -c commit.gpgsign=false commit -qm "docs: old notes" && git -C "$T/pother" push -q
mark="$(git -C "$T/pother" rev-parse HEAD)"
git -C "$PC" fetch -q origin && git -C "$PC" merge -q --ff-only "origin/$PB"
rm "$PC/gadgetron-notes.md"
expect_rc 1 "sync blocks a marker in the generated commit message" psync sync
check "generated commit message: nothing pushed" test "$(git --git-dir="$PR" rev-parse "refs/heads/$PB")" = "$mark"
check "generated commit message: nothing committed" test "$(git -C "$PC" rev-parse HEAD)" = "$mark"
preset
rm -rf "$T/pother"
printf 'Acmecorp notes\n' > "$F/wip.md"
git -C "$PC" add -A && git -C "$PC" -c commit.gpgsign=false commit -q --no-verify -m "wip"
git -C "$PC" rm -q skills/general/fresh/wip.md && git -C "$PC" -c commit.gpgsign=false commit -qm "chore: drop wip"
expect_rc 1 "push blocks a --no-verify blob deleted in a later commit" psync push
if published; then fail "push of a deleted blob: nothing published"; else pass "push of a deleted blob: nothing published"; fi
blocked "sync blocks a --no-verify blob deleted in a later commit"
printf 'Acmecorp notes\n' > "$F/wip.md"
git -C "$PC" add -A && git -C "$PC" -c commit.gpgsign=false commit -q --no-verify -m "wip"
expect_rc 1 "the pre-push hook blocks a manual git push" git -C "$PC" push -q origin HEAD
if published; then fail "manual git push: nothing published"; else pass "manual git push: nothing published"; fi
git -C "$PC" reset -q --hard HEAD~1
git clone -q --bare "$PR" "$T/stray.git"
STRAY="$(git --git-dir="$T/stray.git" for-each-ref)"
skill "$PC/skills/general/stray" stray
git -C "$PC" add -A && git -C "$PC" -c commit.gpgsign=false commit -qm "feat: stray"
git -C "$PC" remote add stray "$T/stray.git"
expect_rc 1 "the pre-push hook blocks a push to another remote" git -C "$PC" push -q stray HEAD
expect_rc 1 "the pre-push hook blocks a push to a bare URL" git -C "$PC" push -q "$T/stray.git" HEAD
check "the other remote received nothing" test "$(git --git-dir="$T/stray.git" for-each-ref)" = "$STRAY"
git -C "$PC" remote remove stray
rm -rf "$T/stray.git"
preset
printf 'Summary:\\u000aACME-12 done, see:\\x09widget-server\n' > "$F/unicode.md"
blocked "sync blocks a marker after a \\u000a or \\x09 escape"
preset

printf 'fail-closed scanning\n'
sed "s/^HERMES_CONFIG_SYNC_WORK_MARKERS=.*/HERMES_CONFIG_SYNC_WORK_MARKERS='(?i)acmecorp'/" "$T/env-personal" > "$T/env-badre"
expect_rc 1 "an invalid marker regex is refused" env HERMES_CONFIG_SYNC_ENV="$T/env-badre" "$TOOL" scan personal
expect_out 'HERMES_CONFIG_SYNC_WORK_MARKERS' "the invalid regex is named"
sed "s/^HERMES_CONFIG_SYNC_JIRA_KEYS=.*/HERMES_CONFIG_SYNC_JIRA_KEYS='A[B'/" "$T/env-personal" > "$T/env-badjira"
expect_rc 1 "a scanner error fails the scan" env HERMES_CONFIG_SYNC_ENV="$T/env-badjira" "$TOOL" scan personal
printf 'plain notes\n' > "$F/more.md"
git -C "$PC" add -A
expect_rc 1 "a scanner error blocks the commit" env HERMES_CONFIG_SYNC_ENV="$T/env-badjira" git -C "$PC" -c commit.gpgsign=false commit -qm "docs: more"
preset
skill "$S/general/plain-adopt" plain-adopt
expect_rc 1 "a scanner error blocks adopt" env HERMES_CONFIG_SYNC_ENV="$T/env-badjira" "$TOOL" adopt plain-adopt personal
check "the skill was not moved" test -f "$S/general/plain-adopt/SKILL.md"
rm -rf "$S/general/plain-adopt"
preset
mv "$T/terms" "$T/terms.away"
expect_rc 1 "scan fails without the terms file" psync scan personal
expect_out 'refresh-markers' "the missing terms file names the fix"
expect_rc 1 "sync fails without the terms file" psync sync
printf 'plain notes\n' > "$F/more.md"
git -C "$PC" add -A
expect_rc 1 "the commit guard fails without the terms file" git -C "$PC" -c commit.gpgsign=false commit -qm "docs: more"
preset
expect_rc 0 "install still works without the terms file" "$TOOL" install
check "install recreated the terms file" test -s "$T/terms"
rm -f "$T/terms.away"
skill "$S/dev/escape-a" escape-a
mkdir -p "$S/dev/escape-a/scripts"
cat > "$S/dev/escape-a/scripts/report.sh" <<'EOF'
printf "Summary:\nACME-42 done\n"
EOF
skill "$S/dev/escape-b" escape-b
cat > "$S/dev/escape-b/run.sh" <<'EOF'
echo "see:\twidget-server"
EOF
skill "$S/dev/name-notes" name-notes
mkdir -p "$S/dev/name-notes/references" && printf 'plain notes\n' > "$S/dev/name-notes/references/gadgetron.md"
skill "$S/dev/linked" linked
ln -s /opt/elsewhere "$S/dev/linked/data"
expect_rc 0 "migrate plan with escapes, names and links" "$TOOL" migrate
expect_out 'escape-a +dev/escape-a +work' 'a \nACME-42 escape in a script marks work'
expect_out 'escape-b +dev/escape-b +work' 'a \twidget-server escape in a script marks work'
expect_out 'name-notes +dev/name-notes +work' "a marker in a file name marks work"
expect_out 'linked +dev/linked +SKIP:symlink' "a skill with a symlink is skipped"
for n in escape-a escape-b name-notes; do
  expect_rc 1 "adopt refuses $n for the personal repo" "$TOOL" adopt "$n" personal
done
expect_rc 1 "adopt refuses a skill with a symlink" "$TOOL" adopt linked personal
expect_out 'symlink' "refused for the symlink reason"
rm -rf "$S/dev/escape-a" "$S/dev/escape-b" "$S/dev/name-notes" "$S/dev/linked"

printf 'remote enforcement\n'
git clone -q --bare "$PR" "$T/elsewhere.git"
ELSE="$(git --git-dir="$T/elsewhere.git" for-each-ref)"
skill "$PC/skills/general/moved" moved
git -C "$PC" remote set-url origin "$T/elsewhere.git"
expect_rc 1 "sync refuses an origin that is not the configured remote" psync sync
expect_out 'HERMES_CONFIG_SYNC_PERSONAL_REMOTE' "the mismatch names the setting"
check "origin mismatch: nothing committed" test "$(git -C "$PC" rev-parse HEAD)" = "$PBASE"
expect_rc 1 "pull refuses an origin that is not the configured remote" psync pull
expect_rc 1 "verify flags an origin mismatch" "$TOOL" verify
expect_out 'personal origin mismatch' "origin mismatch is named"
git -C "$PC" remote set-url origin "$PR"
git -C "$PC" config remote.origin.pushurl "$T/elsewhere.git"
expect_rc 1 "sync refuses a pushurl that is not the configured remote" psync sync
expect_rc 1 "push refuses a pushurl that is not the configured remote" psync push
expect_out 'push URL is not HERMES_CONFIG_SYNC_PERSONAL_REMOTE' "push names the push URL mismatch"
check "nothing pushed to the other remote" test "$(git --git-dir="$T/elsewhere.git" for-each-ref)" = "$ELSE"
expect_rc 1 "verify flags a pushurl mismatch" "$TOOL" verify
reject_out '\[ OK \] personal origin' "verify does not pass a pushurl mismatch"
git -C "$PC" config --unset remote.origin.pushurl
git -C "$PC" config "url.$T/elsewhere.git.pushInsteadOf" "$PR"
expect_rc 1 "sync refuses a pushInsteadOf rewrite to another remote" psync sync
check "nothing pushed through the rewrite" test "$(git --git-dir="$T/elsewhere.git" for-each-ref)" = "$ELSE"
git -C "$PC" config --remove-section "url.$T/elsewhere.git"
preset
rm -rf "$T/elsewhere.git"

printf 'guard in the work repo / clean sync\n'
WB="$(git -C "$WC" symbolic-ref --short HEAD)"
git -C "$WC" fetch -q origin && git -C "$WC" reset -q --hard "origin/$WB"  # drop the diverged test commit
WREFS="$(git --git-dir="$T/remote-work.git" for-each-ref)"
printf 'key %s\n' "$FAKE_AWS" > "$WC/skills/dev/acme-deploy/creds.md"
git -C "$WC" add -A && git -C "$WC" -c commit.gpgsign=false commit -q --no-verify -m "wip"
git -C "$WC" rm -q skills/dev/acme-deploy/creds.md && git -C "$WC" -c commit.gpgsign=false commit -qm "chore: drop creds"
expect_rc 1 "sync blocks a secret in an outgoing blob of the work repo" "$TOOL" sync
expect_out 'possible secrets in work repo' "the work secret is reported"
if grep -qF "$FAKE_AWS" "$T/out"; then fail "outgoing secret value not echoed"; else pass "outgoing secret value not echoed"; fi
check "work remote unchanged" test "$(git --git-dir="$T/remote-work.git" for-each-ref)" = "$WREFS"
git -C "$WC" reset -q --hard "origin/$WB"
rm -f "$PC/.git/hooks/pre-push"
expect_rc 1 "verify fails without the pre-push guard" "$TOOL" verify
expect_out 'personal pre-push guard missing' "the missing pre-push guard is named"
expect_rc 0 "install restores the pre-push guard" "$TOOL" install
git -C "$PC" checkout -qb topic
skill "$PC/skills/general/topic-one" topic-one
git -C "$PC" add -A && git -C "$PC" -c commit.gpgsign=false commit -qm "feat: topic"
expect_rc 0 "push publishes a new clean branch" psync push
check "the new branch has an upstream" git -C "$PC" rev-parse --verify --quiet '@{u}'
check "the remote has the new branch" git --git-dir="$PR" rev-parse --verify --quiet refs/heads/topic
preset
skill "$PC/skills/general/clean-one" clean-one
expect_rc 0 "a clean sync still commits and pushes" psync sync
expect_out 'personal: committed [0-9a-f]+ — chore: sync skills \(clean-one\)' "clean sync commit message"
expect_out 'personal: pushed 1 commit' "clean sync pushed"
check "remote has the clean commit" test "$(git -C "$PC" rev-parse HEAD)" = "$(git --git-dir="$PR" rev-parse "refs/heads/$PB")"
expect_rc 0 "idle sync after the guard tests" "$TOOL" sync
if [[ -s "$T/out" ]]; then fail "idle sync stays silent"; sed 's/^/       /' "$T/out" >&2; else pass "idle sync stays silent"; fi

printf 'state backup: cron jobs + scripts\n'
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
P="$T/clones/personal/machines/testhost"
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
expect_out 'personal: state backup left out:' "left-out jobs reported on first sync"
expect_out 'personal: committed [0-9a-f]+ — chore: sync state backup' "state backup commit message"
check "personal remote has the backup" git --git-dir="$T/remote-personal.git" cat-file -e HEAD:machines/testhost/default/jobs.json
jq '.jobs[0].next_run_at = "2031-01-01T03:00:00" | .jobs[0].last_status = "error" | .jobs[0].repeat.completed = 9' "$HERMES_HOME/cron/jobs.json" > "$T/j" && mv "$T/j" "$HERMES_HOME/cron/jobs.json"
expect_rc 0 "sync after a run" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" sync
if [[ -s "$T/out" ]]; then fail "run-only changes and the same left-out set stay silent"; sed 's/^/       /' "$T/out" >&2; else pass "run-only changes and the same left-out set stay silent"; fi
jq '.jobs |= map(select(.id != "j_clean"))' "$HERMES_HOME/cron/jobs.json" > "$T/j" && mv "$T/j" "$HERMES_HOME/cron/jobs.json"
rm -f "$HERMES_HOME/scripts/clean.sh"
expect_rc 0 "sync records a removed job" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL" sync
expect_out 'chore: sync state backup' "removal committed"
if [[ -e "$P/default/jobs.json" || -e "$P/default/scripts/clean.sh" ]]; then fail "removed job and script gone from the backup"; else pass "removed job and script gone from the backup"; fi
check "other host's backup untouched" bash -c "mkdir -p '$T/clones/personal/machines/otherhost' && touch '$T/clones/personal/machines/otherhost/keep' && env HERMES_CONFIG_SYNC_ENV='$T/env-personal' '$TOOL' backup-state >/dev/null && test -f '$T/clones/personal/machines/otherhost/keep'"
rm -rf "$T/clones/personal/machines/otherhost"
expect_rc 0 "backup into the work repo" env HERMES_CONFIG_SYNC_ENV="$T/env-work" HERMES_CONFIG_SYNC_CRON_BACKUP=work "$TOOL" backup-cron
check "work repo keeps work-named jobs" test "$(jq -r '[.jobs[].id] | join(",")' "$T/clones/work/machines/testhost/default/jobs.json")" = j_work
absent_in "work repo still blocks secrets" "$FAKE_AWS" "$T/clones/work/machines"
rm -rf "$T/clones/work/machines"
expect_rc 1 "bad host label refused" env HERMES_CONFIG_SYNC_ENV="$T/env-personal" HERMES_CONFIG_SYNC_CRON_HOST=../x "$TOOL" backup-cron
expect_rc 1 "backup off is explicit" env HERMES_CONFIG_SYNC_ENV="$T/env-work" "$TOOL" backup-cron
unset HERMES_CONFIG_SYNC_CRON_HOST

printf 'state backup: config fields only, fails safe, no symlinks\n'
export HERMES_CONFIG_SYNC_CRON_HOST=testhost
TP=(env HERMES_CONFIG_SYNC_ENV="$T/env-personal" "$TOOL")
PC="$T/clones/personal"
RP="$T/remote-personal.git"
J="$HERMES_HOME/cron/jobs.json"
jq '.jobs += [{id: "j_keep", name: "keep", prompt: "summarize my notes", skills: ["tidy-notes"], skill: "tidy-notes",
  schedule: {kind: "cron", expr: "0 6 * * *", display: "0 6 * * *"}, schedule_display: "0 6 * * *",
  repeat: {times: 3, completed: 1}, enabled: true, deliver: "local", created_at: "2029-01-01T00:00:00",
  state: "scheduled", pending_slot: "testhost:4242", run_claim: {by: "testhost:4242", at: "2029-01-02T06:00:00"},
  last_dispatch: {at: "2029-01-02T06:00:00", slot: "2029-01-02T06:00:00"}, last_fire_error: null,
  quota_hold_until: null, future_runtime_field: 1}]' "$J" > "$T/j" && mv "$T/j" "$J"
expect_rc 0 "sync backs up a job carrying scheduler runtime fields" "${TP[@]}" sync
expect_out 'chore: sync state backup' "whitelisted job committed"
KEEP='.jobs[] | select(.id == "j_keep")'
check "scheduler runtime and unknown fields not in the backup" test "$(jq "$KEEP"' | [has("state", "pending_slot", "run_claim", "last_dispatch", "last_fire_error", "quota_hold_until", "future_runtime_field"), (.repeat | has("completed"))] | any' "$P/default/jobs.json")" = false
check "configuration fields kept" test "$(jq "$KEEP"' | .name == "keep" and .prompt == "summarize my notes" and .skills == ["tidy-notes"] and .schedule.expr == "0 6 * * *" and .repeat == {times: 3} and .enabled == true and .deliver == "local" and .created_at == "2029-01-01T00:00:00"' "$P/default/jobs.json")" = true
jq '(.jobs[] | select(.id == "j_keep")) |= (.state = "error" | .pending_slot = "testhost:5151" | .run_claim.by = "testhost:5151"
  | .last_dispatch.at = "2029-01-03T06:00:00" | .last_fire_error = "boom" | .last_delivery_queued = true
  | .quota_hold_until = "2029-01-03T07:00:00" | .future_runtime_field = 2 | .repeat.completed = 2)' "$J" > "$T/j" && mv "$T/j" "$J"
before="$(git -C "$PC" rev-parse HEAD)"
expect_rc 0 "sync after scheduler-only changes" "${TP[@]}" sync
if [[ -s "$T/out" ]]; then fail "scheduler-only changes stay silent"; sed 's/^/       /' "$T/out" >&2; else pass "scheduler-only changes stay silent"; fi
check "scheduler-only changes make no commit" test "$(git -C "$PC" rev-parse HEAD)" = "$before"
cp "$J" "$T/jobs.good"
GOOD_TREE="$(git -C "$PC" rev-parse HEAD:machines/testhost)"
# The last pushed backup is still in place: clone working tree, clone HEAD, remote.
backup_intact() {
  [[ -z "$(git -C "$PC" status --porcelain -- machines cron)" ]] \
    && [[ "$(git -C "$PC" rev-parse HEAD:machines/testhost)" == "$GOOD_TREE" ]] \
    && [[ "$(git --git-dir="$RP" rev-parse HEAD:machines/testhost)" == "$GOOD_TREE" ]]
}
check "good backup present on the remote" git --git-dir="$RP" cat-file -e HEAD:machines/testhost/default/jobs.json

before="$(git -C "$PC" rev-parse HEAD)"
printf '\nlocked edit\n' >> "$PC/skills/general/fresh/SKILL.md"
: > "$PC/.git/index.lock"
expect_rc 1 "sync fails on a stale index.lock" "${TP[@]}" sync
expect_out 'personal: .*git add' "failed staging is reported"
check "nothing committed while the index is locked" test "$(git -C "$PC" rev-parse HEAD)" = "$before"
check "edit kept in the working tree" grep -q 'locked edit' "$PC/skills/general/fresh/SKILL.md"
rm -f "$PC/.git/index.lock"
expect_rc 0 "sync commits the edit once the lock is gone" "${TP[@]}" sync
expect_out 'personal: pushed 1 commit' "edit pushed after the lock is gone"

printf '{"jobs": [' > "$J"
expect_rc 1 "backup-cron fails on a malformed jobs.json" "${TP[@]}" backup-cron
expect_out 'state backup failed' "malformed jobs.json is reported"
check "malformed jobs.json: backup-cron keeps the backup" backup_intact
expect_rc 1 "sync fails on a malformed jobs.json" "${TP[@]}" sync
expect_out 'personal: state backup failed' "sync names the failed state backup"
check "malformed jobs.json: sync keeps the backup, here and on the remote" backup_intact
printf '{"jobs": {"j_keep": {}}}\n' > "$J"
expect_rc 1 "backup-cron fails when .jobs is not an array" "${TP[@]}" backup-cron
check ".jobs not an array: backup kept" backup_intact
: > "$J"
expect_rc 1 "sync fails on an empty jobs.json" "${TP[@]}" sync
check "empty jobs.json: backup kept" backup_intact
cp "$T/jobs.good" "$J"
if (( EUID == 0 )); then
  printf '  skip unreadable jobs.json (running as root)\n'
else
  chmod 000 "$J"
  expect_rc 1 "backup-cron fails on an unreadable jobs.json" "${TP[@]}" backup-cron
  check "unreadable jobs.json: backup-cron keeps the backup" backup_intact
  expect_rc 1 "sync fails on an unreadable jobs.json" "${TP[@]}" sync
  check "unreadable jobs.json: sync keeps the backup, here and on the remote" backup_intact
  chmod 644 "$J"
  chmod 000 "$HERMES_HOME/scripts/lib/util.sh"
  expect_rc 1 "sync fails on an unreadable script" "${TP[@]}" sync
  check "unreadable script: backup kept" backup_intact
  chmod 644 "$HERMES_HOME/scripts/lib/util.sh"
fi
expect_rc 1 "backup-cron fails on a missing Hermes root" env HERMES_CONFIG_SYNC_HERMES_ROOT="$T/no-such-root" "${TP[@]}" backup-cron
check "missing root: backup-cron keeps the backup" backup_intact
expect_rc 1 "sync fails on a missing Hermes root" env HERMES_CONFIG_SYNC_HERMES_ROOT="$T/no-such-root" "${TP[@]}" sync
check "missing root: sync keeps the backup, here and on the remote" backup_intact
expect_rc 0 "sync is clean again once the inputs are fixed" "${TP[@]}" sync
check "recovered sync leaves the backup as it was" backup_intact

mkdir -p "$HERMES_HOME/profiles/p2/scripts" "$HERMES_HOME/profiles/p3/cron"
expect_rc 0 "sync with an empty scripts dir, no cron dir, a cron dir without jobs.json" "${TP[@]}" sync
if [[ -e "$P/p2" || -e "$P/p3" ]]; then fail "empty profiles leave no backup dir"; else pass "empty profiles leave no backup dir"; fi
check "empty profiles change nothing" backup_intact
mkdir -p "$T/bare-root/cron"
printf '{"jobs": []}\n' > "$T/bare-root/cron/jobs.json"
expect_rc 0 "backup-cron with no profiles dir and no scripts dir" env HERMES_CONFIG_SYNC_HERMES_ROOT="$T/bare-root" HERMES_CONFIG_SYNC_CRON_HOST=host2 "${TP[@]}" backup-cron
if [[ -e "$PC/machines/host2" ]]; then fail "nothing to back up writes nothing"; else pass "nothing to back up writes nothing"; fi
rm -rf "$HERMES_HOME/profiles/p2" "$HERMES_HOME/profiles/p3" "$T/bare-root"

mkdir -p "$T/outside/dir"
printf 'private outside notes\n' > "$T/outside/dir/gadgetron-plan.txt"
printf '#!/usr/bin/env bash\necho outside\n' > "$T/outside/tool.sh"
ln -s "$T/outside/tool.sh" "$HERMES_HOME/scripts/linked.sh"
ln -s "$T/outside/dir" "$HERMES_HOME/scripts/linked-dir"
expect_rc 0 "sync with symlinked scripts" "${TP[@]}" sync
expect_out 'script linked\.sh: symlink' "symlinked script file reported as left out"
expect_out 'script linked-dir: symlink' "symlinked script dir reported as left out"
if [[ -e "$P/default/scripts/linked.sh" || -L "$P/default/scripts/linked.sh" || -e "$P/default/scripts/linked-dir" || -L "$P/default/scripts/linked-dir" ]]; then
  fail "symlinks not copied"; else pass "symlinks not copied"; fi
if git --git-dir="$RP" ls-tree -r --name-only HEAD | grep -qE 'gadgetron|linked'; then fail "nothing behind a symlink reached the remote"; else pass "nothing behind a symlink reached the remote"; fi
check "real scripts still backed up next to symlinks" test -f "$P/default/scripts/lib/util.sh"
rm -f "$HERMES_HOME/scripts/linked.sh" "$HERMES_HOME/scripts/linked-dir"

jq '.jobs = []' "$T/jobs.good" > "$J"
expect_rc 0 'sync with {"jobs": []}' "${TP[@]}" sync
expect_out 'chore: sync state backup' "emptied job list committed"
if [[ -e "$P/default/jobs.json" ]]; then fail "emptied job list removes the jobs backup"; else pass "emptied job list removes the jobs backup"; fi
absent "removal pushed" machines/testhost/default/jobs.json git --git-dir="$RP" ls-tree -r --name-only HEAD
unset HERMES_CONFIG_SYNC_CRON_HOST

printf 'state backup: machine files\n'
export HERMES_CONFIG_SYNC_STATE_HOST=testhost
H="$HERMES_HOME" M="$PC/machines/testhost" U="$XDG_CONFIG_HOME/systemd/user"
mkdir -p "$H/memories" "$H/agent-hooks/lib/__pycache__" "$H/scripts/__pycache__" "$H/scripts/mcp-tokens" "$T/linked" "$U"
printf 'be brief\n' > "$H/SOUL.md"
printf '{"allow": ["echo"]}\n' > "$H/shell-hooks-allowlist.json"
printf 'remember the plan\n' > "$H/memories/MEMORY.md"
printf 'user key %s\n' "$FAKE_AWS" > "$H/memories/USER.md"
printf 'not a tracked memory file\n' > "$H/memories/notes.md"
printf '#!/usr/bin/env bash\necho hook\n' > "$H/agent-hooks/on-start.sh"
chmod 755 "$H/agent-hooks/on-start.sh"
printf 'helper\n' > "$H/agent-hooks/lib/util.py"
printf 'bytecode\n' > "$H/agent-hooks/lib/__pycache__/util.cpython-312.pyc"
printf 'every script, not only the ones a job names\n' > "$H/scripts/adhoc.sh"
printf 'bytecode\n' > "$H/scripts/__pycache__/tool.cpython-312.pyc"
printf 'bytecode\n' > "$H/scripts/tool.pyc"
printf 'lock\n' > "$H/scripts/run.lock"
printf 'old\n' > "$H/scripts/run.sh.bak-20290101"
printf 'X=1\n' > "$H/scripts/.env.local"
printf '{}\n' > "$H/scripts/auth.json"
printf 'db\n' > "$H/scripts/cache.db"
printf 'db\n' > "$H/scripts/cache.db-wal"
printf '{"token": 1}\n' > "$H/scripts/mcp-tokens/server.json"
# p1: a symlinked config.yaml (tracked where it points), a SOUL that names work.
printf 'model: linked\n' > "$T/linked/config.yaml"
ln -s "$T/linked/config.yaml" "$H/profiles/p1/config.yaml"
printf 'You help with Acmecorp deploys.\n' > "$H/profiles/p1/SOUL.md"
printf 'name: p1\n' > "$H/profiles/p1/profile.yaml"
mkdir -p "$H/profiles/p1/agent-hooks" && printf 'x\n' > "$H/profiles/p1/agent-hooks/h.sh"
mkdir -p "$H/profiles/systemd" && printf 'clash\n' > "$H/profiles/systemd/SOUL.md"
mkdir -p "$H/profiles/env-names.txt" && printf 'clash\n' > "$H/profiles/env-names.txt/SOUL.md"
# p4: a real config.yaml with credentials no token pattern knows.
CFG_PASS="sentinelNotATokenShape""123" CFG_KEY="plainSentinel""456"
mkdir -p "$H/profiles/p4"
cat > "$H/profiles/p4/config.yaml" <<EOF
model:
  default: some-model
  max_tokens: 4096
  api_key: "$CFG_KEY"
  base_url: \${SOME_VAR}
dashboard:
  basic_auth:
    username: me
    password_hash: $CFG_PASS
compression:
  threshold_tokens: 50000
  summary_tokens_ceiling: 8000
context_tokens: 128000
proactive_prune_tokens: 1000
secret_ref: "\${OTHER_VAR}"
token_limit: null
EOF
# p5: other YAML shapes of a credential: a flow map, a parent key ending in
# ":", list items, quoted keys. p6/p7: a flow map and a credential's quoted
# value that run over lines; the file is still copied, redacted.
CFG_FLOW="flowSentinel""111" CFG_PARENT="parentSentinel""222" CFG_LIST="listSentinel""333"
CFG_QUOTED="quotedSentinel""444" CFG_FLOWLIST="flowListSentinel""555" CFG_OPEN="openFlowSentinel""666" CFG_OPENQ="openQuoteSentinel""777"
CFG_ANCHOR="anchoredSentinel""811" CFG_SPACED2="spacedKeySentinel""812" CFG_SPACED3="spacedKeySentinel""813" CFG_FLOWNEXT="flowNextSentinel""814"
CFG_BLOCK="blockSentinel""815" CFG_TAG="tagSentinel""816" CFG_ANCHOR2="anchorValueSentinel""817" CFG_SEQ="seqSentinel""818"
mkdir -p "$H/profiles/p5" "$H/profiles/p6" "$H/profiles/p7" "$H/profiles/p8" "$H/profiles/p9" "$H/profiles/p10"
cat > "$H/profiles/p5/config.yaml" <<EOF
model: {default: some-model, api_key: "$CFG_FLOW"}
before_parent: kept-1
credentials:
  value: $CFG_PARENT
  nested:
    deeper: $CFG_PARENT
after_parent: kept-2
servers:
  - name: alpha
  - api_key: $CFG_LIST
  - token:
      value: $CFG_LIST
  - {name: beta, secret: "$CFG_FLOWLIST"}
"api_key": $CFG_QUOTED
'client_secret':
  - $CFG_QUOTED
limits: {max_tokens: 4096, threshold_tokens: 50000}
plain: ok
EOF
printf 'extra: {a: 1, b: 2,\n  c: 3, api_key: "%s"}\nflow: {name: x,\n  api_key:\n    "%s"}\nplain: ok\n' "$CFG_OPEN" "$CFG_FLOWNEXT" > "$H/profiles/p6/config.yaml"
printf 'api_key: "first part\n  %s"\nplain: ok\n' "$CFG_OPENQ" > "$H/profiles/p7/config.yaml"
# p8: shapes a key-by-key match missed (an anchored flow map, a space before
# a quoted key's colon), a block scalar, a tag, an anchor and an alias, and a
# list at the parent's own indent (how PyYAML writes one).
cat > "$H/profiles/p8/config.yaml" <<EOF
model: &primary {default: some-model, api_key: "$CFG_ANCHOR"}
other:
  default: some-model
  "api_key" : "$CFG_SPACED2"
  'auth_token' : '$CFG_SPACED3'
api_key: |
  $CFG_BLOCK line one

  $CFG_BLOCK line two
password: !!str $CFG_TAG
anchored_token: &tok $CFG_ANCHOR2
alias_secret: *tok
api_keys:
- $CFG_SEQ
- $CFG_SEQ
after: kept-b
EOF
# p9: credential-named keys whose values are kept, and a comment.
cat > "$H/profiles/p9/config.yaml" <<'EOF'
# the api_key comes from the environment
compression:
  threshold_tokens: 350000
model:
  max_tokens: 4096
other_token: ${REFERENCED_VAR}
api_key: ""
use_token: false
token_counter: tiktoken
EOF
# p10: no credential at all, but a quoted string over lines with braces in
# it: copied whole, never left out for its shape.
printf 'model:\n  default: some-model\nagent:\n  system_prompt: "Return results using this layout:\n    {\n      result: text\n    }"\n  note: fine\n' > "$H/profiles/p10/config.yaml"
ENV_VALUE="envvalue""-must-not-leak-42"
printf '# COMMENTED=%s\nFOO_TOKEN=%s\nexport BAR_NAME="%s"\n\nnot a var line\n' "$ENV_VALUE" "$ENV_VALUE" "$ENV_VALUE" > "$H/.env"
printf '[Service]\nExecStart=hermes gateway\n' > "$U/hermes-gateway.service"
printf '[Timer]\nOnCalendar=daily\n' > "$U/hermes-sync.timer"
printf '[Service]\nExecStart=true\n' > "$U/other.service"
printf '[Service]\nExecStart=true\n' > "$T/linked/hermes-linked.service"
ln -s "$T/linked/hermes-linked.service" "$U/hermes-linked.service"
printf '\nLocal edit.\n' >> "$S/general/stock-skill/SKILL.md"
mkdir -p "$S/general/stock-skill/scripts/__pycache__"
printf 'bytecode\n' > "$S/general/stock-skill/scripts/__pycache__/x.cpython-312.pyc"
printf 'old\n' > "$S/general/stock-skill/SKILL.md.bak"
export HERMES_CONFIG_SYNC_STOCK_SKILLS="stock-skill no-such-skill"
# The layout before machines/: this host's dir moves, another host's stays.
mkdir -p "$PC/cron/testhost/default" "$PC/cron/otherhost" "$PC/machines/otherhost/default"
printf '{"jobs": []}\n' > "$PC/cron/testhost/default/jobs.json"
printf 'keep\n' > "$PC/cron/otherhost/keep"
printf 'keep\n' > "$PC/machines/otherhost/default/keep"
git -C "$PC" add -A && git -C "$PC" -c commit.gpgsign=false commit -qm "chore: old layout"
expect_rc 0 "backup-state snapshots the machine" "${TP[@]}" backup-state
expect_out 'testhost/default file memories/USER.md: possible secret' "file with a secret left out, with the reason"
expect_out "testhost/p1 file SOUL.md: names 'Acmecorp'" "work-named file left out of the personal repo"
expect_out 'testhost stock skill no-such-skill: not found' "unknown stock skill reported, not fatal"
expect_out 'testhost/systemd profile: name clashes' "profile clashing with a host-level dir reported"
expect_out 'testhost/env-names\.txt profile: name clashes' "profile named env-names.txt left out and reported"
expect_out '^ ?[?MAD]+ +machines/testhost' "backup-state shows the git status of machines/"
reject_out "$FAKE_AWS" "backup-state does not echo the secret"
reject_out 'testhost/p(6|7|8|9|10) file config\.yaml' "config.yaml over lines or with odd shapes: never left out, so not reported"
for f in default/config.yaml default/SOUL.md default/shell-hooks-allowlist.json default/memories/MEMORY.md p1/profile.yaml \
  p1/jobs.json default/scripts/adhoc.sh default/agent-hooks/on-start.sh default/agent-hooks/lib/util.py \
  systemd/hermes-gateway.service systemd/hermes-sync.timer stock-skill-edits/stock-skill/SKILL.md env-names.txt; do
  check "$f backed up" test -f "$M/$f"
done
check "agent-hooks mode kept" test -x "$M/default/agent-hooks/on-start.sh"
check "stock skill copy has the local edit" grep -q 'Local edit' "$M/stock-skill-edits/stock-skill/SKILL.md"
check "env-names.txt holds the sorted names" test "$(cat "$M/env-names.txt")" = $'BAR_NAME\nFOO_TOKEN'
for f in default/memories/USER.md default/memories/notes.md p1/config.yaml p1/SOUL.md p1/agent-hooks \
  systemd/hermes-linked.service systemd/other.service stock-skill-edits/no-such-skill; do
  if [[ -e "$M/$f" || -L "$M/$f" ]]; then fail "$f not backed up"; else pass "$f not backed up"; fi
done
none_found "caches, locks, backups, .env, auth.json, databases and mcp-tokens never copied" "$M" \( -name __pycache__ -o -name '*.pyc' \
  -o -name '*.lock' -o -name '*.bak*' -o -name '.env*' -o -name auth.json -o -name '*.db*' -o -name mcp-tokens \)
check "this host's old cron/ dir removed" test ! -e "$PC/cron/testhost"
check "another host's cron/ dir kept" test -f "$PC/cron/otherhost/keep"
check "another host's machines/ dir kept" test -f "$PC/machines/otherhost/default/keep"
expect_rc 0 "sync commits the machine state" "${TP[@]}" sync
expect_out 'personal: committed [0-9a-f]+ — chore: sync state backup' "machine state commit message"
expect_out 'personal: state backup left out:' "changed left-out set reported"
check "remote has the machine state" git --git-dir="$RP" cat-file -e HEAD:machines/testhost/default/memories/MEMORY.md
check "remote has the env names" bash -c "git --git-dir='$RP' show HEAD:machines/testhost/env-names.txt | grep -qx FOO_TOKEN"
absent "old cron/ dir removal pushed" cron/testhost/ git --git-dir="$RP" ls-tree -r --name-only HEAD
absent_in "no .env value in the working tree" "$ENV_VALUE" "$PC"
absent "no .env value in the clone's history" "$ENV_VALUE" git -C "$PC" log -p --all
absent "no .env value in the pushed history" "$ENV_VALUE" git --git-dir="$RP" log -p --all
absent "no secret anywhere in the pushed history" "$FAKE_AWS" git --git-dir="$RP" log -p --all
C4="$M/p4/config.yaml"
check "config.yaml: credential values redacted" grep -qx '    password_hash: <redacted>' "$C4"
check "config.yaml: quoted api_key redacted" grep -qx '  api_key: <redacted>' "$C4"
check "config.yaml: \${VAR} references kept" bash -c "grep -qxF '  base_url: \${SOME_VAR}' '$C4' && grep -qxF 'secret_ref: \"\${OTHER_VAR}\"' '$C4'"
check "config.yaml: numeric *_tokens keys and null kept" bash -c "grep -qx '  max_tokens: 4096' '$C4' && grep -qx '  threshold_tokens: 50000' '$C4' && grep -qx '  summary_tokens_ceiling: 8000' '$C4' && grep -qx 'context_tokens: 128000' '$C4' && grep -qx 'proactive_prune_tokens: 1000' '$C4' && grep -qx 'token_limit: null' '$C4'"
C5="$M/p5/config.yaml"
check "config.yaml: a flow map naming a credential is redacted whole" grep -qx 'model: <redacted>' "$C5"
check "config.yaml: a credential parent ending in : is redacted with its subtree" grep -qx 'credentials: <redacted>' "$C5"
check "config.yaml: credential list items redacted" bash -c "grep -qx '  - api_key: <redacted>' '$C5' && grep -qx '  - token: <redacted>' '$C5' && grep -qx '  # <redacted line>' '$C5'"
check "config.yaml: quoted credential keys redacted" bash -c "grep -qx '\"api_key\": <redacted>' '$C5' && grep -qx \"'client_secret': <redacted>\" '$C5'"
check "config.yaml: ordinary keys around them kept" bash -c "grep -qx 'before_parent: kept-1' '$C5' && grep -qx 'after_parent: kept-2' '$C5' && grep -qx '  - name: alpha' '$C5' && grep -qx 'plain: ok' '$C5'"
check "config.yaml: a flow map with a credential word is redacted, even with numbers" grep -qx 'limits: <redacted>' "$C5"
C6="$M/p6/config.yaml" C7="$M/p7/config.yaml" C8="$M/p8/config.yaml" C9="$M/p9/config.yaml"
check "config.yaml: flow map over lines: copied, the credential line redacted" bash -c "grep -qxF 'extra: {a: 1, b: 2,' '$C6' && grep -qx '  c: <redacted>' '$C6' && grep -qx 'plain: ok' '$C6'"
check "config.yaml: flow map over lines, credential key on a later line, value below it: redacted" bash -c "grep -qxF 'flow: {name: x,' '$C6' && grep -qx '  api_key: <redacted>' '$C6' && test \"\$(grep -c . '$C6')\" = 5"
check "config.yaml: credential quoted over more-indented lines: redacted with them" bash -c "test \"\$(cat '$C7')\" = \$'api_key: <redacted>\nplain: ok'"
check "config.yaml: anchored flow map redacted" grep -qx 'model: <redacted>' "$C8"
check "config.yaml: quoted keys with a space before the colon redacted" bash -c "grep -qx '  \"api_key\": <redacted>' '$C8' && grep -qx \"  'auth_token': <redacted>\" '$C8'"
check "config.yaml: block scalar credential redacted with all its lines" bash -c "grep -qx 'api_key: <redacted>' '$C8' && ! grep -q 'line one\|line two' '$C8'"
check "config.yaml: tagged, anchored and alias values redacted" bash -c "grep -qx 'password: <redacted>' '$C8' && grep -qx 'anchored_token: <redacted>' '$C8' && grep -qx 'alias_secret: <redacted>' '$C8'"
check "config.yaml: a list at the credential key's own indent redacted" bash -c "grep -qx 'api_keys: <redacted>' '$C8' && ! grep -q '^- ' '$C8'"
check "config.yaml: ordinary keys around odd shapes kept" bash -c "grep -qx 'other:' '$C8' && grep -qx '  default: some-model' '$C8' && grep -qx 'after: kept-b' '$C8'"
check "config.yaml: plain values that need no redaction kept" bash -c "grep -qx '  threshold_tokens: 350000' '$C9' && grep -qx '  max_tokens: 4096' '$C9' && grep -qxF 'other_token: \${REFERENCED_VAR}' '$C9' && grep -qx 'api_key: \"\"' '$C9' && grep -qx 'use_token: false' '$C9'"
check "config.yaml: comment lines copied as they are" grep -qx '# the api_key comes from the environment' "$C9"
check "config.yaml: any other value under a credential word redacted (over-redaction)" grep -qx 'token_counter: <redacted>' "$C9"
check "config.yaml: quoted text over lines with braces, no credential: copied whole" cmp -s "$H/profiles/p10/config.yaml" "$M/p10/config.yaml"
for v in "$CFG_PASS" "$CFG_KEY" "$CFG_FLOW" "$CFG_PARENT" "$CFG_LIST" "$CFG_QUOTED" "$CFG_FLOWLIST" "$CFG_OPEN" "$CFG_OPENQ" \
  "$CFG_ANCHOR" "$CFG_SPACED2" "$CFG_SPACED3" "$CFG_FLOWNEXT" "$CFG_BLOCK" "$CFG_TAG" "$CFG_ANCHOR2" "$CFG_SEQ"; do
  absent_in "config credential not in the working tree ($v)" "$v" "$PC"
  absent "config credential not in the clone's history ($v)" "$v" git -C "$PC" log -p --all
  absent "config credential not in the pushed history ($v)" "$v" git --git-dir="$RP" log -p --all
done
# The redactor fed directly, under both awks the tool may meet as `awk`.
REDACT_AWK="$(sed -n '/^CONFIG_REDACT_AWK=/,/^AWK$/p' "$TOOL" | sed '1d;$d')"
check "redactor program read from the tool" test -n "$REDACT_AWK"
# redacts <desc> <input> <text that must go> <line that must stay>
redacts() {
  local desc="$1" input="$2" gone="$3" kept="$4" a rc
  for a in gawk mawk; do
    if ! command -v "$a" >/dev/null; then printf '  skip %s (%s not installed)\n' "$desc" "$a"; continue; fi
    rc=0; printf '%s' "$input" | "$a" "$REDACT_AWK" > "$T/redacted" 2>&1 || rc=$?
    if (( rc )); then fail "$desc ($a failed, rc=$rc)"; sed 's/^/       /' "$T/redacted" >&2
    elif grep -qF -- "$gone" "$T/redacted" || ! grep -qxF -- "$kept" "$T/redacted"; then fail "$desc ($a)"; sed 's/^/       /' "$T/redacted" >&2
    else pass "$desc ($a)"; fi
  done
}
redacts "redactor: CRLF blank line inside a block scalar does not end it" $'password: |\r\n  amber-one\r\n\r\n  amber-two\r\nmodel: demo\r\n' amber $'model: demo\r'
redacts "redactor: list under an unreadable credential header redacted" $'"api_keys[primary]":\n- violet-one\n- violet-two\nmodel: demo\n' violet 'model: demo'
redacts "redactor: unreadable credential list item keeps its siblings" $'servers:\n  - {name: alpha, secret: violet-one}\n  - name: beta\n' violet '  - name: beta'
redacts "redactor: tab after the sequence dash still a list item" $'api_keys:\n-\tviolet-one\n-\tviolet-two\nmodel: demo\n' violet 'model: demo'
expect_rc 0 "second sync with nothing changed" "${TP[@]}" sync
if [[ -s "$T/out" ]]; then fail "second sync is silent"; sed 's/^/       /' "$T/out" >&2; else pass "second sync is silent"; fi
if (( EUID != 0 )); then
  chmod 000 "$H/memories/MEMORY.md"
  expect_rc 1 "backup-state fails on an unreadable memory file" "${TP[@]}" backup-state
  absent "unreadable memory file: machines/ left as it was" machines git -C "$PC" status --porcelain -- machines
  chmod 644 "$H/memories/MEMORY.md"
fi
mv "$H/agent-hooks" "$T/linked/agent-hooks" && ln -s "$T/linked/agent-hooks" "$H/agent-hooks"
expect_rc 0 "backup-state with a symlinked agent-hooks" "${TP[@]}" backup-state
check "symlinked agent-hooks not copied" test ! -e "$M/default/agent-hooks"
rm "$H/agent-hooks" && mv "$T/linked/agent-hooks" "$H/agent-hooks"
expect_rc 0 "backup-state with no systemd units" env HERMES_CONFIG_SYNC_SYSTEMD_UNITS= "${TP[@]}" backup-state
check "empty unit list copies no unit" test ! -e "$M/systemd"
expect_rc 0 "backup-state with a custom unit glob" env HERMES_CONFIG_SYNC_SYSTEMD_UNITS='other.*' "${TP[@]}" backup-state
check "custom unit glob picks its units" bash -c "[[ -f '$M/systemd/other.service' && ! -e '$M/systemd/hermes-gateway.service' ]]"
rm -rf "$PC/cron/otherhost" && mkdir -p "$PC/cron/testhost/default" && printf '{}\n' > "$PC/cron/testhost/default/jobs.json"
expect_rc 0 "backup-state drops the last old cron/ dir" "${TP[@]}" backup-state
check "empty cron/ removed" test ! -e "$PC/cron"
WM="$T/clones/work/machines"
expect_rc 0 "state backup into the work repo" env HERMES_CONFIG_SYNC_ENV="$T/env-work" HERMES_CONFIG_SYNC_STATE_BACKUP=work "$TOOL" backup-state
check "work target keeps a work-named file" grep -q Acmecorp "$WM/testhost/p1/SOUL.md"
check "work target still leaves the secret out" test ! -e "$WM/testhost/default/memories/USER.md"
rm -rf "$WM"
expect_rc 0 "CRON_BACKUP picks the target when STATE_BACKUP is unset" env HERMES_CONFIG_SYNC_ENV="$T/env-work" HERMES_CONFIG_SYNC_CRON_BACKUP=work "$TOOL" backup-state
check "CRON_BACKUP fallback wrote the work repo" test -f "$WM/testhost/p1/jobs.json"
rm -rf "$WM"
expect_rc 1 "STATE_BACKUP=off wins over CRON_BACKUP" env HERMES_CONFIG_SYNC_ENV="$T/env-work" HERMES_CONFIG_SYNC_STATE_BACKUP=off HERMES_CONFIG_SYNC_CRON_BACKUP=work "$TOOL" backup-state
expect_out 'state backup is off' "off is named"
expect_rc 0 "CRON_HOST still labels the host" env -u HERMES_CONFIG_SYNC_STATE_HOST HERMES_CONFIG_SYNC_ENV="$T/env-work" HERMES_CONFIG_SYNC_CRON_BACKUP=work HERMES_CONFIG_SYNC_CRON_HOST=oldlabel "$TOOL" backup-cron
check "CRON_HOST fallback label used (backup-cron alias)" test -f "$WM/oldlabel/p1/jobs.json"
expect_rc 0 "STATE_HOST wins over CRON_HOST" env HERMES_CONFIG_SYNC_ENV="$T/env-work" HERMES_CONFIG_SYNC_CRON_BACKUP=work HERMES_CONFIG_SYNC_STATE_HOST=newlabel HERMES_CONFIG_SYNC_CRON_HOST=oldlabel "$TOOL" backup-state
check "STATE_HOST label used, other host kept" bash -c "[[ -f '$WM/newlabel/p1/jobs.json' && -f '$WM/oldlabel/p1/jobs.json' ]]"
rm -rf "$WM"

printf 'state backup: replacing the snapshot\n'
# Every path, type, mode, link target and file hash under a dir.
tree_sum() { (cd "$1" && find . -printf '%p %y %m %l\n' | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum); }
expect_rc 0 "backup-state before the replacement tests" "${TP[@]}" backup-state
SNAP="$(tree_sum "$PC/machines")"
check "a good run leaves no staging dir in .git" bash -c "! compgen -G '$PC/.git/hermes-state.*'"
mv "$PC/machines" "$T/machines-real" && ln -s "$T/machines-real" "$PC/machines"
expect_rc 1 "machines/ a symlink: refused" "${TP[@]}" backup-state
expect_out 'machines is a symlink' "machines/ a symlink: says why"
check "machines/ a symlink: nothing deleted or written behind it" test "$(tree_sum "$T/machines-real")" = "$SNAP"
rm "$PC/machines" && mv "$T/machines-real" "$PC/machines"
ln -s machines "$PC/cron"
expect_rc 1 "cron/ a symlink to machines/: refused" "${TP[@]}" backup-state
check "cron/ a symlink to machines/: the snapshot survives" test "$(tree_sum "$PC/machines")" = "$SNAP"
rm "$PC/cron"
mv "$PC/machines/testhost" "$T/host-real" && ln -s "$T/host-real" "$PC/machines/testhost"
expect_rc 1 "machines/<host> a symlink: refused" "${TP[@]}" backup-state
check "machines/<host> a symlink: link and its target kept" bash -c "[[ -L '$PC/machines/testhost' && -f '$T/host-real/default/SOUL.md' ]]"
rm "$PC/machines/testhost" && mv "$T/host-real" "$PC/machines/testhost"
check "snapshot back in place for the next cases" test "$(tree_sum "$PC/machines")" = "$SNAP"
if (( EUID != 0 )); then
  mode="$(stat -c %a "$PC/machines")"
  chmod 555 "$PC/machines"
  expect_rc 1 "read-only machines/: backup-state fails" "${TP[@]}" backup-state
  expect_out 'left as it was' "read-only machines/: says the repo is unchanged"
  chmod "$mode" "$PC/machines"
  check "read-only machines/: previous snapshot intact" test "$(tree_sum "$PC/machines")" = "$SNAP"
fi
# An mv that fails only when it moves the new tree in: the old one must come back.
mkdir -p "$T/fakemv"
# shellcheck disable=SC2016  # the fake mv's own code, expanded when it runs
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == */tree ]] && { echo "mv: injected failure" >&2; exit 1; }; done\nexec %q "$@"\n' "$(command -v mv)" > "$T/fakemv/mv"
chmod +x "$T/fakemv/mv"
printf 'changed\n' > "$H/SOUL.md.new" && cp "$H/SOUL.md" "$T/soul.keep" && mv "$H/SOUL.md.new" "$H/SOUL.md"
expect_rc 1 "failed move of the new snapshot: backup-state fails" env PATH="$T/fakemv:$PATH" "${TP[@]}" backup-state
expect_out 'previous one is back in place' "failed move of the new snapshot: says the old one is back"
check "failed move of the new snapshot: previous snapshot intact" test "$(tree_sum "$PC/machines")" = "$SNAP"
check "failed move of the new snapshot: no staging dir left" bash -c "! compgen -G '$PC/.git/hermes-state.*'"
mv "$T/soul.keep" "$H/SOUL.md"

printf 'state backup: multi-line .env values\n'
cp "$H/.env" "$T/env.keep"
for q in "'" '"'; do
  [[ "$q" == "'" ]] && qn=single || qn=double
  printf 'FIRST=1\nTOKEN=%sfirst line\nfragmentName=remaining text\nlast line%s\nexport LAST=2\n' "$q" "$q" > "$H/.env"
  expect_rc 0 "multi-line $qn-quoted .env value: backup-state still runs" "${TP[@]}" backup-state
  expect_out 'testhost env-names.txt: .env has a multi-line quoted value' "multi-line $qn-quoted .env value: left-out report names the reason"
  check "multi-line $qn-quoted .env value: no env-names.txt" test ! -e "$M/env-names.txt"
  absent_in "multi-line $qn-quoted .env value: inner name not in the repo" fragmentName "$PC"
done
# Spaces around "=" (TOKEN = "...) still open a quote; a trailing backslash
# continues the line. Neither inner line may become a name.
for shape in spaced continued; do
  if [[ $shape == spaced ]]; then
    printf 'FIRST=1\nTOKEN = "first line\nspacedFragment=zzz\nlast line"\n' > "$H/.env"; frag=spacedFragment why='a multi-line quoted value'
  else
    printf 'FIRST=1\nCONT=prefix\\\ncontFragment=zzz\n' > "$H/.env"; frag=contFragment why='a line ending in a backslash'
  fi
  expect_rc 0 "$shape .env value over lines: backup-state still runs" "${TP[@]}" backup-state
  expect_out "testhost env-names.txt: .env has $why" "$shape .env value over lines: left-out report names the reason"
  check "$shape .env value over lines: no env-names.txt" test ! -e "$M/env-names.txt"
  absent_in "$shape .env value over lines: inner name not in the working tree" "$frag" "$PC"
  expect_rc 0 "$shape .env value over lines: sync" "${TP[@]}" sync
  absent "$shape .env value over lines: inner name not in the clone's history" "$frag" git -C "$PC" log -p --all
done
printf 'SPACED = 1\nexport TIGHT=2\n' > "$H/.env"
expect_rc 0 "NAME = value .env line: backup-state" "${TP[@]}" backup-state
check "NAME = value .env line: name written" test "$(cat "$M/env-names.txt" 2>/dev/null)" = $'SPACED\nTIGHT'
# Quotes that close on their line, a quote inside the other kind, an escaped
# quote and a quote in a comment are all single-line.
printf "A='x \"y\" z' # it's fine\nB=\"p 'q' \\\\\" r\"\nC=plain\\\\'s\nexport D='' E=\"\"\n" > "$H/.env"
expect_rc 0 "single-line quoted .env values: backup-state" "${TP[@]}" backup-state
check "single-line quoted .env values: names written" test "$(cat "$M/env-names.txt" 2>/dev/null)" = $'A\nB\nC\nD'
mv "$T/env.keep" "$H/.env"
expect_rc 0 "backup-state with the usual .env again" "${TP[@]}" backup-state

printf 'state backup: a file name with a newline\n'
NLF="$H/scripts/report"$'\n'"notes.sh"
printf 'x\n' > "$NLF"
expect_rc 0 "newline file name: backup-state still runs" "${TP[@]}" backup-state
expect_out 'testhost/default script report\\nnotes\.sh: name has a newline' "newline file name: reported, the newline escaped"
check "newline file name: other scripts still copied" test -f "$M/default/scripts/adhoc.sh"
none_found "newline file name: not copied" "$M" -name $'*\n*'
rm -f "$NLF"

printf 'state backup: never-copy names on directories\n'
mkdir -p "$H/scripts/archive.bak-old" "$H/scripts/state.db" "$H/agent-hooks/auth.json"
printf 'k\n' > "$H/scripts/archive.bak-old/keep.txt"
printf 'd\n' > "$H/scripts/state.db/data.txt"
printf 'p\n' > "$H/agent-hooks/auth.json/payload.txt"
expect_rc 0 "never-copy dirs: backup-state" "${TP[@]}" backup-state
for f in default/scripts/archive.bak-old default/scripts/state.db default/agent-hooks/auth.json; do
  check "never-copy dirs: $f/ not copied" test ! -e "$M/$f"
done
reject_out 'keep\.txt|data\.txt|payload\.txt' "never-copy dirs: skipped silently, like never-copy files"
check "never-copy dirs: the rest still copied" test -f "$M/default/agent-hooks/on-start.sh"
rm -r "$H/scripts/archive.bak-old" "$H/scripts/state.db" "$H/agent-hooks/auth.json"
"${TP[@]}" verify > "$T/out" 2>&1 || true
expect_out '\[ OK \] state backup → personal repo \(machines/testhost/\)' "verify reports the state backup target"
env HERMES_CONFIG_SYNC_STATE_BACKUP=off "${TP[@]}" verify > "$T/out" 2>&1 || true
expect_out '\[WARN\] state backup is off' "verify warns when the state backup is off"
expect_rc 1 "verify fails on a bad state backup target" env HERMES_CONFIG_SYNC_STATE_BACKUP=both "${TP[@]}" verify
expect_out "state backup target 'both' is not work, personal or off" "bad target is named"
# sync checks the target before it fetches or commits anything: a bad one
# must not quietly skip the backup while the skills still sync.
printf 'pending\n' > "$PC/skills/r25-pending.md"; printf 'pending\n' > "$WC/skills/r25-pending.md"
heads() { git -C "$PC" rev-parse HEAD; git -C "$WC" rev-parse HEAD; git --git-dir="$RP" rev-parse HEAD; git --git-dir="$T/remote-work.git" rev-parse HEAD; }
HEADS="$(heads)"
expect_rc 1 "sync with an unknown state backup target fails" env HERMES_CONFIG_SYNC_STATE_BACKUP=both HERMES_CONFIG_SYNC_ENV="$T/env" "$TOOL" sync
expect_out "state backup target 'both' is not work, personal or off" "sync names the unknown target"
check "unknown target: nothing committed or pushed in either repo" test "$(heads)" = "$HEADS"
expect_rc 1 "sync with a target repo that is not enabled fails" env HERMES_CONFIG_SYNC_STATE_BACKUP=work "${TP[@]}" sync
expect_out "state backup target is the work repo, which is not enabled" "sync names the disabled target"
check "disabled target: nothing committed or pushed" test "$(heads)" = "$HEADS"
expect_rc 0 "sync with the state backup off still syncs" env HERMES_CONFIG_SYNC_STATE_BACKUP=off "${TP[@]}" sync
check "state backup off: the pending change is committed and pushed" test "$(git -C "$PC" rev-parse HEAD)" = "$(git --git-dir="$RP" rev-parse HEAD)" -a "$(git -C "$PC" rev-parse HEAD)" != "$(sed -n 1p <<< "$HEADS")"
rm "$WC/skills/r25-pending.md"
rm -rf "$H/profiles/systemd" "$H/profiles/env-names.txt" "$H/profiles/p4" "$H/profiles/p5" "$H/profiles/p6" "$H/profiles/p7" "$H/profiles/p8" "$H/profiles/p9" "$H/profiles/p10"
unset HERMES_CONFIG_SYNC_STATE_HOST HERMES_CONFIG_SYNC_STOCK_SKILLS

printf '\n'
if (( FAILS )); then printf '%d failure(s)\n' "$FAILS" >&2; exit 1; fi
printf 'all tests passed\n'
