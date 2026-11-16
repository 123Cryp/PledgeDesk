# Architecture

## What a trade is

A bonded trader offers to sell crypto (an `asset` such as 500 USDT on a named chain) for fiat at a stated `rate_text`. The taker pays the fiat off-chain, claims the payment on the contract, and the trader releases the crypto to the taker's wallet and posts the transaction hash as release proof. The GEN (or ETH on Base) bond backs the trade: if the trader never releases and loses a dispute, the taker is paid from the bond. The protected amount is a cap on compensation, not a price.

## Trade state machine

OPEN -> PAYMENT_CLAIMED -> ACTIVE -> RELEASED -> COMPLETED
OPEN -> CANCELLED / EXPIRED
PAYMENT_CLAIMED -> OPEN (trader rejects, counted publicly) or ACTIVE (trader accepts, or anyone binds after the confirm window)
ACTIVE -> EXPIRED (deadline plus review window passed with no dispute)
ACTIVE or RELEASED -> DISPUTED -> RESOLVED, or REOPENED once if evidence is insufficient, then RESOLVED

## Economics

- Trader level from total bond: STARTER 5 GEN (cap 2 per trade), VERIFIED 20 (cap 10), PREMIUM 50 (cap 40).
- Lock per trade: 150% of the protected amount, 120% for traders with at least 5 credited completions and no lost disputes.
- TAKER_WINS pays 100% of the protected amount, SPLIT 50%. A 5% fee on the compensation is paid from the trader's lock to the treasury.
- Taker posts a 1 GEN deposit to dispute. It is refunded unless the verdict is TRADER_WINS.
- Second INSUFFICIENT_EVIDENCE verdict ends the dispute as INCONCLUSIVE: no compensation, lock released, deposit refunded.
- Accounting invariant: contract balance = bonds + claimable + treasury + burned claim deposits + held deposits. All payouts are pull payments through `claim()`.

## Anti-abuse

- Payable methods never revert on bad input. The value is credited to `claimable` and the call returns `REFUNDED:<reason>`, so funds cannot get stuck.
- Reputation credit per trader and taker pair is capped at 3, and tiny trades earn no credit.
- Verified and automatic completions are tracked separately.
- Evidence is frozen with a sha256 digest, capped at 3 pieces per side, https only, no embedded credentials.

## Arbiter

Untrusted text is wrapped in `<DATA>` markers with angle brackets neutralised, trusted facts are passed as JSON, the rubric is fixed, and the answer must be JSON with a verdict enum and a reason code enum. Validators re-run the evaluation and compare only the verdict.

## GenVM notes

Header lines are exactly the version line and the Depends line. No comments or docstrings in the contract. Collections are class-level annotations and never assigned in `__init__`. Views return JSON strings.

## Payment confirmation and the timeout trade-off

The contract cannot verify a fiat payment (bank transfer or payment app). A taker claims payment with a reference, and the trader either accepts, rejects, or stays silent. Silence for the confirm window binds the trade (`bound_by = timeout`), otherwise a trader who took the money could escape by never answering.

That choice has a cost: a taker who never paid can bind a trade when the trader is offline. To limit it:

- The judge is told whether payment was `TRADER_CONFIRMED` or `TRADER_SILENT`. For silent trades a taker win needs checkable payment evidence from the taker; without it the verdict must be INSUFFICIENT_EVIDENCE, which ends with no compensation.
- The taker's payment reference is passed to the judge as untrusted evidence.
- A taker whose claim was rejected cannot claim the same trade again.
- On Base the arbiter should apply the same rule. The trade records who bound it (`boundBy`: 1 trader, 2 timeout).

## Unconfirmed-payment policy (enforced in the contracts)

For trades bound by trader silence (`bound_by = timeout`, `boundBy = 2`):

- Compensation is capped at 25% of the protected amount (`TIMEOUT_CAP_BPS = 2500`). TAKER_WINS pays the cap, SPLIT pays the lower of 50% and the cap. The fee is taken on the capped amount.
- Any compensation requires the judge to set `payment_evidence_reviewed = true`. The flag is stored in the final dispute record and, on Base, emitted in the `Resolved` event. It records the judge's responsibility. It is not proof that the payment happened.
- Without the flag, GenLayer downgrades a TAKER_WINS or SPLIT verdict to INSUFFICIENT_EVIDENCE (reopen, then no payout), and `_settle` itself refuses to pay. On Base `resolveDispute` reverts, so the arbiter must choose TRADER_WINS or INSUFFICIENT_EVIDENCE.
- On GenLayer, validators must agree on the flag as well as the verdict for these trades.
- The cap is a conservative starting policy, not an economically derived number.

Residual risk: a fabricated payment proof can still fool a judge, up to the cap. Traders should answer claims promptly.

## URL policy

Both versions use the same rules, checked against `tests/url_vectors.json` (Python test) and a generated Foundry test (`base/test/UrlVectors.t.sol`, regenerate with `python3 scripts/gen_url_tests.py`): empty or https only (lowercase scheme), 12 to 300 bytes, printable ASCII without spaces or backslashes, no userinfo, no brackets, port only 443, host with at least two labels of letters, digits and hyphens, and an alphabetic top-level label of at least two letters (so IP addresses and localhost are rejected).

