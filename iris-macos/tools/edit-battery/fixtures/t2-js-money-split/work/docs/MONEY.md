# Money contract

## `splitEvenly(totalCents, parts)`

Divides `totalCents` into exactly `parts` whole-cent amounts.

Guarantees, all of which the billing reconciliation job depends on:

1. **Conservation.** The returned amounts sum to exactly `totalCents`. No
   cent is created and none is lost, for any total and any part count.
2. **Fairness.** The largest and smallest returned amounts differ by at most
   one cent.
3. **Order.** The returned array is in non-increasing order, so the party
   who absorbs the odd cent is always deterministic and always first.
4. **Signs.** Negative totals (refunds and chargebacks) obey the same three
   rules. Note what rule 3 means for a refund: the *largest* value is the
   one closest to zero, so the extra cent lands at the **end** of the array.

Worked examples:

    splitEvenly(1000, 4)   -> [250, 250, 250, 250]
    splitEvenly(1000, 3)   -> [334, 333, 333]
    splitEvenly(100, 3)    -> [34, 33, 33]
    splitEvenly(-1000, 3)  -> [-333, -333, -334]
    splitEvenly(-100, 3)   -> [-33, -33, -34]
    splitEvenly(7, 1)      -> [7]
    splitEvenly(0, 3)      -> [0, 0, 0]

## Errors

`splitEvenly` throws `RangeError` when `parts` is not an integer >= 1, and
`TypeError` when `totalCents` is not a safe integer.
