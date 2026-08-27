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

  gt: {
    arity: 1,
    argType: 'number',
    apply(value, args) {
      return value > args[0];
    },
  },

  lt: {
    arity: 1,
    argType: 'number',
    apply(value, args) {
      return value < args[0];
    },
  },

  between: {
    arity: 2,
    argType: 'number',
    check(args) {
      if (args[0] > args[1]) {
        throw new Error('operator "between" requires args[0] <= args[1]');
      }
    },
    apply(value, args) {
      return value >= args[0] && value <= args[1];
    },
  },
};

/** Operator names, sorted, for error messages and UI menus. */
function operatorNames() {
  return Object.keys(OPERATORS).sort();
}

module.exports = { OPERATORS, operatorNames };
