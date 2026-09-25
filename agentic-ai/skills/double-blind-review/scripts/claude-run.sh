#!/usr/bin/env bash
# One review seat on the Claude Code CLI, with the same contract as
# codex-run.sh: prompt from a file, stdin closed, stderr kept out of context,
# `session id: <id>` on stderr, resume by explicit id.
#   - plan mode plus an allowlist of read-only tools: the reviewer can read and
#     run git inspection commands but cannot edit.
#   - the prompt goes first; --allowedTools is variadic and would swallow it.
#   - --bedrock sets CLAUDE_CODE_USE_BEDROCK so the run bills to AWS instead of
#     the subscription. Bedrock model ids need an inference-profile prefix (us.).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  claude-run.sh --prompt <file> --dir <dir> [--model <name>] [--effort <level>] [--bedrock]
  claude-run.sh --resume --session <uuid> --prompt <file> --dir <dir>
                [--model <name>] [--effort <level>] [--bedrock]

  --prompt   File holding the fully-rendered prompt. Required.
  --dir      Repository to review (the run's working directory). Required.
  --model    Leave unset for the subscription default. Required with --bedrock.
  --effort   low, medium, high, xhigh, or max.
  --bedrock  Bill through Amazon Bedrock with the caller's AWS credentials.
  --resume   Continue the session given by --session.

Exit status is claude's own; 4 when the model refused.
EOF
}

prompt=""
dir=""
model=""
effort=""
resume=0
session=""
bedrock=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)  prompt=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --model)   model=${2:-}; shift 2 ;;
    --effort)  effort=${2:-}; shift 2 ;;
    --resume)  resume=1; shift ;;
    --session) session=${2:-}; shift 2 ;;
    --bedrock) bedrock=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'claude-run: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z $prompt || -z $dir ]]; then
  printf 'claude-run: --prompt and --dir are required\n\n' >&2; usage >&2; exit 2
fi
if [[ ! -s $prompt ]]; then
  printf 'claude-run: prompt file missing or empty: %s\n' "$prompt" >&2; exit 2
fi
if (( resume )) && [[ -z $session ]]; then
  printf 'claude-run: --resume requires --session <uuid>\n' >&2; exit 2
fi
if (( ! resume )) && [[ -n $session ]]; then
  printf 'claude-run: --session requires --resume\n' >&2; exit 2
fi
if (( bedrock )) && [[ -z $model ]]; then
  printf 'claude-run: --bedrock requires --model (e.g. us.anthropic.claude-opus-5)\n' >&2; exit 2
fi
if [[ -n $effort && ! $effort =~ ^(low|medium|high|xhigh|max)$ ]]; then
  printf 'claude-run: --effort must be low, medium, high, xhigh, or max, got: %s\n' "$effort" >&2; exit 2
fi
if ! command -v claude >/dev/null 2>&1; then
  printf 'claude-run: claude CLI not found on PATH\n' >&2; exit 127
fi

(( resume )) || session=$(</proc/sys/kernel/random/uuid)

err=$(mktemp)
out=$(mktemp)
trap 'rm -f "$err" "$out"' EXIT

cmd=(claude -p "$(<"$prompt")" --output-format json)
if (( resume )); then
  cmd+=(--resume "$session")
else
  cmd+=(--session-id "$session")
fi
[[ -n $model ]] && cmd+=(--model "$model")
[[ -n $effort ]] && cmd+=(--effort "$effort")
cmd+=(--permission-mode plan --permission-prompts none
      --tools "Read,Glob,Grep,Bash"
      --allowedTools Read Glob Grep "Bash(git diff *)" "Bash(git log *)"
      "Bash(git show *)" "Bash(git status *)" "Bash(git rev-parse *)")

if (( bedrock )); then
  export CLAUDE_CODE_USE_BEDROCK=1
  export AWS_REGION=${AWS_REGION:-us-east-1}
fi

if (cd "$dir" && "${cmd[@]}") </dev/null >"$out" 2>"$err"; then
  status=0
else
  status=$?
fi

if (( status != 0 )); then
  printf 'claude-run: claude failed (exit %s)\n' "$status" >&2
  tail -n 20 "$err" >&2
  exit "$status"
fi
# JSON output carries stop_reason, so a refusal is not mistaken for a review.
if ! jq -e 'type == "object" and has("result")' "$out" >/dev/null 2>&1; then
  printf 'claude-run: unexpected output (not a JSON result)\n' >&2
  head -c 2000 "$out" >&2
  exit 1
fi
jq -r '.result' "$out"
printf 'session id: %s\n' "$session" >&2
if [[ $(jq -r '.stop_reason // ""' "$out") == refusal ]]; then
  printf 'claude-run: model refused; treat this seat as failed\n' >&2
  exit 4
fi
if [[ $(jq -r '.is_error // false' "$out") == true ]]; then
  printf 'claude-run: claude reported an error result\n' >&2
  exit 1
fi
