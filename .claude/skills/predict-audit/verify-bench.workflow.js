// Verify-panel PRECISION bench — runs the audit's verify PANEL over a labeled corpus (evals/verify_corpus.json)
// with NO find phase, so it measures the single most load-bearing component (what decides which findings you
// see) for a fraction of a full run (~1 loader + one panel per corpus entry). Each corpus entry carries an
// `expect` verdict (refuted | settled); a healthy panel matches it. A `confirmed` on a must-refute/settle
// entry is a false-positive LEAK — the number to drive down. RECALL (confirming a real bug) is tested by
// evals/seeds.md, which needs a seeded tree, not this bench.
//
// The verify LENSES below MIRROR orchestrator.workflow.js — keep them in sync (scripts can't share imports).
//
// args = { corpus?: [ ...entries ], corpusPath?: string }  // default: read evals/verify_corpus.json via a loader agent
// Run (zero-arg): Workflow({ scriptPath: '.claude/skills/predict-audit/verify-bench.workflow.js' })

export const meta = {
  name: 'predict-audit-verify-bench',
  description: 'Precision bench for the audit verify panel: run the refute/settled/repro panel over a labeled corpus and score verdict match',
  phases: [
    { title: 'Load', detail: 'read the labeled corpus (evals/verify_corpus.json)' },
    { title: 'Verify', detail: 'run the real verify panel over each entry; score against its expected verdict' },
  ],
}

const SKILL = '.claude/skills/predict-audit'
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
if (!A || typeof A !== 'object') A = {}
const CORPUS_PATH = A.corpusPath || `${SKILL}/evals/verify_corpus.json`
const SETTLED_SOURCES = 'AGENTS.md "Settled design decisions" (incl. the D-id ledger), packages/predict/predeploy/rounding-policy.md, and packages/predict/predeploy/open-items.md'
const CODEX = 'codex:codex-rescue'
const SEVRANK = { critical: 5, high: 4, medium: 3, low: 2, info: 1 }
function sevOf(s) { return SEVRANK[(s || '').toLowerCase()] || 0 }
function isHigh(sev) { return sev === 'Critical' || sev === 'High' }

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'settled', 'uncertain'] },
    adjusted_severity: { type: 'string', enum: ['Critical', 'High', 'Medium', 'Low', 'Info'] },
    reasoning: { type: 'string' },
    evidence: { type: 'string', description: 'file:line, git, or sim fact supporting the verdict' },
  },
  required: ['verdict', 'adjusted_severity', 'reasoning', 'evidence'],
}
// MIRROR of orchestrator.workflow.js LENSES / COMBINED_VERIFY — keep in sync.
const LENSES = [
  { tag: 'refute', agentType: CODEX, build: () => 'ADVERSARIAL LENS = REFUTE-BY-CORRECTNESS. Try to prove this finding FALSE from the actual code. Read the cited lines, grep all call sites, check whether the precondition can hold. If you cannot construct a concrete code-grounded triggering path, verdict "refuted". Cite file:line.' },
  { tag: 'settled', agentType: null, build: () => `ADVERSARIAL LENS = SETTLED-DECISION CHECK. Check ${SETTLED_SOURCES}. Is this an accepted/rejected design decision, committed policy, or already-tracked open item? If yes, verdict "settled" with the D-id or committed-doc reference in evidence. Otherwise pass through.` },
  { tag: 'repro', agentType: CODEX, build: () => 'ADVERSARIAL LENS = REPRODUCE. Trace the exact PTB-ordered sequence through the real mint/redeem/liquidate/settle/flush code. Does it actually reach the cited line with all preconditions co-occurring? If they cannot co-exist, verdict "refuted"; if it genuinely triggers, "confirmed". Cite the call chain.' },
]
const COMBINED_VERIFY = { tag: 'verify', agentType: CODEX, build: () => `ADVERSARIAL VERIFY (single pass — do ALL THREE): (1) REFUTE from the actual code; if no concrete triggering path, "refuted". (2) SETTLED — check ${SETTLED_SOURCES}; if it matches, "settled" with the D-id/doc ref. (3) REPRODUCE the PTB-ordered path; if preconditions co-occur, "confirmed", else "refuted". Cite file:line / D-id / doc ref.` }
const VERIFY_PREAMBLE = `You are an ADVERSARIAL VERIFIER in a Predict smart-contract audit. A lens proposed the finding below; TEST it against the actual code + git + the settled-decision priors, do NOT agree by default. Read ${SKILL}/primer.md for the module map + prior-awareness. The .claude/predict-review/ files are STALE — trust the current tree. Do NOT run sui build/test or localnet; reason from source, grep, git, and Python. STAY SCOPED. Verdicts: confirmed / refuted / settled (cite a D-id) / uncertain. Provide file:line / git evidence. adjusted_severity = your independent severity (Info if refuted/settled). OUTPUT: emit ONLY the structured verdict object.`
function verifyPrompt(f, lens) { return `${VERIFY_PREAMBLE}\n\nFINDING:\n${JSON.stringify(f, null, 2)}\n\n${lens.build()}` }

