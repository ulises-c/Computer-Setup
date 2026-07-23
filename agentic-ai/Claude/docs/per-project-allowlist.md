# Per-project allowlist overrides

Railguard can grant one project access to an additional path without widening the
global allowlist for every project. The global policy must explicitly opt in; a
project cannot enable this feature for itself.

In the global `railguard.yaml`:

```yaml
fence:
  enabled: true
  allow_local_overrides: true
```

In the project root, create `.railguard.local.yaml`:

```yaml
fence:
  allowed_paths:
    - "<additional-project-path>"
```

The local file is additive only. It can add allowed paths, but it cannot remove
denied paths, change other rules, or disable the fence. Denied paths still take
precedence over allowed paths. A malformed local file is ignored with a warning.

Treat the override as per-machine checkout state and gitignore it unless the path
is a safe, shared project dependency. The implementation and issue history live in
[ulises-c/railguard](https://github.com/ulises-c/railguard/blob/main/docs/per-project-allowlist.md).
