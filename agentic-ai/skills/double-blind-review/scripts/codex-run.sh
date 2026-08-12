#!/usr/bin/env bash
# One call around `codex exec`, so the mechanics that used to be prose gotchas
# cannot be got wrong:
#
#   - stdin is closed on initial runs. codex exec concatenates stdin with the
#     positional prompt, and from a non-TTY harness an unclosed stdin blocks
#     forever (symptom: zero stdout, zero CPU).
#   - stderr goes to a temp file, never /dev/null, so thinking tokens stay out
#     of context while a failure's text stays recoverable. Its tail is printed
#     only when the run actually fails.
#   - the prompt is read from a file and passed as a single argument, so `$(...)`
#     and backticks inside prompt text (branch names, diff content, user focus
#     text) can never be re-expanded by the shell.
#   - resume takes the prompt on stdin, adds no </dev/null, and re-passes no
#     model/effort/sandbox flags, because a resumed session inherits them.
#
# This script does NOT background itself. Every real codex run must still be
# launched as a background Bash task (run_in_background: true): the harness
# hard-caps foreground Bash at 10 minutes and a mid-run SIGTERM silently loses
# codex's final report. That is a property of the tool call, not of the command,
# so it cannot be wrapped away.
#
# Vendored from the codex-review plugin (0.4.0) so this skill stands alone —
# upstream itself duplicates this file per-plugin for the same reason. If an
# installed codex-review copy diverges from this one, prefer re-vendoring over
# hand-editing.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  codex-run.sh --prompt <file> [--sandbox read-only|workspace-write]
               [--dir <dir>] [--model <name>] [--effort <low|medium|high|xhigh>]
  codex-run.sh --resume --prompt <file> [--dir <dir>]

  --prompt   File holding the fully-rendered prompt. Required. Write it with the
             Write tool; never build it by interpolating repo-derived text into
             a command string.
  --sandbox  Defaults to read-only. Use workspace-write only when the user has
             asked for edits.
  --dir      Run codex from this directory (-C).
  --model    Leave unset unless asked; codex uses its configured model.
             `codex debug models` lists what this machine actually has.
  --effort   Reasoning effort. Leave unset unless a hard pass warrants it.
  --resume   Continue the last session. Inherits its model, effort, and sandbox,
             so those flags are rejected here rather than silently ignored.

Exit status is codex's own. On failure the actionable tail of stderr is printed.
EOF
}

prompt=""
sandbox="read-only"
dir=""
model=""
effort=""
resume=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)  prompt=${2:-}; shift 2 ;;
    --sandbox) sandbox=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --model)   model=${2:-}; shift 2 ;;
    --effort)  effort=${2:-}; shift 2 ;;
    --resume)  resume=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'codex-run: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z $prompt ]]; then
  printf 'codex-run: --prompt is required\n\n' >&2; usage >&2; exit 2
fi
if [[ ! -f $prompt ]]; then
  echo "codex-run: prompt file not found: $prompt" >&2; exit 2
fi
if [[ ! -s $prompt ]]; then
  echo "codex-run: prompt file is empty: $prompt" >&2; exit 2
fi
if [[ $sandbox != "read-only" && $sandbox != "workspace-write" ]]; then
  echo "codex-run: --sandbox must be read-only or workspace-write, got: $sandbox" >&2; exit 2
fi
if (( resume )) && [[ -n $model || -n $effort ]]; then
  echo "codex-run: --resume inherits model and effort; drop --model/--effort" >&2; exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex-run: codex CLI not found on PATH. Install with 'npm install -g @openai/codex', then 'codex login'." >&2
  exit 127
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT

cmd=(codex exec --skip-git-repo-check)
[[ -n $dir ]] && cmd+=(-C "$dir")

if (( resume )); then
  # The pipe IS stdin here, so no </dev/null, and no flags are re-passed.
  cmd+=(resume --last)
  "${cmd[@]}" <"$prompt" 2>"$err"
  status=$?
else
  [[ -n $model ]] && cmd+=(-m "$model")
  [[ -n $effort ]] && cmd+=(--config "model_reasoning_effort=$effort")
  cmd+=(--sandbox "$sandbox" "$(cat "$prompt")")
  "${cmd[@]}" </dev/null 2>"$err"
  status=$?
fi

if (( status != 0 )); then
  echo "codex-run: codex exec failed (exit $status)" >&2
  tail -n 20 "$err" >&2
  exit "$status"
fi