function aggregateStatus(verdicts) {
  const vs = verdicts.filter(Boolean)
  if (!vs.length) return 'unverified-panel'
  if (vs.find(v => v.verdict === 'settled')) return 'settled'
  const refuted = vs.filter(v => v.verdict === 'refuted').length
  const confirmed = vs.filter(v => v.verdict === 'confirmed').length
  if (refuted > confirmed) return 'refuted'
  if (confirmed > 0) return 'confirmed'
  return 'uncertain'
}
async function verdictAgent(prompt, lens, label) {
  const base = { schema: VERDICT_SCHEMA, effort: 'high', phase: 'Verify' }
  let v = await agent(prompt, { ...base, label, ...(lens.agentType ? { agentType: lens.agentType } : {}) })
  if (!v) v = await agent(prompt, { ...base, label: `${label}:retry` })
  return v
}

// ---------- Load ----------
phase('Load')
let corpus = Array.isArray(A.corpus) ? A.corpus : null
if (!corpus) {
  const CORPUS_SCHEMA = {
    type: 'object', additionalProperties: false,
    properties: { corpus: { type: 'array', items: {
      type: 'object', additionalProperties: true,
      properties: { id: { type: 'string' }, expect: { type: 'string' }, severity: { type: 'string' }, title: { type: 'string' }, location: { type: 'string' }, claim: { type: 'string' }, scenario: { type: 'string' }, impact: { type: 'string' }, confidence: { type: 'string' }, recommendation: { type: 'string' }, settled_ref: { type: 'string' }, evidence: { type: 'string' }, why: { type: 'string' } },
      required: ['id', 'expect', 'severity', 'title', 'location', 'claim'],
    } } },
    required: ['corpus'],
  }
  const loaded = await agent(`Read the JSON file ${CORPUS_PATH} and return its "corpus" array VERBATIM (every entry, every field, unchanged). Do not add, drop, edit, or re-order entries. This is a data-load, not analysis.`,
    { schema: CORPUS_SCHEMA, effort: 'low', phase: 'Load', label: 'load:corpus' })
  corpus = (loaded && loaded.corpus) || []
}
if (!corpus.length) { log('⚠ empty corpus — nothing to bench'); return { error: 'empty_corpus', corpusPath: CORPUS_PATH } }
log(`verify-bench — ${corpus.length} corpus entries from ${Array.isArray(A.corpus) ? 'args' : CORPUS_PATH}`)

// ---------- Verify + score ----------
phase('Verify')
const results = await parallel(corpus.map((f, fi) => async () => {
  const panel = isHigh(f.severity) ? LENSES : [COMBINED_VERIFY]
  const verdicts = await parallel(panel.map(lens => () => verdictAgent(verifyPrompt(f, lens), lens, `bench:${f.id}:${lens.tag}`)))
  const status = aggregateStatus(verdicts)
  return {
    id: f.id, expect: f.expect, got: status, pass: status === f.expect,
    why: f.why || '', severity: f.severity,
    verdicts: verdicts.filter(Boolean).map(v => `${v.verdict}/${v.adjusted_severity}: ${(v.reasoning || '').slice(0, 160)}`),
  }
}))

const scored = results.filter(Boolean)
const passes = scored.filter(r => r.pass).length
// A confirmed on a must-refute/settle entry is the dangerous failure (a false positive leaking to the report).
const leaks = scored.filter(r => !r.pass && r.got === 'confirmed')
const panelDead = scored.filter(r => r.got === 'unverified-panel')
scored.forEach(r => log(`${r.pass ? '✅' : '❌'} ${r.id}: expected ${r.expect}, got ${r.got}`))
log(`verify-bench precision: ${passes}/${scored.length} matched | ${leaks.length} false-positive leak(s) | ${panelDead.length} panel-dead`)

return {
  summary: { corpus: scored.length, passed: passes, precision: scored.length ? +(passes / scored.length).toFixed(2) : 0, leaks: leaks.length, panel_dead: panelDead.length },
  leaks, results: scored,
}
