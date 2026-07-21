// multi-slice-review — ONE review round (U6), a native Workflow script.
//
// Invoked as Workflow({ scriptPath: workflows/review.js, args: <slice-plan> }).
// It fans out ONE round: each slice's lens reviewers in parallel, seam reviewers
// in parallel, a mutation proof per slice on an ISOLATED worktree, then synthesizes
// findings by slice/seam. It NEVER loops — the across-rounds loop is /loop
// re-invoking the round command across turns (KTD4). The round command calls the
// pure predicates (predicates.js) on this round's output and persists round-state.
//
// Globals agent()/pipeline()/parallel()/phase()/log() are provided by the Workflow
// runtime. This module is executed by that runtime only — never imported under bare
// node (that is predicates.js's job, which stays native-primitive-free).
//
// args (the confirmed slice-plan the front door prints and the caller may edit):
//   {
//     base: '<git base ref>',
//     round: <n>,                       // 1-based round number
//     otherSliceNames: ['storage','net',...],
//     priorFixes: ['<what changed since last round>', ...],   // priming, rounds >1
//     envTraps: ['<verification lies in this repo>', ...],    // §4.3, stated as fact
//     slices: [
//       { id, invariant, files:[...], lenses:['correctness','adversarial',...],
//         testCommand: 'npm test' | null }
//     ],
//     seams: [
//       { id, sliceA, sliceB, contract:'<one sentence>', question:'<the one question>' }
//     ],
//   }

export const meta = {
  name: 'multi-slice-review-round',
  description: 'One seam-aware review round: slices → lens reviewers, seam reviewers, mutation proof, synthesis.',
  phases: [
    { title: 'Slices', detail: 'lens reviewers per slice, in parallel' },
    { title: 'Seams', detail: 'one reviewer per seam: both sides + one question' },
    { title: 'Mutation', detail: 'prove load-bearing assertions on an isolated worktree' },
    { title: 'Synthesize', detail: 'collect capped findings by slice/seam' },
  ],
};

// Defect-category enum, INLINED (not imported): the Workflow loader requires
// `export const meta` to be the FIRST statement, so review.js cannot `import`
// from predicates.js. SEAM — keep this list identical to DEFECT_CATEGORIES in
// workflows/predicates.js; they must stay in sync.
const DEFECT_CATEGORIES = [
  'correctness', 'contract-mismatch', 'resource-safety', 'concurrency',
  'security', 'missing-validation', 'ordering',
];

// Capped structured returns (KTD5): ~8 findings, detail to an artifact file.
const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      maxItems: 8,
      items: {
        type: 'object',
        required: ['id', 'title', 'severity', 'slice', 'lens', 'defectCategory', 'whyItMatters', 'evidence'],
        properties: {
          id: { type: 'string' },
          title: { type: 'string' },
          severity: { type: 'string', enum: ['P0', 'P1', 'P2', 'P3'] },
          slice: { type: 'string' },
          lens: { type: 'string' },
          defectCategory: { type: 'string', enum: [...DEFECT_CATEGORIES] },
          whyItMatters: { type: 'string' },
          evidence: { type: 'array', items: { type: 'string' }, minItems: 1 },
          artifactPath: { type: ['string', 'null'] },
        },
      },
    },
  },
};

const MUTATION_SCHEMA = {
  type: 'object',
  required: ['slice', 'assertionsLoadBearing', 'report'],
  properties: {
    slice: { type: 'string' },
    // true = a broken assertion failed then passed on restore; false = a survivor
    // (weak assertion) or no runnable assertion to mutate.
    assertionsLoadBearing: { type: 'boolean' },
    survivors: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },
  },
};

// The four-part brief every reviewer gets (§4).
function brief(args, scopeLine) {
  return [
    scopeLine,
    `Deliberately OUT of scope: the other slices (${args.otherSliceNames.join(', ')}).`,
    args.round > 1 && args.priorFixes.length
      ? `Already-fixed since last round:\n- ${args.priorFixes.join('\n- ')}\nHunt what those fixes INTRODUCED — fix-induced regressions outnumber fresh discoveries after round one.`
      : '',
    args.envTraps.length
      ? `Environment traps (fact, not caution — prove by EXECUTION, not string-matching):\n- ${args.envTraps.join('\n- ')}`
      : 'Prove findings by execution, not by string-matching.',
    `Output contract: at most 8 findings, compact. Put any longer detail in an artifact file and reference it in artifactPath. Each finding needs id, severity (P0-P3), defectCategory (one of: ${DEFECT_CATEGORIES.join(', ')}), whyItMatters, and at least one evidence quote.`,
  ].filter(Boolean).join('\n\n');
}

