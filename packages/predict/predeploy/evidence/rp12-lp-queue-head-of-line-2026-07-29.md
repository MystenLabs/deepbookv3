# LP Queue Head-of-Line Blocking by Limit-Missing Requests

**Item:** RP-12 (register annex evidence) · **Instrument:** Move unit repro on `origin/main` `e4f27843` · **Date:** 2026-07-29

Status: measured on the pre-fix code, where three attempts were compiled in. The
attempt count is now admin-tunable and ships at 1, at which the measured blockage
cannot occur; the numbers below are what an operator re-enables, bounded by the
configured ceiling, if they raise it.

## What Was Measured

The superseded RP-12 held a limit-missing request at the head of its queue and
stopped that queue for the flush, refunding only on the third miss. Its stated
reasoning was that the three-attempt expiry "bounds queue blockage". The bound is
per request. Requests compose, and nothing bounded how many a single party could
queue: `min_output` is unbounded at admission, `min_supply_request` /
`min_withdraw_request` are 10 DUSDC / 1 PLP, escrow is refunded in full on
expiry, and accounts are permissionless.

## Repro

Two minimum-sized requests carrying `min_output = u64::MAX` (no executable mark
can ever quote it) queued ahead of one honest request with no limit, drained
repeatedly at a constant 1.0 mark with both budgets unbounded, so the only thing
that can stop a queue is the contract's own head handling.

Observed schedule, identical on both queues:

| Flush | Head | Outcome | Honest request |
| --- | --- | --- | --- |
| 1 | A | miss 1, queue stops | blocked |
| 2 | A | miss 2, queue stops | blocked |
| 3 | A → B | A refunded, B miss 1, queue stops | blocked |
| 4 | B | miss 2, queue stops | blocked |
| 5 | B → honest | B refunded, honest fills | filled |

**2N+1 flushes of total blockage for N limit-missing requests** — the third miss
refunds and the next request takes its first miss in the same flush, so each
request after the first costs two further flushes rather than three.

## Cost And Scale

The escrow returns in full, so the cost is gas plus temporarily parked
minimum-size capital: 100 pre-stuffed withdraw requests are 100 PLP, all
refunded. The blockage is denominated in flushes, so its wall-clock cost is
`(2N+1) × flush cadence` — at N=100 that is 201 flushes of no honest LP exits,
which is hours to days across any cadence an operator would plausibly run. FIFO
means a party cannot extend the wait of a request already ahead of theirs; the
sustained form is keeping a rolling backlog so arriving LPs queue behind it.

## Scope And Limits

Measured against `origin/main` `e4f27843` at the `lp_book` layer, with hand-set
marks rather than a live flush: it measures the queue's head handling, not NAV
behaviour. The deployed testnet package (`ec99cfae`) predates request limits
entirely and never had this path. No mainnet deployment exists, so the finding
was pre-deploy throughout.

Provenance: external audit issue #42.

## Post-Fix Pinning

`packages/predict/tests/plp/lp_book_tests.move` —
`supply_limit_miss_does_not_block_later_requests` and
`withdraw_limit_miss_does_not_block_later_requests` stage the same shape at the
shipped attempt count and assert the later request fills in the *same* flush that
refunds the unfillable head; `supply_limit_miss_refunds_at_the_flush_that_reaches_it`
and `withdraw_limit_miss_refunds_at_the_flush_that_reaches_it` pin the
single-request case. All four fail if the head-holding `break` is restored at one
attempt (verified by mutation, 2026-07-29).

`raising_attempts_reintroduces_head_of_line_blocking` pins the other direction:
at three attempts the honest request behind an unfillable head is not reached for
two further flushes. The table above is therefore not just history — it is the
cost of the knob, and the suite fails if that stops being true.
