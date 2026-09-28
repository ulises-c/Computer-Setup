#!/usr/bin/env bash
# One review seat as an isolated Hermes process, with the same contract as
# codex-run.sh: prompt from a file, stdin closed, stderr kept out of context,
# `session id: <id>` on stderr, resume by explicit id.
#   - a separate process per seat, because delegate_task children share one
#     delegation model and cannot be resumed for round 2.
#   - the seat's profile owns the provider (seats.json passes the model); memory and messaging toolsets
#     are disabled there, so the reviewer inherits nothing from the orchestrator.
#   - Hermes has no read-only sandbox. --dir must be a clean git worktree; the
#     run fails if the reviewer left it dirty.
#   - a profile on the bedrock provider is refused (exit 5) when the AWS SSO
#     session ends before --budget (aws-sso-gate.sh). The profile's .env wins
#     over the shell, so its AWS_PROFILE is the one checked.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  hermes-run.sh --profile <name> --prompt <file> --dir <worktree> [--model <id>] [--effort <level>]
                [--budget <duration>]
  hermes-run.sh --profile <name> --resume --session <id> --prompt <file> --dir <worktree>
                [--model <id>] [--effort <level>] [--budget <duration>]

  --profile  Hermes profile that pins this seat's provider (and default model).
  --model    Model id from seats.json; overrides the profile default. Pass it
             on resume too.
  --prompt   File holding the fully-rendered prompt. Required.
  --dir      Clean git worktree at the pinned head. Required.
  --effort   none, minimal, low, medium, high, xhigh, max, or ultra.
  --budget   How long this run may take, e.g. 90m or 2h (default 2h). When the
             profile's provider is bedrock the run is refused unless
             aws-sso-ttl says the AWS SSO session lasts at least that long.
  --resume   Continue the seat's session; --session is required with it.

Exit status is hermes's own; 3 when the worktree was modified; 4 when the model
refused (safety/content filter), which hermes itself reports as success; 5 when
the AWS preflight refused the run.
EOF
}

# shellcheck source=aws-sso-gate.sh
source "$(dirname "${BASH_SOURCE[0]}")/aws-sso-gate.sh"

profile=""
prompt=""
dir=""
effort=""
model=""
resume=0
session=""
budget=$AWS_SSO_GATE_DEFAULT_BUDGET

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile=${2:-}; shift 2 ;;
    --prompt)  prompt=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --effort)  effort=${2:-}; shift 2 ;;
    --model)   model=${2:-}; shift 2 ;;
    --resume)  resume=1; shift ;;
    --session) session=${2:-}; shift 2 ;;
    --budget)  budget=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'hermes-run: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z $profile || -z $prompt || -z $dir ]]; then
  printf 'hermes-run: --profile, --prompt, and --dir are required\n\n' >&2; usage >&2; exit 2
fi
if [[ ! -s $prompt ]]; then
  printf 'hermes-run: prompt file missing or empty: %s\n' "$prompt" >&2; exit 2
fi
if (( resume )) && [[ -z $session ]]; then
  printf 'hermes-run: --resume requires --session <id>\n' >&2; exit 2
fi
if (( ! resume )) && [[ -n $session ]]; then
  printf 'hermes-run: --session requires --resume\n' >&2; exit 2
fi
if ! aws_sso_budget_valid "$budget"; then
  printf 'hermes-run: --budget must be a duration like 90m, 2h, 1h30m, or seconds, got: %s\n' "$budget" >&2; exit 2
fi
if ! command -v hermes >/dev/null 2>&1; then
  printf 'hermes-run: hermes not found on PATH\n' >&2; exit 127
fi

provider=$(hermes -p "$profile" config get model.provider 2>/dev/null) || provider=""
if [[ $provider == bedrock ]]; then
  unset AWS_BEARER_TOKEN_BEDROCK
  profile_env="$HOME/.hermes/profiles/$profile/.env"
  aws_profile=$(aws_sso_env_value "$profile_env" AWS_PROFILE) || aws_profile=""
  aws_sso_gate hermes-run "$budget" "$aws_profile"
fi

dir=$(cd "$dir" && pwd)
prompt=$(cd "$(dirname "$prompt")" && pwd)/$(basename "$prompt")
if [[ -n $(git -C "$dir" status --porcelain) ]]; then
  printf 'hermes-run: worktree is not clean before the run: %s\n' "$dir" >&2; exit 2
fi

# Refusals exit 0 with a canned reply; the profile's agent.log is the only
# structured record. Profiles live under ~/.hermes/profiles regardless of HERMES_HOME.
log="$HOME/.hermes/profiles/$profile/logs/agent.log"
log_start=0
[[ -f $log ]] && log_start=$(wc -l <"$log")

out=$(mktemp)
err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT

cmd=(hermes -p "$profile" chat -Q --query-file "$prompt" --in "$dir" -t "terminal,file")
[[ -n $model ]] && cmd+=(-m "$model")
[[ -n $effort ]] && cmd+=(--reasoning "$effort")
(( resume )) && cmd+=(--resume "$session")

if "${cmd[@]}" </dev/null >"$out" 2>"$err"; then
  status=0
else
  status=$?
fi

cat "$out"
sid=""
while IFS= read -r line; do
  line=${line%$'\r'}
  [[ $line == "session_id: "* ]] && sid=${line#session_id: }
done < <(cat "$out" "$err")

if (( status != 0 )); then
  printf 'hermes-run: hermes chat failed (exit %s)\n' "$status" >&2
  tail -n 20 "$err" >&2
  exit "$status"
fi
[[ -n $sid ]] && printf 'session id: %s\n' "$sid" >&2

if [[ -n $sid && -f $log ]] &&
  tail -n +"$((log_start + 1))" "$log" | grep -F "[$sid]" | grep -qF 'Model declined to respond'; then
  printf 'hermes-run: model refused (content filter); treat this seat as failed\n' >&2
  exit 4
fi

if [[ -n $(git -C "$dir" status --porcelain) ]]; then
  printf 'hermes-run: reviewer modified the worktree; treat this seat as failed\n' >&2
  git -C "$dir" status --short >&2
  exit 3
fi
