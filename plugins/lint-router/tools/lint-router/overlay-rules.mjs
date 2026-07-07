// Personal unicorn correctness overlay for Slate web-app — agent code-quality feedback.
// Layered ON TOP of Slate's own eslint.config.mjs (see eslint.unicorn.mjs written into each worktree).
// This is NOT part of Slate's shared config and never lands in the org repo.
//
// Curation is empirically vetted: the --fix of every rule below was run against real Slate src and
// checked with the TS type-checker. Rules whose auto-fix breaks this Angular/Pixi + strict-TS codebase
// are OFF (so an agent is never nudged into a breaking "fix"). See the memory
// `reference_unicorn_autofix_footguns_slate` for the full story.
import unicorn from 'eslint-plugin-unicorn';

export default [
    {
        files: ['**/*.ts'],
        plugins: { unicorn },
        rules: {
            ...unicorn.configs['flat/recommended'].rules,

            // OFF — idiom-fighters (Slate/Angular conventions; high noise, no correctness gain):
            'unicorn/prevent-abbreviations': 'off',
            'unicorn/no-null': 'off',
            'unicorn/no-array-for-each': 'off',
            'unicorn/no-array-reduce': 'off',
            'unicorn/no-array-callback-reference': 'off',
            'unicorn/no-this-outside-of-class': 'off',
            'unicorn/consistent-function-scoping': 'off',
            'unicorn/no-object-as-default-parameter': 'off',
            'unicorn/no-array-sort': 'off',
            'unicorn/no-array-reverse': 'off',
            'unicorn/prefer-array-some': 'off',
            'unicorn/no-await-expression-member': 'off',
            'unicorn/prefer-code-point': 'off',
            'unicorn/no-static-only-class': 'off',
            'unicorn/no-empty-file': 'off',

            // OFF — pure style (Prettier owns formatting):
            'unicorn/explicit-length-check': 'off',
            'unicorn/switch-case-braces': 'off',
            'unicorn/numeric-separators-style': 'off',
            'unicorn/no-zero-fractions': 'off',
            'unicorn/no-negated-condition': 'off',
            'unicorn/prefer-ternary': 'off',
            'unicorn/no-lonely-if': 'off',
            'unicorn/prefer-switch': 'off',
            'unicorn/prefer-logical-operator-over-ternary': 'off',
            'unicorn/no-unreadable-array-destructuring': 'off',
            'unicorn/consistent-compound-words': 'off',
            'unicorn/no-useless-undefined': 'off',
            'unicorn/filename-case': 'off',

            // OFF — VERIFIED FOOTGUNS: unicorn's --fix breaks this codebase. Never nudge an agent to apply these.
            'unicorn/prefer-https': 'off', // rewrites the SVG namespace URI (http://www.w3.org/2000/svg → https) → breaks createElementNS/SVG rendering
            'unicorn/prefer-dom-node-remove': 'off', // mis-fires on Pixi removeChild (Container/Graphics/string), not just DOM nodes
            'unicorn/dom-node-dataset': 'off', // .dataset needs HTMLElement (breaks on Element); returns undefined vs getAttribute's null
            'unicorn/no-new-array': 'off', // new Array(n)→Array.from changes any[]→unknown[] AND sparse→dense (iteration behavior)
            'unicorn/no-useless-spread': 'off', // removes ...{computed-key} spreads that intentionally suppress TS excess-property checks
            'unicorn/prefer-at': 'off', // arr[len-1]→arr.at(-1) widens to T|undefined, cascading type errors
            'unicorn/prefer-object-from-entries': 'off', // reduce→Object.fromEntries loosens Record types
            'unicorn/require-css-escape': 'off', // CSS.escape(x) requires string; breaks on string|number selector args

            // WARN — real value but the fix can change behavior (DOM/event/spread); review, don't blind-fix:
            'unicorn/prefer-spread': 'warn',
            'unicorn/prefer-add-event-listener': 'warn',
            'unicorn/prefer-query-selector': 'warn',
            'unicorn/new-for-builtins': 'warn',
            // WARN — good modernization but a style shift:
            'unicorn/no-for-loop': 'warn',
            'unicorn/catch-error-name': 'warn',
            // WARN — correctness rules with no auto-fix (manual judgement to apply):
            'unicorn/prefer-includes-over-repeated-comparisons': 'warn',
            'unicorn/no-useless-switch-case': 'warn',
            'unicorn/error-message': 'warn',
            'unicorn/prefer-array-last-methods': 'warn',
            'unicorn/no-immediate-mutation': 'warn',
            'unicorn/no-useless-iterator-to-array': 'warn',
            'unicorn/prefer-blob-reading-methods': 'warn',
            'unicorn/better-dom-traversing': 'warn',
            'unicorn/no-abusive-eslint-disable': 'warn',
            'unicorn/prefer-default-parameters': 'warn',
            'unicorn/prefer-math-trunc': 'warn',
            'unicorn/no-unused-array-method-return': 'warn',
            'unicorn/prefer-dom-node-text-content': 'warn',
            'unicorn/prefer-class-fields': 'warn',
            'unicorn/no-confusing-array-splice': 'warn',
            'unicorn/prefer-top-level-await': 'warn',
            'unicorn/prefer-iterator-to-array-at-end': 'warn',
            'unicorn/prefer-keyboard-event-key': 'warn',

            // Everything else in flat/recommended stays ERROR: the verified-safe correctness/modernization core
            // (prefer-number-properties, prefer-string-slice, prefer-includes, prefer-string-replace-all, prefer-at
            //  is OFF above, prefer-set-has, prefer-date-now, prefer-optional-catch-binding, prefer-regexp-test,
            //  prefer-export-from, prefer-global-this, prefer-native-coercion-functions, prefer-dom-node-append, …).
            // NOTE for isNaN/isFinite (prefer-number-properties): NOT auto-fixable — global isNaN coerces.
            // Fix by hand: Number.isNaN(x) where x is provably numeric, else Number.isNaN(Number(x)) to preserve behavior.
        },
    },
];
