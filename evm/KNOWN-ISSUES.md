# EVM home: known issues (internal review, 2026-11-11)

These apply to the deployed v1 contracts (`KrexaSwapPolicy` `0x446b4ea7cd7CF874895c03b91478514Cbfd7E931`,
`KrexaRiskHook` `0xAcF4425F4E349cD4cE646898d2a5a6250945f5d9`). None of them lets a session key move funds to a
stranger. No external audit has been done yet; one is required before mainnet use beyond Monad.

## MEDIUM-1: self-paid gas can be burned by a leaked session key

With `maxOpWei > 0`, each self-paid UserOp may take up to `maxOpWei` of the account's native token as gas.
The policy writes no storage and reads no block data during validation (ERC-7562), so it cannot count ops.
A leaked key that runs its own bundler with a high tip can repeat ops and burn the account's native balance.
Pausing the hook does not stop it: gas is charged before the hook runs.

**Mitigation (in force):** install with `maxOpWei = 0` and a non-empty `paymasters` list. Then every self-paid op
fails validation (`PrefundTooHigh`), and gas comes only from an allowlisted paymaster. The Krexa API refuses a
mainnet install without a paymaster, and the owner-side guard refuses any mainnet config with `maxOpWei != 0`.
Self-paid gas is used on testnets only. Revoking the permission ends the risk at once.

## LOW-1: no on-chain upper bound on `maxSlippageBps`

The hook accepts `1..10000`. **Mitigation:** the owner-side guard refuses configs above 200 bps (2%), and the API
always installs 200.

## LOW-2: dust in a token with a stale feed blocks buys

`_valuate` marks NAV as not fresh when any held token's feed is stale, even for a dust balance. Buys are then
refused until the feed updates or the token is sold. This fails safe (sells still work).

## LOW-3: `startNav` is taken at the first trade of the day

The daily-loss baseline is the NAV at the first hooked op of the UTC day, not at midnight. A loss that happens
between midnight and the first op is not counted against that day's limit.

## INFO

- A Universal Router plan with no swap command is accepted by the policy; it can only call allowlisted
  commands and moves no value to a stranger.
- Install-time values (token list, feeds, spenders, targets) are trusted. The API builds them from pinned
  addresses and the owner-side guard re-checks them before the owner signs.
