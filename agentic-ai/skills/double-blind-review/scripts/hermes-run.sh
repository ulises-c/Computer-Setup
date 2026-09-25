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
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  hermes-run.sh --profile <name> --prompt <file> --dir <worktree> [--model <id>] [--effort <level>]
  hermes-run.sh --profile <name> --resume --session <id> --prompt <file> --dir <worktree>
                [--model <id>] [--effort <level>]

  --profile  Hermes profile that pins this seat's provider (and default model).
  --model    Model id from seats.json; overrides the profile default. Pass it
             on resume too.
  --prompt   File holding the fully-rendered prompt. Required.
  --dir      Clean git worktree at the pinned head. Required.
  --effort   none, minimal, low, medium, high, xhigh, max, or ultra.
  --resume   Continue the seat's session; --session is required with it.

Exit status is hermes's own, or 3 when the worktree was modified.
EOF
}

profile=""
prompt=""
dir=""
effort=""
model=""
resume=0
session=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile=${2:-}; shift 2 ;;
    --prompt)  prompt=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --effort)  effort=${2:-}; shift 2 ;;
    --model)   model=${2:-}; shift 2 ;;
    --resume)  resume=1; shift ;;
    --session) session=${2:-}; shift 2 ;;
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
if ! command -v hermes >/dev/null 2>&1; then
  printf 'hermes-run: hermes not found on PATH\n' >&2; exit 127
fi

dir=$(cd "$dir" && pwd)
prompt=$(cd "$(dirname "$prompt")" && pwd)/$(basename "$prompt")
if [[ -n $(git -C "$dir" status --porcelain) ]]; then
  printf 'hermes-run: worktree is not clean before the run: %s\n' "$dir" >&2; exit 2
fi

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

if [[ -n $(git -C "$dir" status --porcelain) ]]; then
  printf 'hermes-run: reviewer modified the worktree; treat this seat as failed\n' >&2
  git -C "$dir" status --short >&2
  exit 3
fi
