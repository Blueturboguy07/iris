# money-split

Integer-cent helpers used by the billing service. Everything is in whole
cents; no floating-point money crosses a module boundary.

## Build

    npm run build

## Test

    npm test

The behavioural contract for `splitEvenly` lives in `docs/MONEY.md`.
