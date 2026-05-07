# List of useful npm global packages

Install via `npm install -g <name>`.

1. codeburn | [npm](https://www.npmjs.com/package/codeburn) | [brew tap](https://github.com/getagentseal/homebrew-codeburn) | [GitHub](https://github.com/getagentseal/codeburn)
   1. Track AI coding token usage by task, tool, model, and project
   2. CLI is cross-platform; **prefer npm** over the brew tap — brew tap pulls in brew's `node` as a dependency, which conflicts with nvm and breaks `source ~/.zshrc`
   3. Install (npm): `npm install -g codeburn`
   4. macOS menubar app (native Swift, macOS only): `codeburn menubar`
