# Round 2 — cross-examination prompts

Each reviewer receives the other's findings **verbatim** and must rule on every one.
Transcribe faithfully — paraphrasing loses the file:line evidence that makes a claim
checkable, and a reviewer cannot verify a claim you have summarized away.

Resume each reviewer's **existing** context using the harness mechanics in `SKILL.md`,
so neither has to re-derive its own analysis.

## Frame (both sides)

Open with the framing, and do not soften it — deference is the main failure mode of this
round:

> This is a peer-AI exchange, not a correction. Do NOT defer to the other reviewer
> because it is a different model — it has its own blind spots and knowledge cutoff.
> Verify claims against the actual code before agreeing or disagreeing. Where the other
> reviewer reproduced a finding empirically and you reasoned from code reading, its
> evidence is stronger; where you reproduced and it reasoned, yours is.

Identify the orchestrator honestly in both prompts: *"This is {{ORCHESTRATOR_HARNESS}}
using {{ORCHESTRATOR_PROVIDER}} {{ORCHESTRATOR_MODEL}}, orchestrating a double-blind
review."* Name the other reviewer with this run's actual configuration. In the Claude
prompt, restate the read-only rule; a resumed reviewer may otherwise start fixing things.

Pass along anything **you** verified independently between rounds, and say you verified
it. It anchors the exchange in checked fact and stops both reviewers relitigating a
settled point.

## The ask

```
For each of the other reviewer's N findings, state AGREE (and whether you would change
its severity), PARTIALLY AGREE (say precisely which part survives), or DISAGREE (why,
with code evidence). Where you can cheaply verify a claim by reading code or running an
isolated simulation, do so rather than reasoning about it — especially {{LOAD_BEARING_CLAIMS}}.

Then address these specifically:

1. Findings {{X}} and {{Y}} look like the same underlying gap reached by two different
   vectors. Do you agree they are one finding? Would a single fix close both, or does
   each vector need its own? [Name each reviewer's proposed fix and ask which one
   actually closes the whole class — and whether it survives {{KNOWN_COMPLICATION}}.]

2. Findings {{A}} and {{B}} are distinct gaps in the same logic. Are there further gaps
   in that function neither of you reported? Does fixing both together create false
   positives on ordinary work?

3. You rated {{Z}} {{SEVERITY_A}}; the other rated it {{SEVERITY_B}} and reproduced it.
   Defend or revise your severity given its evidence.

4. The other reviewer did not report {{YOUR_UNIQUE_FINDINGS}}. Do you still stand behind
   each? Which, if any, do you now think are noise?

5. Revise your own findings where cross-examination changed them — withdraw, downgrade,
   or upgrade.

6. Give a final merge-blocker set: the minimum subset (yours and the other's) that
   genuinely must be fixed before this PR merges, versus what ships as follow-up issues.
   Be decisive — I will act on this list.
```

Close with the round-1 grounding rules again (label inferences; say "unverified" rather
than guessing).

## Why each question earns its place

- **Q1 (one gap, N vectors)** — deduplication belongs to the reviewers. It also forces
  the fix question: in the source run, one reviewer *tested* the other's proposed
  `tool: "*"` change, confirmed it closed its own separately-reported vector too, and
  withdrew its own recommendation as strictly worse. You will not get that by merging
  two finding lists yourself.
- **Q2 (further gaps)** — highest yield in the protocol. Both reviewers, primed by
  seeing a second set of gaps in code they had already read, found more. Round 2 is
  where the deepest bypasses surface.
- **Q3 (severity reconciliation)** — resolves rating spread with evidence instead of
  averaging. Expect the code-reading reviewer to concede to the one with a repro.
- **Q4 (unique findings)** — the honest test for noise. A reviewer will downgrade its own
  weak finding when asked why the other reviewer did not think it worth reporting.
- **Q5 (self-revision)** — makes revision an expected outcome rather than a loss of face.
- **Q6 (decisive list)** — "I will act on this" is what converts a survey into a
  recommendation. Both reviewers producing near-identical blocker sets is the strongest
  ship/no-ship evidence the protocol can give you.

## Expect asymmetry

The two sides will not return the same shape of answer, and that is fine — one may lean
on reproduction, the other on code reading and severity calibration. Report both; do not
flatten them into a single voice.
