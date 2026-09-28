#!/usr/bin/env bats
# The Bedrock preflight in the seat adapters, against the real aws-sso-ttl and
# fake codex/claude/hermes CLIs. Fixture caches under a throwaway HOME; every
# name and id is a placeholder.

SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
# aws-sso-ttl is installed separately; AWS_SSO_TTL_BIN overrides the PATH lookup.
TTL="${AWS_SSO_TTL_BIN:-$(command -v aws-sso-ttl || true)}"

NOW="$(jq -rn '"2026-09-28T19:47:22Z" | fromdate')"

iso() { jq -rn --argjson t "$1" '$t | todate'; }
sha1() { local o; o="$(printf '%s' "$1" | sha1sum)"; printf '%s\n' "${o%% *}"; }

setup() {
  [[ -n "$TTL" && -x "$TTL" ]] || skip "aws-sso-ttl not found (set AWS_SSO_TTL_BIN or put it on PATH)"
  TTL="$(readlink -f "$TTL")"
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$HOME/.aws/sso/cache" "$HOME/logs" "$HOME/.codex" "$BIN" "$CALLS"
  unset AWS_CONFIG_FILE AWS_SSO_SESSION_DURATION XDG_STATE_HOME HERMES_HOME CODEX_HOME AWS_REGION
  export AWS_SSO_TTL_NOW="$NOW" AWS_SSO_TTL_LOG_DIRS="$HOME/logs" TZ=UTC
  export AWS_SSO_SESSION_DURATION=2h
  export CALLS

  ln -s "$TTL" "$BIN/aws-sso-ttl"
  for tool in aws curl wget nc ssh uv; do
    printf '#!/bin/sh\ntouch "%s/network-tool-called"\nexit 99\n' "$BATS_TEST_TMPDIR" > "$BIN/$tool"
  done
  cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CALLS/codex.args"
printf '%s\n' "${AWS_BEARER_TOKEN_BEDROCK-<unset>}" > "$CALLS/codex.bearer"
printf 'session id: 00000000-0000-0000-0000-000000000001\n' >&2
printf 'review text\n'
EOF
  cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CALLS/claude.args"
printf '%s|%s\n' "${AWS_BEARER_TOKEN_BEDROCK-<unset>}" "${CLAUDE_CODE_USE_BEDROCK-<unset>}" > "$CALLS/claude.env"
printf '{"result": "review text", "stop_reason": "end_turn", "is_error": false}\n'
EOF
  cat > "$BIN/hermes" <<'EOF'
#!/usr/bin/env bash
if [[ $3 == config ]]; then
  printf '%s\n' "${FAKE_HERMES_PROVIDER:-bedrock}"
  exit 0
fi
printf '%s\n' "$@" > "$CALLS/hermes.args"
printf '%s\n' "${AWS_BEARER_TOKEN_BEDROCK-<unset>}" > "$CALLS/hermes.bearer"
printf 'review text\nsession_id: 20260928_000000_abcdef\n'
EOF
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"

  cat > "$HOME/.aws/config" <<'EOF'
[profile work]
sso_session = example-session
sso_account_id = EXAMPLE-ACCOUNT
sso_role_name = ExampleRole
region = us-east-1

[sso-session example-session]
sso_start_url = https://example.invalid/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile other]
sso_session = other-session
sso_account_id = EXAMPLE-ACCOUNT
sso_role_name = ExampleRole

[sso-session other-session]
sso_start_url = https://other.example.invalid/start
sso_region = us-east-1
EOF
  export AWS_PROFILE=work
  # Login 1h08m ago with a 2h session: 52m left.
  session work example-session $((NOW - 4080))
  PROMPT="$BATS_TEST_TMPDIR/prompt.md"
  printf 'Review this.\n' > "$PROMPT"
}

teardown() {
  [[ ! -e "$BATS_TEST_TMPDIR/network-tool-called" ]]
}

# session PROFILE SSO_SESSION LOGIN_EPOCH: a refreshable token plus a login stamp.
session() {
  local key
  key="$(sha1 "$2")"
  jq -n --arg e "$(iso $((NOW + 3000)))" '
    {startUrl: "https://example.invalid/start", region: "us-east-1",
     accessToken: "fixture-access", expiresAt: $e, clientId: "fixture-client",
     clientSecret: "fixture-secret", registrationExpiresAt: "2026-12-14T00:00:00Z",
     refreshToken: "fixture-refresh"}' > "$HOME/.aws/sso/cache/$key.json"
  mkdir -p "$HOME/.local/state/aws-sso"
  iso "$3" > "$HOME/.local/state/aws-sso/$key.login"
}

