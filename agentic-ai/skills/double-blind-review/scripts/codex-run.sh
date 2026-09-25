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
#   - --bedrock routes through Amazon Bedrock Mantle with a short-lived bearer
#     token minted from the caller's AWS credentials; config.toml is untouched.
# It does not background itself: the harness must, because a foreground cap that
# kills a long run silently loses codex's final report.
# Vendored from the codex-review plugin (0.4.0); prefer re-vendoring over
# hand-editing if an installed copy diverges.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  codex-run.sh --prompt <file> [--sandbox read-only|workspace-write]
               [--dir <dir>] [--model <name>] [--effort <level>] [--bedrock]
  codex-run.sh --resume [--session <id>] --prompt <file> [--dir <dir>]
               [--model <name>] [--effort <level>] [--bedrock]

  --prompt   File holding the fully-rendered prompt. Required. Write it with the
             harness's file-writing tool; never build it by interpolating
             repo-derived text into a command string.
  --sandbox  Defaults to read-only. Use workspace-write only when the user has
             asked for edits.
  --dir      Run codex from this directory (-C).
  --model    Leave unset unless asked; codex uses its configured model.
             `codex debug models` lists what this machine actually has.
  --effort   Reasoning effort: low, medium, high, xhigh, or max.
  --bedrock  Use Amazon Bedrock Mantle (OpenAI-compatible) instead of the
             subscription. Needs valid AWS credentials (e.g. `aws sso login`)
             and `uv`. Region: $AWS_REGION, default us-east-1. Model defaults to
             openai.gpt-6-sol (Mantle ids have no `us.` prefix).
  --resume   Continue a session. Pass the same --model, --effort, and --bedrock
             as the initial run: codex does not restore them on resume.
  --session  Session id from a prior run. Valid only with --resume. Without it,
             --resume keeps the backward-compatible most-recent-session behavior.

Exit status is codex's own. On success the session-id header is copied to stderr;
on failure the actionable tail of stderr is printed.
EOF
}

prompt=""
sandbox="read-only"
dir=""
model=""
effort=""
resume=0
session=""
bedrock=0

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

if ! command -v codex >/dev/null 2>&1; then
  printf '%s\n' "codex-run: codex CLI not found on PATH. Install with 'npm install -g @openai/codex', then 'codex login'." >&2
  exit 127
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT

cmd=(codex exec --skip-git-repo-check)
[[ -n $dir ]] && cmd+=(-C "$dir")

if (( bedrock )); then
  if ! command -v uv >/dev/null 2>&1; then
    printf 'codex-run: --bedrock needs uv on PATH to mint the Bedrock token\n' >&2; exit 127
  fi
  region=${AWS_REGION:-us-east-1}
  if ! AWS_BEARER_TOKEN_BEDROCK=$(uv run --quiet --no-project --with aws-bedrock-token-generator \
      python3 -c 'import sys; from aws_bedrock_token_generator import provide_token; print(provide_token(region=sys.argv[1]))' \
      "$region" 2>"$err"); then
    printf 'codex-run: could not mint a Bedrock token; is the AWS session valid (aws sso login)?\n' >&2
    tail -n 5 "$err" >&2
    exit 1
  fi
  export AWS_BEARER_TOKEN_BEDROCK
  [[ -n $model ]] || model="openai.gpt-6-sol"
  cmd+=(-c 'model_provider="bedrock_mantle"'
        -c 'model_providers.bedrock_mantle.name="Amazon Bedrock Mantle"'
        -c "model_providers.bedrock_mantle.base_url=\"https://bedrock-mantle.$region.api.aws/openai/v1\""
        -c 'model_providers.bedrock_mantle.env_key="AWS_BEARER_TOKEN_BEDROCK"'
        -c 'model_providers.bedrock_mantle.wire_api="responses"')
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
