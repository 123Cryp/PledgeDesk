# PledgeDesk

Bonded traders and on-chain dispute arbitration for peer-to-peer crypto trades, built as a GenLayer Intelligent Contract with a static frontend.

A taker pays the trader in fiat off-chain, the way P2P trades already work. The trader has locked a GEN bond that backs the trade. If the crypto is never released, both sides submit evidence and GenLayer validators reach consensus on a verdict. A winning taker is paid from the trader's bond.

## Layout

- `contracts/pledgedesk.py` - the Intelligent Contract (production windows, 1 hour unit)
- `contracts/pledgedesk_testnet.py` - generated variant with 5 second units for fast live testing
- `scripts/make_testnet.py` - regenerates the testnet variant
- `frontend/index.html` - single-file hash-routed app (genlayer-js, Studio network)
- `tests/` - offline test suite (includes shared URL vectors and parity scenarios) with a small GenLayer stub (no network, no pip)
- `base/` - Solidity version for Base (`src/PledgeDeskBase.sol`, Foundry tests, deploy script)
- `frontend/base.html` - Base frontend (viem), also usable as a Base App / Farcaster mini app
- `frontend/.well-known/farcaster.json` - mini app manifest template (placeholders to fill)
- `ARCHITECTURE.md` - state machine, economics, limits

## Run the tests

    python3 -m unittest discover -s tests -t tests

## Deploy

1. Open GenLayer Studio, create a new file, paste `contracts/pledgedesk_testnet.py` (use `pledgedesk.py` for real time windows), deploy with no arguments.
2. Open `frontend/index.html?c=<contract address>` or set the address under Settings, then put the address into `DEFAULT_ADDRESS` in `frontend/index.html`.

## Base version

Same trade flow, with ETH bonds. Differences from the GenLayer version:

- No AI judge. A designated `arbiter` address (set by the owner, ideally a multisig) rules after the evidence window. If it stays silent for 7 days anyone can close the dispute as inconclusive (no payout, deposits returned).
- Trades bound by trader silence cap compensation at 25%, need the arbiter's `paymentEvidenceReviewed` flag, and pay out only after a 7-day window in which the trader can challenge. Claiming a payment needs a refundable deposit (see ARCHITECTURE.md).
- Invalid input reverts normally (ETH is returned by the EVM), so no refund-instead-of-revert path.
- Constants are scaled to ETH (min bond 0.005, protect cap 0.002 / 0.01 / 0.04, dispute deposit 0.001). Constructor takes `(arbiter, timeUnit)`; use 3600 for real windows, 5 for fast tests.
- The Solidity code was adapted from a tested sibling project by renaming; it has not been compiled or run yet, has not been deployed to a live chain and has not been audited. Run the Foundry tests first (`cd base && forge test`).
- The arbiter should be a multisig contract; the deploy script refuses an EOA unless `ALLOW_EOA_ARBITER=true` (testnet only). Arbiter changes are timelocked 7 days (`proposeArbiter`, `applyArbiterChange`).
- Deploy: `cd base && ARBITER=0x... forge script script/Deploy.s.sol --rpc-url https://sepolia.base.org --account <keystore> --broadcast`, then open `frontend/base.html?c=<address>&n=sepolia`.
- Mini app: host `frontend/` over https, replace `APP_URL` in `base.html` and `.well-known/farcaster.json`, and sign the account association with Base Build. The mini app is untested.

## Honest limits

- The contract cannot see bank or payment-app transfers, and it does not read blockchains. It only weighs submitted evidence.
- Aliases are self-declared labels, not verified accounts.
- Validators are language models and can be wrong. No appeal in v1.
- Compensation is in GEN and covers the protected amount, not necessarily the value of the crypto.
- Links are never opened. When the trader stays silent, a text-only payment claim is expected to be rejected as insufficient, so the taker gets the deposits back but no compensation.
- The offline test suite passes (65 tests). The GenLayer contract has not been deployed on Studio yet, so the live behaviour of the AI judge is untested.

MIT licensed.