git_worktree() {
  local d="$BATS_TEST_TMPDIR/repo"
  git init -q "$d"
  git -C "$d" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$d"
}

@test "codex --bedrock: a budget above the time left is refused before codex starts" {
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 3h
  [ "$status" -eq 5 ]
  [[ "$output" == "codex-run: refused by the AWS SSO preflight (--budget 3h, aws-sso-ttl exit 10): refused: job needs 3h00m, AWS SSO session has ~52m left"* ]]
  [[ "$output" == *"run aws-sso-ensure" ]]
  [ ! -e "$CALLS/codex.args" ]
}

@test "codex --bedrock: the default 2h budget is refused with 52m left" {
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock
  [ "$status" -eq 5 ]
  [[ "$output" == *"--budget 2h"*"job needs 2h00m"* ]]
  [ ! -e "$CALLS/codex.args" ]
}

@test "codex --bedrock: a budget that fits runs the built-in amazon-bedrock provider without a bearer" {
  export AWS_BEARER_TOKEN_BEDROCK=bedrock-api-key-fixture
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m --effort high
  [ "$status" -eq 0 ]
  [[ "$output" == *"review text"* ]]
  [ "$(cat "$CALLS/codex.bearer")" = "<unset>" ]
  grep -qxF 'model_provider="amazon-bedrock"' "$CALLS/codex.args"
  grep -qxF 'model_providers.amazon-bedrock.aws.region="us-east-1"' "$CALLS/codex.args"
  grep -qxF 'openai.gpt-6-sol' "$CALLS/codex.args"
  grep -qxF 'read-only' "$CALLS/codex.args"
  ! grep -q 'bedrock_mantle\|env_key\|base_url' "$CALLS/codex.args"
}

@test "codex --bedrock: AWS_REGION picks the provider region" {
  AWS_REGION=us-west-2 run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 0 ]
  grep -qxF 'model_providers.amazon-bedrock.aws.region="us-west-2"' "$CALLS/codex.args"
}

@test "codex --bedrock --resume is gated and re-passes the provider" {
  run "$SCRIPTS/codex-run.sh" --resume --session 00000000-0000-0000-0000-000000000001 \
    --prompt "$PROMPT" --bedrock --budget 3h
  [ "$status" -eq 5 ]
  [ ! -e "$CALLS/codex.args" ]
  run "$SCRIPTS/codex-run.sh" --resume --session 00000000-0000-0000-0000-000000000001 \
    --prompt "$PROMPT" --bedrock --budget 45m
  [ "$status" -eq 0 ]
  grep -qxF 'model_provider="amazon-bedrock"' "$CALLS/codex.args"
  grep -qxF 'resume' "$CALLS/codex.args"
}

@test "codex --bedrock: a bearer in CODEX_HOME/.env is refused" {
  printf 'OTHER=1\nexport AWS_BEARER_TOKEN_BEDROCK="bedrock-api-key-fixture"\n' > "$HOME/.codex/.env"
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 5 ]
  [[ "$output" == *".codex/.env sets AWS_BEARER_TOKEN_BEDROCK"* ]]
  [[ "$output" != *"bedrock-api-key-fixture"* ]]
  [ ! -e "$CALLS/codex.args" ]
}

@test "codex --bedrock: an empty AWS_BEARER_TOKEN_BEDROCK= line in CODEX_HOME/.env is allowed" {
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex-home"
  mkdir -p "$CODEX_HOME"
  printf 'AWS_BEARER_TOKEN_BEDROCK=\n' > "$CODEX_HOME/.env"
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 0 ]
}

@test "codex --bedrock: Codex-managed Bedrock credentials in auth.json are refused" {
  printf '{"auth_mode": "bedrock", "bedrock_api_key": {"key": "fixture"}}\n' > "$HOME/.codex/auth.json"
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 5 ]
  [[ "$output" == *"auth.json holds Codex-managed Bedrock credentials"* ]]
  printf '{"auth_mode": "chatgpt", "tokens": {}}\n' > "$HOME/.codex/auth.json"
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 0 ]
}

@test "codex --bedrock: an expired session is refused" {
  session work example-session $((NOW - 30000))
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 5 ]
  [[ "$output" == *"aws-sso-ttl exit 11): expired:"* ]]
}

@test "codex --bedrock: a profile with no SSO settings is refused, not waved through" {
  printf '\n[profile static]\nregion = us-east-1\n' >> "$HOME/.aws/config"
  AWS_PROFILE=static run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 5 ]
  [[ "$output" == *"aws-sso-ttl exit 12"*"no SSO settings"* ]]
}

