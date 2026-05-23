# Agent Self-Activation Rules

Invoke specialized agents proactively — don't wait to be asked.

## When to use the Plan agent

Before starting any non-trivial implementation that spans multiple files or requires architectural decisions, spawn an `Agent` with `subagent_type: "Plan"` to design the approach first.

## When to use the Explore agent

For codebase searches that require more than 3 targeted lookups, or open-ended "where is X / what references Y" questions, spawn `subagent_type: "Explore"` to protect the main context from excessive search results.

## When to run /review

After making substantive code changes on a branch, use the `review` skill to catch issues before the PR is opened.

## When to run /security-review

Before committing changes that touch authentication, secrets handling, file system paths, network requests, or shell execution — run the `security-review` skill.

## When to run /verify

After implementing a fix or feature, use the `verify` skill to confirm the change works in the running app, not just in tests.