function lensPrompt(slice, lens, args) {
  return [
    `You are the **${lens}** reviewer for slice **${slice.id}**.`,
    `Its invariant (one thing to check): ${slice.invariant}`,
    `Files: ${slice.files.join(', ')}`,
    lens === 'adversarial'
      ? 'Try to FALSIFY the slice: construct inputs/states where its invariant breaks.'
      : lens === 'security'
        ? 'Focus on destructive actions, untrusted input, and credentials in this slice.'
        : lens === 'reliability'
          ? 'Focus on retries, locks, signals, background work, and partial-failure/orphaned state.'
          : lens === 'api-contract'
            ? 'Focus on changed public signatures / return conventions and their callers.'
            : 'Check the slice does what its invariant claims, on happy, nil, empty, and error paths.',
    brief(args, `Review ONLY slice ${slice.id}'s internals through the ${lens} lens.`),
  ].join('\n\n');
}

function seamPrompt(seam, args) {
  return [
    `You are the reviewer for the seam between slices **${seam.sliceA}** and **${seam.sliceB}**.`,
    `The shared contract: ${seam.contract}`,
    `Answer EXACTLY ONE question: ${seam.question}`,
    'Do NOT review either side\'s internals — the slice reviewers own those. Look only for an asymmetry across the seam: a guard on one side absent on the other, a field one side requires and the other treats as optional, an ordering guarantee that spans both, a value produced by one and misinterpreted by the other, a rule duplicated rather than shared.',
    brief(args, `Scope: the ${seam.sliceA}↔${seam.sliceB} contract only.`),
  ].join('\n\n');
}

function mutationPrompt(slice, args) {
  return [
    `You are the mutation-proof runner for slice **${slice.id}** (§5).`,
    `Work on an ISOLATED checkout of the reviewed diff (base ${args.base}) — never the user's working tree.`,
    slice.testCommand
      ? `The slice's assertion command is: \`${slice.testCommand}\`. Pick a load-bearing assertion it covers, BREAK the code that assertion guards, run the command, and confirm it FAILS. Then restore and confirm it PASSES. Report both outputs. If the mutation SURVIVES (the assertion still passes with the code broken), the assertion is weak — report it as a survivor and say so.`
      : `This slice exposes no runnable assertion command. Report assertionsLoadBearing=false with "no executable assertion to mutate" — do NOT fabricate a pass.`,
    'A deliberate-fail flag that flips one expected value proves only the harness can exit non-zero; it is NOT evidence any assertion is load-bearing. Mutate the CODE.',
  ].join('\n\n');
}

// ── one round ──────────────────────────────────────────────────────────────
// The Workflow tool delivers `args` as a JSON STRING in this runtime — parse it.
const input = typeof args === 'string' ? JSON.parse(args) : (args || {});

phase('Slices');
log(`Round ${input.round}: ${input.slices.length} slices, ${input.seams.length} seams.`);

// Each slice: its lens reviewers in parallel (Slices), then a mutation proof (Mutation).
const perSlice = await pipeline(
  input.slices,
  (slice) =>
    parallel(
      slice.lenses.map((lens) => () =>
        agent(lensPrompt(slice, lens, input), {
          schema: FINDINGS_SCHEMA,
          phase: 'Slices',
          label: `${slice.id}:${lens}`,
        }),
      ),
    ),
  (lensResults, slice) =>
    agent(mutationPrompt(slice, input), {
      schema: MUTATION_SCHEMA,
      phase: 'Mutation',
      label: `mutate:${slice.id}`,
      isolation: 'worktree',
    }).then((mutation) => ({
      slice: slice.id,
      findings: (lensResults || []).filter(Boolean).flatMap((r) => r.findings),
      mutation,
    })),
);

// Seams: one reviewer each, in parallel (Seams).
phase('Seams');
const seamResults = await parallel(
  input.seams.map((seam) => () =>
    agent(seamPrompt(seam, input), { schema: FINDINGS_SCHEMA, phase: 'Seams', label: `seam:${seam.id}` }),
  ),
);

phase('Synthesize');
const sliceFindings = perSlice.filter(Boolean).flatMap((s) => s.findings);
const seamFindings = seamResults.filter(Boolean).flatMap((r) => r.findings);
const mutationReports = perSlice.filter(Boolean).map((s) => s.mutation).filter(Boolean);

// This round's output. The round command feeds `findings` through predicates.js
// (dedupeVsSeen → isEmptyRound → escalates) and persists round-state.
return {
  round: input.round,
  base: input.base,
  findings: [...sliceFindings, ...seamFindings],
  mutationReports,
  weakAssertions: mutationReports.filter((m) => !m.assertionsLoadBearing),
};
