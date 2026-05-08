# List of useful npm global packages

Install via `npm install -g <name>`.

1. codeburn | [npm](https://www.npmjs.com/package/codeburn) | [brew tap](https://github.com/getagentseal/homebrew-codeburn) | [GitHub](https://github.com/getagentseal/codeburn)
   1. Track AI coding token usage by task, tool, model, and project
   2. CLI is cross-platform; **prefer npm** over the brew tap
   3. Install (npm): `npm install -g codeburn`
   4. macOS menubar app (native Swift, macOS only): `codeburn menubar`
   5. **Why not brew tap?** The formula depends on brew's `node` (always latest, not LTS), which conflicts with nvm. Even with `nvm use --delete-prefix` keeping nvm's node first in PATH, `brew upgrade` can silently reset the npm prefix back to `/opt/homebrew` and reintroduce the conflict. npm install uses whatever node nvm has active — no conflict, no fragility.