## Review round 1 changes

- Free-text verdict extraction removed. Only valid JSON with an allowed verdict counts, anything else is INSUFFICIENT_EVIDENCE with reason code UNSPECIFIED.
- GenLayer gained `close_stalled_dispute` (168 units after the evidence deadline): no payout, lock released, deposit returned, outcome STALLED.
- Evidence limit is 3 per side, plus 2 more per side in the reopened round.
- The dispute deposit must be exactly the configured amount.
- Rejected claims no longer lower the reputation score (still shown publicly). Trusted status needs at least 3 taker-confirmed completions.
- Base: the arbiter is snapshotted per dispute, so changing it does not affect open disputes. The owner should still be a multisig. Time unit is bounded to 1..86400.
- Late release is allowed on purpose. The taker can still dispute within the review window, and the late timestamp is visible.
- Aliases are lowercase only in both versions; the GenLayer contract lowercases input, the Solidity contract rejects uppercase.
- Tests: 41 offline tests including a randomized stateful run that checks the accounting invariant after every operation.

## Red-team round and defenses

An internal attack pass (script: the attack list sent with the review bundle) found these weaknesses and the fixes applied. All fixes exist in both contracts.

- Free claim spam: anyone could claim payment on any open trade at no cost, and a silent trader then got bound. Fix: `claim_payment` needs an exact refundable deposit (1 GEN / 0.001 ETH). It returns on completion, lapse or dispute outcome (to the trader if TRADER_WINS), and is burned (locked forever in the contract, counted as `burned`) if the trader rejects the claim. It goes to neither the owner nor the trader, so nobody profits from rejecting a genuine payment.
- Fake-payment payouts on silent trades: a taker could fabricate a payment claim and wait for the trader to miss the 24 h window. Fix: on silent-bound trades a TAKER_WINS or SPLIT ruling is not paid at once. It becomes PAYOUT_PENDING for 7 days. The trader can challenge, which forces a second review round and pays only after that ruling (still capped at 25%, still needing the review flag). If nobody challenges, anyone can finalize after the delay. A challenge is always accepted even if the trader used every evidence slot, and it gives both sides two extra evidence slots for the re-review.
- Fake reputation: a trader could farm the trusted lock ratio with a few friendly takers. Fix: trusted needs at least 5 completed trades, 3 of them taker-confirmed, 5 distinct takers, 14 days of age and no lost disputes.
- Server-side fetch abuse (GenLayer): evidence links used to be fetched by validators. Fix: the contract and the judge never open links. Links are stored and shown only as references; the judge sees only the text the parties wrote. This removes SSRF, DNS-rebinding and page-borne prompt injection. A separate isolated evidence-fetching service can be designed later.
- Weekly compensation cap: tried and removed. A per-trader cap computed from the trader's level let a fraudulent trader exhaust it with a sock-puppet taker (losing only the 5% fee, since the payout returns to their own wallet) so that real victims in the same week got nothing; even honest losses shrank the cap for later takers. The bond and the 150% lock already bound the worst-case loss per trader.
- Base arbiter: should be a multisig (for example 2-of-3). The deploy script refuses an EOA arbiter unless ALLOW_EOA_ARBITER=true (testnet only). Arbiter changes are two-step and timelocked: the owner calls proposeArbiter, anyone can applyArbiterChange after 7 days, the owner can cancel, and every step emits an event. Each dispute snapshots its arbiter when it opens.
- Frontend: self-declared alias label, rate-vs-protect notice, new statuses and actions.

Residual risks that remain by design: the contract cannot see fiat payments and does not read other blockchains, so a convincing fabricated text can still sway a judge; a multisig arbiter can still be bribed or colluding; a trader can still reject a genuine payment, costing the taker the claim deposit (visible as rejected_claims on the trader profile); aliases are not verified; the rate text is not tied to the protected amount. Before real money: compile and run the Solidity CI, run the GenLayer contract on real Studio, and get an external audit.

## Cross-implementation parity

`scripts/gen_parity.py` holds a small reference model of the dispute economics (compensation, 25% cap on silent-payment trades, fee, deposit routing, reputation counters, reopen then inconclusive) and generates 72 scenarios: protected amount (1 or 10), payment confirmed or silent, every verdict with and without the review flag, two-round sequences, and the delayed-payout flows (finalize after the delay, challenge then trader wins, challenge then taker wins again, challenge then inconclusive). The model includes the claim deposit routing. The outputs are `tests/parity_scenarios.json`, run against the GenLayer contract by `tests/test_parity.py`, and `base/test/ParityScenarios.t.sol`, run against the Solidity contract by Foundry. Tests fail if the generated files are stale.

Intentional difference, covered by explicit scenarios: when a silent-payment trade gets TAKER_WINS or SPLIT without the review flag, GenLayer downgrades the verdict to INSUFFICIENT_EVIDENCE (dispute reopens), while Base reverts so the arbiter must submit a different ruling.

Status: the GenLayer contract matches the reference model in all 72 scenarios on the offline stub. The Solidity side has not been compiled or run.
