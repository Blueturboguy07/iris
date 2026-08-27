'use strict';

/**
 * The operator registry.
 *
 * Every entry declares:
 *   arity   - exact number of entries required in `args`
 *   argType - 'any' | 'number' | 'string'; how validate() type-checks args
 *   check   - optional extra argument validation; throws on bad args
 *   apply   - (value, args) => boolean, run only after validation passed
 *             and after filter.js has already ruled out null/undefined
 *             fields and (for argType 'number') non-numeric field values.
 *
 * See docs/FILTERS.md for the full contract.
 */
const OPERATORS = {
  eq: {
    arity: 1,
    argType: 'any',
    apply(value, args) {
      return Object.is(value, args[0]);
    },
  },

  contains: {
    arity: 1,
    argType: 'string',
    apply(value, args) {
      return typeof value === 'string' && value.includes(args[0]);
    },
  },
};

/** Operator names, sorted, for error messages and UI menus. */
function operatorNames() {
  return Object.keys(OPERATORS).sort();
}

module.exports = { OPERATORS, operatorNames };
