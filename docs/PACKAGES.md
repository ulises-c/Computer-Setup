# packages.json — schema & selection reference

`packages.json` is the single source of truth for all package data across every
platform. This is the deep reference; `AGENTS.md` carries the one-paragraph summary.
Read this before editing `packages.json` or the selection logic in `lib/core.sh`.
The design history is in [UNIFICATION.md](UNIFICATION.md).

## Per-entry fields

- **`name`** — canonical name and default install token.
- **`package_manager`** — object keyed by platform (`{macos, ubuntu, arch, server}`);
  omit platforms the package doesn't target. `custom` selects the install-command path.
- **`<platform>_name`** — optional per-platform install-token override; the engine
  reads `.<platform>_name // .name` (e.g. `huggingface-hub` → arch
  `python-huggingface-hub`).
- **`priority`** — `high | medium | low | none`.
- **`optional`** — boolean; `low`/`none` + optional installs only with `--optional`.
- **`environment`** — gates on `--work` / `--personal`; absent ⇒ always installs.
- **`install_command`** — `custom` managers only; string or per-platform object.
- **`handled_by_setup`** — `custom` entries: `true` auto-runs the command, otherwise
  it's printed as a manual-install reminder.
- **`tags`** — required non-empty array of categories from the controlled vocabulary
  in `scripts/validate-packages.sh`. Metadata only (grouping/docs/`--tags` filter);
  the install engine ignores them for resolution.
- **`description`**.

## Scalar or per-platform object

`priority`, `optional`, `environment`, and `install_command` each accept a **scalar**
(applies to every platform) **or a per-platform object** keyed by platform, e.g.:

```jsonc
"priority": { "macos": "medium", "ubuntu": "none" }
```

The engine resolves them via the `prfor` / `optfor` / `envfor` / `icfor` jq defs in
`lib/core.sh`. This is what lets one entry serve platforms that differ in
tier/optionality/gating instead of splitting into duplicate entries.

**`environment` caveat:** its scalar form is itself an *array* (`["work"]`), so the
per-platform form is detected as an *object* (`{ "ubuntu": ["work"] }`) — array means
legacy/all-platforms, object means per-platform. Keep the per-platform value an
object-of-arrays.

## Category selection (`--base` / `--tags`)

- `--base` installs only the high-priority base set (no category packages).
- `--tags development,terminal` installs base + those tag categories. Enabled
  work/personal apps install regardless of category.
- Bare run on a TTY with no selection flag → `core_maybe_prompt_selection` prompts
  interactively; skipped on the server profile and in non-interactive/CI runs.
- The filter is implemented by `tagok()` in `CORE_JQ_DEFS`, which reads
  `TAG_FILTER_ACTIVE` and `SELECTED_TAGS` from the environment — **inactive by
  default**, so flag-driven and CI runs are unchanged.
- The dedicated custom-install steps (tailscale, claude-code, docker) gate on
  `pkg_selected` so they honor the selection too. The server profile keeps the filter
  inactive, so they install as before there.

## Validation & reminder semantics

- `scripts/validate-packages.sh` (pre-commit + CI) enforces the schema: platform
  vocabulary, controlled tag set, `handled_by_setup` is a real boolean, custom
  entries carry an `install_command`, and the **"no silent drop"** rule — every
  platform a package targets must resolve a valid priority tier and a boolean
  optional.
- App-store packages and `priority: "none"` entries are **reminders only** — never
  auto-installed.
