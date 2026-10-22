# Private privacy inventory and audit

`scripts/privacy-audit.py` discovers identifiers on explicitly selected machines,
maintains a private historical denylist, and checks Git history and selected GitHub
surfaces locally. It never sends identifiers as search queries and never executes
code from the repository being audited.

## Runtime and trust boundary

Use Python 3.9+ on macOS or Linux, Git, and (for configured GitHub surfaces) an
authenticated `gh`. Remote collectors require `python3` plus Linux `ip` or macOS
`/sbin/ifconfig`. SSH aliases must already work noninteractively; this tool does not
change SSH configuration, accept host keys, or prompt for credentials.

For scheduled operation, copy **both** `privacy-audit.py` and `check-privacy.py`
into an administrator-controlled private runtime directory outside the public
checkout. The audit imports only that adjacent scanner. Do not schedule scripts
straight from a mutable public checkout or let the audited repository update the
installed runtime automatically. Running the source version is appropriate for
trusted development/tests, not as the installed security boundary.

The configuration, state, denylist, and detailed reports are private. Keep them
outside published or synchronized document trees. Config and state paths must be
absolute and have no symlink components. Config permissions must be `600` or
stricter. The state directory is forced to `700`; generated files and the rendered
repo denylist are `600`. The state directory must be outside `repo_path`. A
nonblocking `flock` serializes all commands against the same state directory.
Writes use private temporary files, fsync, and atomic replacement; symlink targets
are refused. Do not share ownership of the private runtime/config/state tree with
untrusted users.

## Configuration schema

Create a private JSON file, replacing these nonfunctional example paths/aliases:

```json
{
  "repo_path": "/absolute/path/to/public-checkout",
  "state_dir": "/absolute/private/privacy-state",
  "denylist_path": "/absolute/private/manual-denylist",
  "hosts": [
    {"name": "local", "local": true},
    {"name": "server", "ssh": "server-alias"},
    {"name": "game", "ssh": "game-alias"},
    {"name": "pi", "ssh": "pi-alias"}
  ],
  "tailnet_host": "local",
  "github_repo": "example/project",
  "mirror_url": "https://github.com/example/project.git",
  "sync_secret": false
}
```

- `repo_path`, `state_dir`, `denylist_path`, and `hosts` are required. `hosts: []`
  deliberately disables host discovery for an offline audit based on manual seed
  values. Host `name` values must be unique source labels; `manual` is reserved.
- Each host uses either `local: true` **or** `ssh: "alias"`. Labels/aliases accept
  letters, digits, underscores, dots, and hyphens, starting with a letter/digit.
  Remote commands are fixed strings, not generated shell fragments. The Python
  collector is sent through SSH stdin; aliases are never interpolated into shell
  source. Local and remote collectors use `python3 -I -`, working directory `/`,
  and an environment without `PYTHONPATH`/`PYTHONHOME`. Interpreter isolation
  prevents an audited checkout's modules from shadowing standard-library imports.
  SSH uses BatchMode, connection/keepalive limits, and a wall-time timeout.
- `tailnet_host` is optional and names one configured host's **name**, not its SSH
  alias. It supplies `tailscale status --json`. A local source tries the bundled
  macOS Tailscale executable if the ordinary command fails.
- `denylist_path` is an explicit seed file, one value per line, with `#` comments.
  It can initially be the checkout's existing ignored `.privacy-denylist`.
  A separate manual file avoids repeatedly reclassifying generated values as
  manual. Historical values are retained even if removed from the seed later.
  A missing/unreadable seed marks `manual` unavailable and refresh degraded;
  retained inventory still renders the denylist and `run` continues into audit.
  Secret synchronization is skipped. An empty inventory still fails closed.
- `github_repo` is optional, an explicit `owner/repository`, with no URL.
- `mirror_url` is optional. Only fixed `https://github.com/owner/repository.git`
  URLs are accepted; credentials, query strings, fragments, redirects, arbitrary
  hosts, and shell transports are not accepted. It need not be configured for a
  useful local audit. Set it explicitly to audit current advertised public refs
  independently of the user's checkout.
- `sync_secret` defaults to `false`. With explicit `true` and `github_repo`, a
  successful, nondegraded refresh validates the rendered denylist through the
  trusted scanner, sends it to `gh secret set PRIVACY_DENYLIST` **via stdin**, then
  verifies the secret's name/update metadata through the API. GitHub cannot return
  a secret's plaintext for verification. No secret update occurs on discovery
  failure. This is the only optional public-service write; audit itself is read-only.