@test "codex --bedrock: no aws-sso-ttl on PATH is refused" {
  rm "$BIN/aws-sso-ttl"
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget 30m
  [ "$status" -eq 5 ]
  [[ "$output" == *"aws-sso-ttl is not on PATH"* ]]
}

@test "codex without --bedrock is not gated and uses the subscription" {
  session work example-session $((NOW - 30000))
  export AWS_BEARER_TOKEN_BEDROCK=bedrock-api-key-fixture
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT"
  [ "$status" -eq 0 ]
  ! grep -q 'amazon-bedrock' "$CALLS/codex.args"
}

@test "codex: --budget needs --bedrock, and must be a duration" {
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --budget 1h
  [ "$status" -eq 2 ]
  [[ "$output" == *"--budget requires --bedrock"* ]]
  run "$SCRIPTS/codex-run.sh" --prompt "$PROMPT" --bedrock --budget soon
  [ "$status" -eq 2 ]
  [[ "$output" == *"--budget must be a duration"* ]]
}

@test "claude --bedrock: a budget above the time left is refused before claude starts" {
  run "$SCRIPTS/claude-run.sh" --prompt "$PROMPT" --dir "$BATS_TEST_TMPDIR" \
    --bedrock --model us.anthropic.claude-opus-5 --budget 3h
  [ "$status" -eq 5 ]
  [[ "$output" == "claude-run: refused by the AWS SSO preflight (--budget 3h, aws-sso-ttl exit 10): refused: job needs 3h00m, AWS SSO session has ~52m left"* ]]
  [ ! -e "$CALLS/claude.args" ]
}

@test "claude --bedrock: a budget that fits runs on the SDK chain without a bearer" {
  export AWS_BEARER_TOKEN_BEDROCK=bedrock-api-key-fixture
  run "$SCRIPTS/claude-run.sh" --prompt "$PROMPT" --dir "$BATS_TEST_TMPDIR" \
    --bedrock --model us.anthropic.claude-opus-5 --budget 30m
  [ "$status" -eq 0 ]
  [[ "$output" == *"review text"* ]]
  [ "$(cat "$CALLS/claude.env")" = "<unset>|1" ]
}

@test "claude without --bedrock is not gated" {
  session work example-session $((NOW - 30000))
  run "$SCRIPTS/claude-run.sh" --prompt "$PROMPT" --dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS/claude.env")" = "<unset>|<unset>" ]
  run "$SCRIPTS/claude-run.sh" --prompt "$PROMPT" --dir "$BATS_TEST_TMPDIR" --budget 1h
  [ "$status" -eq 2 ]
}

@test "hermes on a bedrock profile: a budget above the time left is refused" {
  local repo
  repo="$(git_worktree)"
  run "$SCRIPTS/hermes-run.sh" --profile review-x --prompt "$PROMPT" --dir "$repo" --budget 3h
  [ "$status" -eq 5 ]
  [[ "$output" == "hermes-run: refused by the AWS SSO preflight (--budget 3h, aws-sso-ttl exit 10): refused: job needs 3h00m"* ]]
  [ ! -e "$CALLS/hermes.args" ]
  run "$SCRIPTS/hermes-run.sh" --profile review-x --prompt "$PROMPT" --dir "$repo" --budget 30m
  [ "$status" -eq 0 ]
  [ -e "$CALLS/hermes.args" ]
}

@test "hermes: the profile's .env AWS_PROFILE is the one checked" {
  local repo
  repo="$(git_worktree)"
  session other other-session $((NOW - 600))
  mkdir -p "$HOME/.hermes/profiles/review-x"
  printf 'AWS_PROFILE=other\n' > "$HOME/.hermes/profiles/review-x/.env"
  run "$SCRIPTS/hermes-run.sh" --profile review-x --prompt "$PROMPT" --dir "$repo" --budget 90m
  [ "$status" -eq 0 ]
  printf 'AWS_PROFILE=work\n' > "$HOME/.hermes/profiles/review-x/.env"
  AWS_PROFILE=other run "$SCRIPTS/hermes-run.sh" --profile review-x --prompt "$PROMPT" --dir "$repo" --budget 90m
  [ "$status" -eq 5 ]
}

@test "hermes on a non-bedrock profile is not gated" {
  local repo
  repo="$(git_worktree)"
  session work example-session $((NOW - 30000))
  FAKE_HERMES_PROVIDER=openrouter run "$SCRIPTS/hermes-run.sh" --profile review-x \
    --prompt "$PROMPT" --dir "$repo" --budget 3h
  [ "$status" -eq 0 ]
}
