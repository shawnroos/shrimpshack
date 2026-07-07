// Self-contained "full unicorn" lint for Shawn's OWN repos (not Slate).
// Standalone flat config — brings its own parser + the ENTIRE unicorn suite (flat/all), so it runs on
// repos that have no eslint of their own. Run via this tool's own eslint binary; writes nothing into the repo.
//
// Router picks this for any non-Slate repo (see run.sh). Slate repos use overlay-rules.mjs instead.
// This is `flat/all` by explicit choice — the maximally-opinionated set. High volume is expected.
import unicorn from 'eslint-plugin-unicorn';
import tsParser from '@typescript-eslint/parser';

export default [
    {
        ignores: [
            '**/node_modules/**',
            '**/dist/**',
            '**/build/**',
            '**/out/**',
            '**/.next/**',
            '**/coverage/**',
            '**/vendor/**',
            '**/*.min.js',
        ],
    },
    {
        files: ['**/*.{js,jsx,mjs,cjs,ts,tsx}'],
        languageOptions: {
            parser: tsParser, // parses JS and TS; no `project` set → fast, syntactic (type-aware rules degrade gracefully)
            ecmaVersion: 'latest',
            sourceType: 'module',
            parserOptions: { ecmaFeatures: { jsx: true } },
        },
        plugins: { unicorn },
        rules: {
            ...unicorn.configs['flat/all'].rules,
        },
    },
];