## Commands and scheduling

Global options precede the command:

```sh
python3 /absolute/private/runtime/privacy-audit.py --config /absolute/private/config.json refresh
python3 /absolute/private/runtime/privacy-audit.py --config /absolute/private/config.json audit
python3 /absolute/private/runtime/privacy-audit.py --config /absolute/private/config.json run
python3 /absolute/private/runtime/privacy-audit.py --config /absolute/private/config.json --full run
python3 /absolute/private/runtime/privacy-audit.py --config /absolute/private/config.json --state-dir /absolute/private/other-state --full audit
```

`refresh` collects and merges inventory, writes private state and the compatible
plain denylist, and optionally syncs the secret. It refuses to write the checkout's
`.privacy-denylist` unless Git confirms that exact target is ignored and untracked.

`audit` uses the already generated private denylist and does not discover hosts or
update the checkout denylist. Run `refresh` first. `run` performs both while holding
one lock. Suggested scheduler arguments are `--config CONFIG run` daily and
`--config CONFIG --full run` monthly, using an always-on machine that can SSH to
all explicit fleet aliases. Invoke the trusted runtime with a native scheduler;
no scheduled jobs are installed by the audit command itself.

### Before-push guard

The scanner's `--pre-push` mode consumes Git's hook stdin and requires a usable
denylist. A repository-local hook may invoke the trusted private scanner through
an absolute interpreter path with `-I`; preserve any existing hook or custom
`core.hooksPath` rather than overwriting it. Do not schedule or install a hook
that silently updates its scanner from unreviewed checkout content.

Existing destination refs scan their outgoing commit range. **A new destination
ref scans its complete reachable history**, not history absent from arbitrary
local remotes: a private backup is not evidence that a commit is already public.
Both reference names and annotated-tag metadata are checked. Consequently,
creating a new public branch or tag can be blocked by old identifiers in commit
metadata or files. That is intentional and requires separate remediation or a
deliberate policy decision; the audit never rewrites history, changes author
identity, deletes public comments, or rotates credentials automatically.

A daily Git audit scans **all previously unscanned reachable commits**, including
newly visible old branch history, not just commits newer than a timestamp. A changed
denylist, changed installed scanner, or changed repo/mirror selection forces a full
rescan. `--full` also reconciles retained findings against current reachable history
and current GitHub content. Incremental reports intentionally retain past findings;
a deleted GitHub comment may remain until that full reconciliation. GitHub surfaces
and ref/tag metadata are revisited on every audit. Checkpoints advance only when
all configured audit surfaces complete without truncation. A missing, degraded,
or truncated previous report forces a full scan, regardless of the retained
checkpoint. If any configured surface is unavailable or findings truncate, the
report is marked degraded and **all previous findings are retained**, including
findings from unavailable full-scan surfaces. New observations fill the remaining
5,000-finding budget after previous findings; omitted observations set
`findings_truncated`. The old checkpoint remains unchanged. Only a subsequent
complete full reconciliation can retire stale findings. A degraded report's zero
count is not a clean result; it means no retained/observed findings under
incomplete coverage. Report replacement precedes checkpoint replacement, so a
failed checkpoint write cannot authorize skipping findings absent from a report.

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Completed; no audit findings (or successful refresh only). |
| `1` | Completed audit with possible privacy findings. |
| `2` | Degraded/incomplete coverage, lock contention, invalid configuration, command failure, or report truncation. Findings may also exist. |

Stdout contains a single sanitized JSON summary with counts, generic categories,
mode, fixed surface labels, and coverage status. Failures emit a generic JSON error
without exception strings or raw child-process diagnostics. Do not treat `1` as a
crash or `2` as a clean audit.

## Inventory and reports

`inventory.json` contains private entries with `type`, `value`, `source` (a list),
`first_seen`, and `last_seen`, plus source status and timestamps. Hostname/FQDN,
login, interface addresses, Tailscale full DNS names and Tailscale IPs are collected.
Tagged Tailscale nodes contribute full DNS names/IPs but not container short names.
Names shorter than four characters and generic names such as `localhost` are not
inserted, matching the scanner's denylist minimum. Addresses are canonicalized,
including IPv4-mapped IPv6; loopback, unspecified, multicast, link-local and
reserved documentation ranges are omitted. Linux interface metadata and macOS
interface names exclude generic bridge/container interfaces. Tailscale identities
come from its status rather than tunnel-interface heuristics. Tailscale `Addrs`
and `CurAddr` additionally contribute public endpoint **candidates**: explicit
`IPv4:port` and `[IPv6]:port` forms are parsed, ports validated, and only globally
routable addresses automatically included. Unknown/malformed, private, CGNAT,
container/LAN and other nonglobal endpoints are skipped; owned LAN addresses are
collected directly from configured hosts instead. Public endpoints may reflect
NAT, shared infrastructure, or transient addresses: this is conservative privacy
matching, **not proof of ownership**. The port is not inventoried.

