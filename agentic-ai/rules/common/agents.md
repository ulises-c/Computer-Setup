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

## When to hand text to the Hermes editor profile

Before you post text that other people read, send the draft to the Hermes `editor` profile. This covers PR titles and descriptions, PR and review comments, Slack messages, Jira and Confluence text, emails, and release notes. Commit messages are excluded.

```bash
hermes -p editor chat -Q -q "Edit this <kind> for <audience>. Keep every fact. Return only the edited text. Source: <diff/ticket/path>. Draft: <draft>"
```

- Give editor the evidence (diff, log, ticket, file path) as well as the draft, so it can check the claims.
- Use the edited text. If you reject an edit, tell the user why.
- The user's approval rules for posting do not change. Editor drafts. It does not approve.
- If you are the editor profile (`$HERMES_HOME` ends in `/profiles/editor`), skip this step.
- If `hermes` is not installed or the call fails, post your own draft and say that editor did not run.
