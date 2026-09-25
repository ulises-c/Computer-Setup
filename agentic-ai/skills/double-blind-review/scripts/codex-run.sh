#!/usr/bin/env bash
# One call around `codex exec`, so these mechanics cannot be got wrong:
#   - stdin is closed on initial runs: codex exec concatenates stdin with the
#     positional prompt, and from a non-TTY harness an open stdin blocks forever.
#   - stderr goes to a temp file, so thinking tokens stay out of context while a
#     failure's tail (and the session-id header) stays recoverable.
#   - the prompt is passed from a file as one argument, so `$(...)` and backticks
#     in repo-derived text are never re-expanded by the shell.
#   - resume re-passes no model/effort/sandbox flags; the session inherits them.
# It does not background itself: the harness must, because a foreground cap that
# kills a long run silently loses codex's final report.
# Vendored from the codex-review plugin (0.4.0); prefer re-vendoring over
# hand-editing if an installed copy diverges.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  codex-run.sh --prompt <file> [--sandbox read-only|workspace-write]
               [--dir <dir>] [--model <name>] [--effort <low|medium|high|xhigh>]
  codex-run.sh --resume [--session <id>] --prompt <file> [--dir <dir>]

  --prompt   File holding the fully-rendered prompt. Required. Write it with the
             harness's file-writing tool; never build it by interpolating
             repo-derived text into a command string.
  --sandbox  Defaults to read-only. Use workspace-write only when the user has
             asked for edits.
  --dir      Run codex from this directory (-C).
  --model    Leave unset unless asked; codex uses its configured model.
             `codex debug models` lists what this machine actually has.
  --effort   Reasoning effort. Leave unset unless a hard pass warrants it.
  --resume   Continue a session. Inherits its model, effort, and sandbox, so
             those flags are rejected here rather than silently ignored.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)  prompt=${2:-}; shift 2 ;;
    --sandbox) sandbox=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --model)   model=${2:-}; shift 2 ;;
    --effort)  effort=${2:-}; shift 2 ;;
    --resume)  resume=1; shift ;;
    --session) session=${2:-}; shift 2 ;;
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
if (( resume )) && [[ -n $model || -n $effort ]]; then
  printf 'codex-run: --resume inherits model and effort; drop --model/--effort\n' >&2; exit 2
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
  [[ -n $model ]] && cmd+=(-m "$model")
  [[ -n $effort ]] && cmd+=(--config "model_reasoning_effort=$effort")
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
