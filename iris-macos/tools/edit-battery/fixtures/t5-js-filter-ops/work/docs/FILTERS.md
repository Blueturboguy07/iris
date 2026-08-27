# The filter contract

A filter is a plain object:

```js
{ field: 'age', op: 'gt', args: [21] }
```

`src/operators.js` holds the operator registry. `src/filter.js` holds
`validate`, `applyOne` and `applyAll`, which are operator-agnostic: adding an
operator means adding a registry entry and nothing else.

## Registry entry shape

```js
name: {
  arity,      // exact number of entries required in `args`
  argType,    // 'any' | 'number' | 'string'
  check,      // optional; extra argument validation, throws on bad args
  apply       // (value, args) => boolean; `value` is the row's field value
}
```

## Validation rules

`validate(filter)` runs before any row is touched and throws:

| situation | error | message |
|---|---|---|
| `op` is not in the registry | `Error` | `unknown operator: <op>` |
| wrong number of args | `Error` | `operator "<op>" expects <arity> argument(s), got <n>` |
| `argType: 'number'` and an arg is not a finite number | `TypeError` | `operator "<op>" requires numeric arguments` |
| `argType: 'string'` and an arg is not a string | `TypeError` | `operator "<op>" requires string arguments` |
| `field` is not a non-empty string | `TypeError` | `filter.field must be a non-empty string` |
| `args` is not an array | `TypeError` | `filter.args must be an array` |

`check` runs last and may throw its own `Error` for operator-specific
argument problems.

## Apply rules

`applyOne(row, filter)` validates, then reads `row[filter.field]`:

* A field that is `undefined` or `null` yields `false`. It never throws.
* An operator whose `argType` is `'number'` yields `false` for a field value
  that is not a finite number. Only the *arguments* are type-checked; row
  data is whatever the warehouse gave us and must never throw.
* Otherwise the result is `apply(value, args)`, coerced with `Boolean`.

`applyAll(rows, filters)` returns the rows for which every filter holds.
An empty filter list returns every row.

## Operators today

| op | arity | argType | meaning |
|---|---|---|---|
| `eq` | 1 | `any` | strict equality (`Object.is`) |
| `contains` | 1 | `string` | field is a string containing the argument |

## Operators we want

| op | arity | argType | meaning |
|---|---|---|---|
| `gt` | 1 | `number` | field is strictly greater than the argument |
| `lt` | 1 | `number` | field is strictly less than the argument |
| `between` | 2 | `number` | `args[0] <= field <= args[1]`, both ends inclusive |

`between` additionally rejects a reversed range at validation time, via
`check`, with the `Error` message:

    operator "between" requires args[0] <= args[1]
