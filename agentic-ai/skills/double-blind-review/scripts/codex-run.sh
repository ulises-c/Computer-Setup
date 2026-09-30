#!/usr/bin/env bash
# One call around `codex exec`, so these mechanics cannot be got wrong:
#   - stdin is closed on initial runs: codex exec concatenates stdin with the
#     positional prompt, and from a non-TTY harness an open stdin blocks forever.
#   - stderr goes to a temp file, so thinking tokens stay out of context while a
#     failure's tail (and the session-id header) stays recoverable.
#   - the prompt is passed from a file as one argument, so `$(...)` and backticks
#     in repo-derived text are never re-expanded by the shell.
#   - resume re-passes model, effort, and provider: codex exec resume does NOT
#     inherit them (0.154 falls back to config.toml defaults), so a resumed seat
#     would silently switch models without them.
#   - --bedrock uses Codex's built-in amazon-bedrock (Mantle) provider on the
#     AWS SDK credential chain, which refreshes itself; config.toml is
#     untouched. Codex prefers AWS_BEARER_TOKEN_BEDROCK over the chain, so the
#     variable is dropped here, and a bearer set where it cannot be dropped
#     refuses the run: a bearer lives an hour at most and dies mid-review.
#   - --bedrock refuses to start (exit 5) when the AWS SSO session ends before
#     --budget is over (aws-sso-gate.sh).
# It does not background itself: the harness must, because a foreground cap that
# kills a long run silently loses codex's final report.
# Vendored from the codex-review plugin (0.4.0); prefer re-vendoring over
# hand-editing if an installed copy diverges.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  codex-run.sh --prompt <file> [--sandbox read-only|workspace-write]
               [--dir <dir>] [--model <name>] [--effort <level>]
               [--bedrock [--budget <duration>]]
  codex-run.sh --resume [--session <id>] --prompt <file> [--dir <dir>]
               [--model <name>] [--effort <level>] [--bedrock [--budget <duration>]]

  --prompt   File holding the fully-rendered prompt. Required. Write it with the
             harness's file-writing tool; never build it by interpolating
             repo-derived text into a command string.
  --sandbox  Defaults to read-only. Use workspace-write only when the user has
             asked for edits.
  --dir      Run codex from this directory (-C).
  --model    Leave unset unless asked; codex uses its configured model.
             `codex debug models` lists what this machine actually has.
  --effort   Reasoning effort: low, medium, high, xhigh, or max.
  --bedrock  Use Amazon Bedrock Mantle (Codex's built-in amazon-bedrock
             provider) instead of the subscription, on the AWS SDK credential
             chain ($AWS_PROFILE, e.g. after `aws sso login`). Region:
             $AWS_REGION, default us-east-1. Model defaults to openai.gpt-6-sol
             (Mantle ids have no `us.` prefix).
  --budget   How long this run may take, e.g. 90m or 2h (default 2h). With
             --bedrock the run is refused (exit 5) unless aws-sso-ttl says the
             AWS SSO session lasts at least that long.
  --resume   Continue a session. Pass the same --model, --effort, and --bedrock
             as the initial run: codex does not restore them on resume.
  --session  Session id from a prior run. Valid only with --resume. Without it,
             --resume keeps the backward-compatible most-recent-session behavior.

Exit status is codex's own; 5 when the AWS preflight refused the run. On success
the session-id header is copied to stderr; on failure the actionable tail of
stderr is printed.
EOF
}

# shellcheck source=aws-sso-gate.sh
source "$(dirname "${BASH_SOURCE[0]}")/aws-sso-gate.sh"

prompt=""
sandbox="read-only"
dir=""
model=""
effort=""
resume=0
session=""
bedrock=0
budget=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)  prompt=${2:-}; shift 2 ;;
    --sandbox) sandbox=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --model)   model=${2:-}; shift 2 ;;
    --effort)  effort=${2:-}; shift 2 ;;
    --resume)  resume=1; shift ;;
    --session) session=${2:-}; shift 2 ;;
    --bedrock) bedrock=1; shift ;;
    --budget)  budget=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'codex-run: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z $prompt ]]; then
  printf 'codex-run: --prompt is required\n\n' >&2; usage >&2; exit 2
