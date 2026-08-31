# Round 1 — independent review prompts

Both reviewers get the **same** scope, domain context, and output contract. Fill the
placeholders identically for each. Asymmetric prompts destroy the signal that
convergence is supposed to carry.

Shared placeholders:

- `{{SCOPE}}` — e.g. ``the branch diff `git diff main...HEAD` on `fix/foo` ``
- `{{DOMAIN}}` — what the codebase is and what it must guarantee
- `{{PRIORITY}}` — the failure class that matters most here (see note below)

**Set `{{PRIORITY}}` from the domain.** For security-enforcement code it is bypasses:
*ways a governed agent could evade the checks this change introduces or modifies.* For a
migration it is data loss and rollback. For a service it is partial failure and version
skew. A generic "find bugs" wastes the round.

---

## Codex side

Write to a file, pass to `scripts/codex-run.sh` with `--prompt`. Never interpolate
branch names or user text into the command string.

```xml
<task>
Review {{SCOPE}} in this repository for material correctness and regression risks, and
assess whether it is ready to ship as a PR. Focus on the provided repository context
only. Read the diff with your own git tools; read surrounding code as needed to verify
claims.

Context: {{DOMAIN}}. Pay particular attention to {{PRIORITY}}.
</task>

<structured_output_contract>
Return:
1. a one-line ship / needs-attention verdict
2. findings ordered by severity (critical, high, medium, low), each with: what can go
   wrong, the file and line range, supporting evidence, and a concrete recommendation
3. brief next steps
Omit style, naming, and low-value cleanup. Prefer one strong finding over several weak ones.
</structured_output_contract>

<grounding_rules>
Ground every claim in the repository context or your tool outputs.
If a point is an inference, label it clearly. Do not invent files, lines, or behavior.
</grounding_rules>

<dig_deeper_nudge>
After the first plausible issue, check second-order failures, empty-state handling,
retries, stale state, and rollback paths before finalizing. For each check the change
adds or modifies, actively look for an input that slips past it.
</dig_deeper_nudge>
```

## Claude side

Same contract, plus the things a subagent needs told explicitly:

```
You are performing an independent code review. Do NOT modify any files — read-only.

Repository: {{REPO_PATH}}. {{DOMAIN}}.

Review target: {{SCOPE}}. {{ONE_PARAGRAPH_SUMMARY_OF_THE_CHANGE}}

Your job: assess whether this branch is ready to ship as a PR.

Method:
- Run `git log --oneline main..HEAD` and `git diff main...HEAD` (read it fully; use
  `git diff main...HEAD -- <file>` per file for large files).
- Read surrounding code beyond the diff hunks wherever needed to verify a claim — do not
  report a finding you have not grounded in the actual code.
- Prioritize {{PRIORITY}}. Also check second-order failures, empty-state handling,
  retries, stale state, and rollback paths.
- Verify the branch builds and tests pass if that completes in reasonable time; if you
  skip it, say so.

Return in your final message (raw data for the orchestrator, not a user-facing message):
1. A one-line verdict: ship / needs-attention.
2. Findings ordered by severity. For each: what can go wrong, file and line range,
   supporting evidence, concrete recommendation. Label inferences as inferences. Omit
   style/naming/low-value cleanup. Prefer one strong finding over several weak ones.
3. Brief next steps.
```

Adding "reproduce findings against the real binary in an isolated temp dir where cheap"
measurably raises quality on both sides — it is what separates a confirmed bypass from a
plausible one. Include it whenever the tool under review can actually be run.
