# The differential gate

The single rule that makes moving logic into the core safe:

> **A platform may only stop using its own implementation once this gate proves
> the core produces byte-identical output for every case in the corpus.**

Not "looks equivalent". Not "the unit tests pass". Identical, case for case,
against the implementation that ships today.

## Why it exists

The macOS app is the mature one — 47k lines, in daily use. The core is new.
If a module moves and the core is subtly different, macOS regresses in a way
that unit tests written *for the core* cannot catch, because they were written
from the same misunderstanding.

So the shipping implementation is the reference and the core has to match it.
When they diverge the gate says which case and what each produced, and the
answer is to fix the core — never to widen the corpus until it passes.

## Running it

```bash
node parity/run.mjs break-signature
```

Each module gets a `<module>.swift` reference extracted verbatim from the
shipping macOS source. When that source changes, the reference changes with it
and the gate catches the drift immediately.

## The corpus

`corpus.json` is real-shaped crash text plus every edge case the logic's
ordering depends on — Windows paths that the POSIX pattern would otherwise
eat, bare hex, empty strings, whitespace-only input. Add a case whenever a bug
teaches you one; never remove a case to make the gate pass.
