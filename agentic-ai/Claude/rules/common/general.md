# General Coding Principles

- Write no comments by default. Add one only when the WHY is non-obvious: a hidden constraint, a workaround for a specific bug, a subtle invariant.
- Don't explain WHAT the code does — well-named identifiers already do that.
- Don't design for hypothetical future requirements. Three similar lines beats a premature abstraction.
- No error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees; validate only at system boundaries (user input, external APIs).
- Prefer editing existing files to creating new ones.
- Default to not adding features, refactors, or abstractions beyond what the task requires.
- No backwards-compatibility shims for clearly removed or unused code — delete it cleanly.