fi
if [[ ! -f $prompt ]]; then
  printf 'codex-run: prompt file not found: %s\n' "$prompt" >&2; exit 2
fi
if [[ ! -s $prompt ]]; then
  printf 'codex-run: prompt file is empty: %s\n' "$prompt" >&2; exit 2
fi
if [[ $sandbox != "read-only" && $sandbox != "workspace-write" ]]; then
  printf 'codex-run: --sandbox must be read-only or workspace-write, got: %s\n' "$sandbox" >&2; exit 2
fi
if [[ -n $effort && ! $effort =~ ^(low|medium|high|xhigh|max)$ ]]; then
  printf 'codex-run: --effort must be low, medium, high, xhigh, or max, got: %s\n' "$effort" >&2; exit 2
fi
if (( ! resume )) && [[ -n $session ]]; then
  printf 'codex-run: --session requires --resume\n' >&2; exit 2
fi
if [[ -n $budget ]] && (( ! bedrock )); then
  printf 'codex-run: --budget requires --bedrock\n' >&2; exit 2
fi
budget=${budget:-$AWS_SSO_GATE_DEFAULT_BUDGET}
if ! aws_sso_budget_valid "$budget"; then
  printf 'codex-run: --budget must be a duration like 90m, 2h, 1h30m, or seconds, got: %s\n' "$budget" >&2; exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  printf '%s\n' "codex-run: codex CLI not found on PATH. Install with 'npm install -g @openai/codex', then 'codex login'." >&2
  exit 127
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT

cmd=(codex exec --skip-git-repo-check)
[[ -n $dir ]] && cmd+=(-C "$dir")

if (( bedrock )); then
  unset AWS_BEARER_TOKEN_BEDROCK
  codex_home=${CODEX_HOME:-$HOME/.codex}
  if aws_sso_env_value "$codex_home/.env" AWS_BEARER_TOKEN_BEDROCK >/dev/null; then
    printf 'codex-run: refused: %s/.env sets AWS_BEARER_TOKEN_BEDROCK, which Codex prefers over the AWS SDK chain and which expires mid-run; remove that line\n' "$codex_home" >&2
    exit "$AWS_SSO_GATE_REFUSED"
  fi
  if [[ -f $codex_home/auth.json ]] &&
    jq -e '(.bedrock_api_key // .bedrock_access_keys) != null' "$codex_home/auth.json" >/dev/null 2>&1; then
    printf 'codex-run: refused: %s/auth.json holds Codex-managed Bedrock credentials, which take priority over the AWS SDK chain; clear them before using --bedrock\n' "$codex_home" >&2
    exit "$AWS_SSO_GATE_REFUSED"
  fi
  aws_sso_gate codex-run "$budget"
  region=${AWS_REGION:-us-east-1}
  [[ -n $model ]] || model="openai.gpt-6-sol"
  cmd+=(-c 'model_provider="amazon-bedrock"'
        -c "model_providers.amazon-bedrock.aws.region=\"$region\"")
fi
[[ -n $model ]] && cmd+=(-m "$model")
[[ -n $effort ]] && cmd+=(-c "model_reasoning_effort=\"$effort\"")

if (( resume )); then
  if [[ -n $session ]]; then
    cmd+=(resume "$session")
  else
    cmd+=(resume --last)
  fi
  if "${cmd[@]}" <"$prompt" 2>"$err"; then
    status=0
  else
    status=$?
  fi
else
  cmd+=(--sandbox "$sandbox" "$(<"$prompt")")
  if "${cmd[@]}" </dev/null 2>"$err"; then
    status=0
  else
    status=$?
  fi
fi

if (( status != 0 )); then
  printf 'codex-run: codex exec failed (exit %s)\n' "$status" >&2
  tail -n 20 "$err" >&2
  exit "$status"
fi

session_header_found=0
while IFS= read -r line; do
  if [[ $line == "session id: "* ]]; then
    printf '%s\n' "$line" >&2
    session_header_found=1
    break
  fi
done <"$err"

if (( ! session_header_found )); then
  printf 'codex-run: warning: no session id header; only bare --resume can continue this run\n' >&2
fi