Unavailable sources are marked `unavailable`, keep earlier last-seen timestamps,
and **never delete historical entries**. Removed source configuration is marked
`not_configured`. There is deliberately no automatic expiry/removal of identifiers;
retired identifiers can still exist in old published content.

Private state files include:

- `inventory.json`: the sensitive inventory, including discovered values.
- `.privacy-denylist`: a compatible private copy used for audits.
- `report.json`: category-only findings with sanitized commit/path or item locators,
  first matching line numbers, and coverage metadata. Matched content is never
  stored. Identifying/control-character/overlong locators are redacted with a
  stable 24-hex-character SHA-256 locator digest; safe commit IDs are preserved.
  Distinct redacted paths do not collapse into one finding. The digest discloses
  neither raw path nor length, but is not encryption: reports remain private and
  guessed paths can be tested against it. Non-UTF-8 Git paths retain byte identity
  before hashing. Findings deduplicate by surface/locator/category; repeated
  identical blobs are read once per Git scan (blob counts are not path counts).
- `checkpoint.json`: fingerprint and reachable commit sets for incremental scans.
- `refresh-summary.json`, `audit-summary.json`, `summary.json`: sanitized results,
  with `summary.json` containing the latest CLI command's result.
- `public-mirror.git/`: only if explicitly configured; a bare mirror in private
  state, cloned with no templates, fetched from origin with pruning, without
  checkout, hooks, submodules, external diffs, filters, or branch changes in the
  user's checkout.

## Coverage and limits

Local Git always scans reachable history across all refs, root commits included:
commit headers/messages, changed paths and raw added/modified blobs, plus ref names
and annotated-tag metadata. Removed files are covered through their earlier
reachable commits. Merge changes are compared against each parent. Git data is
NUL-delimited where paths occur and treated solely as data; filenames never become
commands, options, or imported code. Hooks/fsmonitor/external diffs/credential
helpers and non-HTTPS network transports are disabled for tool-issued Git commands.
Audit ignores allow-markers and test-path exemptions so untrusted public content
cannot suppress inspection. Conservative findings may need private manual review.
The audit deliberately passes no owner exemption to the scanner: even public
repository-owner links can be flagged when the owner matches the private
denylist. It does not trust a checkout's `origin` to authorize exemptions. A
future scoped exception would need to derive exclusively from trusted
`github_repo` configuration; no such exception is currently applied.

When `github_repo` is configured, bounded REST pagination reads open/closed issue
and PR titles/bodies, repository-wide issue comments, PR inline review comments,
and release names/tags/bodies. Failure on one surface is recorded as unavailable
without suppressing the others. No public notification or search is performed.

**Not scanned:** Actions logs and artifacts; release asset contents; PR review
summary bodies; uncommitted working tree/index; reflogs, unreachable objects,
server-hidden refs or unavailable deleted refs; forks, cached pages, wikis,
discussions and submodule repository contents. This is not proof that a previously
published value was never copied elsewhere, nor a substitute for rotating secrets.

Resource limits are explicit: 32 MiB per command response, 16 MiB per Git blob,
200,000 reachable commits, 10,000 annotated tags, 1,000 pages of 100 GitHub items per
surface, and 5,000 deduplicated retained findings. Command timeouts are generally
45 seconds (SSH/collectors have their own shorter limits; mirror operations allow
180 seconds). Git scanning allows about 15 minutes per repository and GitHub about
10 minutes, checked between bounded operations. Limit failures mark coverage
incomplete; they never silently advance a successful checkpoint. Large repositories
may need a deliberate future streaming/resource-limit extension.

## Verification

```sh
python3 -m unittest discover -s scripts -p test_privacy_audit.py -v
python3 scripts/privacy-audit.py --help
```

Tests use real temporary Git repositories, including removed data, root/other
branch history, adversarial filenames, metadata, annotated tags and hostile Git
configuration. Network-dependent collectors, mirror transport and GitHub calls use
fake responses; no actual host discovery, secret update or public-service mutation
is performed by the test suite.
