# Krexa EVM home: Kernel policy + risk hook

> **UNAUDITED - do not deploy to mainnet with user funds before an external audit.**
> Live on Monad mainnet with team funds only; Monad testnet, Arbitrum Sepolia and Robinhood Chain testnet for testing.

Two contracts that confine a Krexa **session key** on a ZeroDev **Kernel v3.3** account (EntryPoint v0.7).
They are split on purpose by ERC-4337 phase. Install **both** on the session permission.

| Contract | Kernel module | Phase | What it enforces |
|---|---|---|---|
| `KrexaSwapPolicy` | policy (type 5), one config per `(wallet, permissionId)` | **validation**, static only | router + selector allowlist, token allowlist, `recipient == account` decoded from calldata, `approve` only to allowlisted spenders, no native value, no calls to the account / policy / hook, expiry (`validUntil` returned in `validationData`), max prefund per UserOp (`maxOpWei`) and a paymaster allowlist |
| `KrexaRiskHook` | hook (type 4), one config per wallet | **execution** (`preCheck` / `postCheck`) | per-trade USDC cap, rolling 24h cap (25 hourly buckets), ops/hour, fresh Chainlink price for buys, slippage / `minOut` proof (always on), daily-loss NAV check (blocks buys, never sells), owner-only pause |

Why the split: public ERC-7562 bundlers (Pimlico, Coinbase CDP, ...) reject a UserOp whose validation reads
`TIMESTAMP`/`NUMBER`, reads storage of another contract (a Chainlink feed), or touches storage not associated with the
sender. Everything that needs a clock, a price or a mutable counter is therefore in the hook, which Kernel runs in the
execution phase where those rules do not apply. The policy is a pure function of the UserOp calldata and the
account's own config (see "ERC-7562 footprint"). **The policy alone has no amount limits, no rate limit and no price
check: the hook must be installed on the same permission** (the API checks `validationConfig(vId).hook`).

Owner operations never go through either contract (see "Owner vs session"). Nothing here can move funds; both
contracts only say yes or no.

## Layout

```
src/evm-home/
  KrexaSwapPolicy.sol  KrexaRiskHook.sol
  interfaces/   IERC7579Modules (Kernel v3.3, MIT), PackedUserOperation (ERC-4337 v0.7), IAggregatorV3 (Chainlink)
  lib/          ExecDecoder (Kernel execute calldata), SwapDecoder (router calldata), OracleLib (Chainlink, hook only)
test/evm-home/  unit, fuzz, invariant, Kernel stand-in (MockKernel) integration, deploy-script test, optional Base fork
script/DeployEvmHome.s.sol
```

## Run

```
cd evm
forge build
forge test -vv
forge coverage --report summary --no-match-coverage "(test|script|mocks)"
# optional, read-only Base fork (needs a Base RPC URL in YOUR environment, never in a file):
BASE_MAINNET_RPC_URL=... forge test --match-contract ForkBaseTest
```

## Check a deployment

`./script/verify-deployments.sh` rebuilds both contracts and checks that the code hash of the build, of every
`deployments/<chainId>-evm-home.json`, and of the code on chain are the same. The compiler settings in
`foundry.toml` and the OpenZeppelin commit in `lib/` are the ones the deployed bytecode was built with.

## Deploy

```
export PRIVATE_KEY=...   # any key with a little gas; the contracts have no owner, so the key gets no power
cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url <RPC>   # CREATE2 factory must exist
forge script script/DeployEvmHome.s.sol --rpc-url <RPC>               # dry run
forge script script/DeployEvmHome.s.sol --rpc-url <RPC> --broadcast
```

## Owner vs session (how the hook tells them apart)

Source: ZeroDev Kernel v3.3, `src/Kernel.sol` (`validateUserOp`, `executeUserOp`), `src/core/HookManager.sol`,
`src/core/ValidationManager.sol` (`validationConfig[vId].hook`, `_checkUserOpPolicy`).

- A hook is stored **per validation id**. In `executeUserOp` Kernel calls `hook.preCheck(msg.sender, value,
  userOp.callData[4:])` and `hook.postCheck(ctx)` only when that validation's hook is not `address(1)`.
- `msg.sender` seen by `preCheck` is the **EntryPoint** for owner and session ops alike, and the calldata carries no
  validator id. So a hook cannot recognise a session op from its arguments.
- Therefore the split is structural: **install `KrexaRiskHook` as the hook of the session permission only**
  (`ValidationConfig.hook = KrexaRiskHook`), never on the root validator. Owner UserOps (root validator, hook
  `address(1)`) skip the policy and the hook. Pause, unpause, config changes and withdrawals always work.
- Inside both modules `msg.sender` is the Kernel account, so all state is keyed by the account.
- A session UserOp cannot reach `pause/unpause/setConfig/installModule`. Those functions check `msg.sender ==
  account`, and an account executing its own call has exactly that `msg.sender`. The barrier is that the session
  op may not **target** the account, the policy or the hook. `KrexaSwapPolicy` denies those targets (and the hook
  address from its config); `KrexaRiskHook.preCheck` denies them again. A hook uninstalled while the permission still
  names it makes `preCheck` revert (fail closed).
- With a hook on the permission, Kernel requires the UserOp calldata to be `executeUserOp.selector (0x8dd7712f) ++
  execute(bytes32,bytes)`; the policy accepts both that and a bare `execute(...)`.

## ERC-7562 footprint of the policy

`checkUserOpPolicy` is the only code that runs while the bundler validates the UserOp. It touches:

- **Opcodes:** SLOAD, KECCAK256, CALLER, ADDRESS, CALLDATA*, MLOAD/MSTORE/MCOPY, arithmetic, control flow. The runtime
  has **no** TIMESTAMP, NUMBER, BLOCKHASH, COINBASE, PREVRANDAO, GASLIMIT, GASPRICE, BASEFEE, BLOBHASH, BLOBBASEFEE,
  ORIGIN, BALANCE, SELFBALANCE, GAS, EXTCODE*, CALL*, CREATE*, SELFDESTRUCT. (SSTORE/LOG exist only in
  `onInstall` / `onUninstall` / `setConfig`, which run in the execution phase.)
- **Storage read:** only this contract's slots `keccak256(pad32(wallet) . X) + n` (the wallet is the innermost mapping
  key, the shape ERC-7562 calls "associated with the sender"): `_cfg[id][wallet]` (3 words), `_gen[id][wallet]`, and one
  `_allow[key][wallet]` word per checked target+selector / token / spender / paymaster. No other contract is read.
- **Storage written:** none.
- **Expiry:** `validUntil` is returned as `validationData = uint256(validUntil) << 160` (authorizer 0, `validAfter` 0).
  The EntryPoint enforces it. The policy never reads the clock.

`test/evm-home/Erc7562.t.sol` pins this: it scans the policy runtime for banned opcodes, records the storage accesses
of a real validation and asserts they are a subset of the wallet-keyed slots with zero writes, and checks that the
scanner does find `TIMESTAMP` / `STATICCALL` / `SSTORE` in the hook (so the scan is not vacuous).

## Install data (for the API)

Kernel calls `policy.onInstall(permissionId32 ++ yourBytes)` and `hook.onInstall(yourBytes)`; `permissionId32` is the
4-byte `PermissionId` **right-padded with zeros to 32 bytes** (`0x<4 bytes>` + 28 zero bytes). That same `bytes32` is
the `id` argument of every policy call below. `yourBytes` is `abi.encode(<struct>)` (one tuple, so it starts with an
offset word).

### `KrexaSwapPolicy.PolicyConfig`

```ts
const policyConfigAbi = [{
  type: 'tuple',
  components: [
    { name: 'validUntil', type: 'uint48'  }, // unix seconds, non-zero; returned in validationData (EntryPoint enforces)
    { name: 'usdc',       type: 'address' }, // the quote token; must equal the hook's usdc
    { name: 'hook',       type: 'address' }, // KrexaRiskHook (always denied as a target), or 0x0
    { name: 'spenders',   type: 'address[]' },  // approve targets: routers, Permit2, AllowanceHolder (max 32)
    { name: 'targets', type: 'tuple[]', components: [   // max 32, at least 1
        { name: 'target',    type: 'address'  },
        { name: 'selectors', type: 'bytes4[]' },        // only: 0x04e45aaf 0xb858183f 0x3593564c 0x2213bc0b 0x1fff991f 0x87517c45
    ]},
    { name: 'tokens',     type: 'address[]' },  // non-USDC tokens the key may trade, max 32 (no feeds, no decimals here)
    // appended fields (new fields only ever go at the END)
    { name: 'maxOpWei',   type: 'uint128'   },  // max prefund of a self-paid UserOp in wei; 0 only together with a paymaster list
    { name: 'paymasters', type: 'address[]' },  // paymasters a session UserOp may name (max 32); empty = self-paid only
  ],
}] as const
// policy onInstall data = concat([permissionId32, encodeAbiParameters(policyConfigAbi, [cfg])])
```

Selectors: `0x04e45aaf` SwapRouter02 `exactInputSingle`, `0xb858183f` `exactInput`, `0x3593564c` Universal Router
`execute(bytes,bytes[],uint256)`, `0x2213bc0b` 0x `AllowanceHolder.exec`, `0x1fff991f` 0x Settler `execute` (list it on the
**Settler** address; it is only used as the inner target of `exec`), `0x87517c45` Permit2 `approve(address,address,uint160,uint48)`
(list it on the Permit2 address). ERC-20 `approve` needs no entry: it is allowed on any allowlisted token to any allowlisted spender.

Install-time rules (revert `InvalidConfig(reason)`): `usdc != 0`, `validUntil != 0`, `targets` non-empty, lists at most
32, the account, the policy, the hook, USDC and every listed token may not be a target or spender; every selector must be
one of the six above, `maxOpWei != 0` unless `paymasters` is non-empty, no zero paymaster. The policy cannot check `validUntil > now` (it reads no clock); the API must pass a sensible value.

Policy calls the API needs (all `id` = `permissionId32`):

```
setConfig(bytes32 id, PolicyConfig cfg)              // account only (owner UserOp); rebuilds the allowlists from scratch
getConfig(bytes32 id, address wallet) -> Cfg{installed, validUntil, usdc, hook, maxOpWei}
isTargetAllowed(id, wallet, target, selector) / isSpenderAllowed(id, wallet, spender) / isTokenAllowed(id, wallet, token)
```

Errors the bundler returns in the validation revert (`AA23 reverted`, decode with the policy ABI): `NotInitialized`,
`BadSender`, `EmptyExecution`, `ValueNotAllowed(value)`, `TargetForbidden(target)`, `NotAllowed(target,selector)`,
`TokenNotAllowed(token)`, `SpenderNotAllowed(spender)`, `BadCalldata`, `ZeroAmount`, `PairNotAllowed(in,out)`, `PrefundTooHigh(prefund,max)`, `PaymasterNotAllowed(paymaster)`; from the
decoders `RecipientNotWallet(recipient)`, `CommandNotAllowed(cmd)`, `ActionNotAllowed(action)`, `SelectorUnsupported(sel)`,
`BadPath`, `Malformed`, `NotUserFunded`, `PoolHookNotAllowed(hooks)`, `NotExecute`, `UnsupportedMode(mode)`, `BadEncoding`.
Expiry shows up as the EntryPoint's own `AA22 expired or not due`.

### `KrexaRiskHook.HookConfig`

```ts
const hookConfigAbi = [{
  type: 'tuple',
  components: [
    { name: 'maxDailyLossUsdc', type: 'uint128' }, // 6 decimals, > 0
    { name: 'perTradeCapUsdc',  type: 'uint128' }, // 6 decimals, > 0: sum of all buy inputs in one UserOp
    { name: 'dailyCapUsdc',     type: 'uint128' }, // 6 decimals, >= perTradeCapUsdc: rolling 24h buys (counted for 24h-25h)
    { name: 'maxOpsPerHour',    type: 'uint32'  }, // > 0, per UTC hour
    { name: 'maxOracleAge',     type: 'uint32'  }, // seconds, > 0
    { name: 'maxSlippageBps',   type: 'uint16'  }, // 1..10000; 0 is rejected (it would switch the minOut proof off)
    { name: 'usdc',             type: 'address' }, // decimals() must be 6; same token as the policy's usdc
    { name: 'tokens', type: 'tuple[]', components: [ // non-USDC tokens the key may trade, counted in NAV, max 16
        { name: 'token',    type: 'address' },
        { name: 'feed',     type: 'address' },     // Chainlink token/USD, required
        { name: 'decimals', type: 'uint8'   },     // must equal token.decimals(), checked at install; no duplicate tokens
    ]},
  ],
}] as const
// Kernel hookData = concat(['0x00', encodeAbiParameters(hookConfigAbi, [cfg])])
//   first byte is Kernel's flag: 0x00 = install only if not yet initialised, 0xff = force onInstall
```

The hook has its own token list (`tokens`); a swap whose non-USDC token is not in it is denied (`TokenNotAllowed`).
Keep it equal to the policy's `tokens`.

Hook calls (all must come from the account itself, i.e. an owner UserOp `execute(account -> hook, 0, data)`):

```
pause()                         // blocks every session op
unpause()
setConfig(HookConfig cfg)       // keeps pause flag, the day's NAV snapshot, spend window and op counter
riskState(address wallet) -> (bool blockBuys, bool fresh, uint256 nav, uint256 startNav, uint256 loss)   // view, for the UI/engine
spentInWindow(address wallet) -> uint256     // USDC bought in the live rolling window (24h-25h)
remainingDaily(address wallet) -> uint256
opsThisHour(address wallet) -> uint32
getState(address wallet) / getTokens(address wallet)
```

Hook errors (they surface as a reverted execution, not as a validation failure): `HookPaused`, `BuysBlocked`,
`ValueNotAllowed(value)`, `TargetForbidden(target)`, `NotInitialized`, `InvalidConfig(reason)`, `ZeroAmount`,
`PairNotAllowed(in,out)`, `TokenNotAllowed(token)`, `PerTradeCapExceeded(requested,cap)`, `DailyCapExceeded(requested,remaining)`,
`OpsPerHourExceeded(max)`, `StaleOracle(feed)`, `MinOutTooLow(fairUsdc,minOutUsdc)`; plus the decoder
errors listed above (the hook decodes the same calldata again).

**A reverted hook check still costs gas.** `preCheck` runs after validation, so the bundler has already accepted the
UserOp; if a limit trips, the UserOp is included, reverts, and the account pays for it. The engine should read
`spentInWindow` / `opsThisHour` / `riskState` first and not submit what the hook will refuse.

### Wiring the permission (Kernel `installValidations`)

1. `vId = 0x02 ++ permissionId(4 bytes)` (`VALIDATION_TYPE_PERMISSION`, `ValidatorLib.permissionToIdentifier`).
2. `ValidationConfig { nonce, hook: KrexaRiskHook }`.
3. Permission data: policies first (this policy with flag `0x0000`, i.e. not skipped for UserOps), the ECDSA session
   signer last. The permission must not be `SKIP_USEROP`. `checkSignaturePolicy` always denies, so the session key can
   never produce an ERC-1271 signature even if the signer allows signatures.
4. Grant the permission only the `execute(bytes32,bytes)` selector (`grantAccess`).
5. After install read back `account.validationConfig(vId).hook == KrexaRiskHook`. If the hook were missing the
   caps, rate limit, slippage proof, daily-loss and pause protection would silently be absent (the policy alone is only
   a static allowlist); the API must refuse to mark the agent live until this holds.
6. UserOps for this permission must be `0x8dd7712f ++ execute(...)` (hooked path), mode single (`0x00..`) or batch
   (`0x01..`) with exec type `0x00`.

## Semantics

**What a session UserOp may contain (policy, validation phase).** `execute` single or batch (default exec type;
try/delegatecall/static are rejected), value 0 on every call, batch encoding must be canonical (we re-encode and compare,
because Kernel parses batches with a laxer pointer parser and two parsers must never disagree). Each call must be one
of: ERC-20 `approve` on an allowlisted token to an allowlisted spender; Permit2 `approve` (token and spender
allowlisted); an exact-input swap on an allowlisted `(router, selector)`. `transfer`, `transferFrom`, module installs
and anything else have no allowed code path.

**Swaps.** `tokenIn` and `tokenOut` must both be allowlisted and exactly one must be USDC (token-to-token is denied).
A *buy* is USDC in. Buys and sells are classified from the router calldata (first/last token of the path), which is
what the router pulls and pays. The policy and the hook run the same decoder on the same bytes.

| Router path | Recipient rule | Other rules |
|---|---|---|
| SwapRouter02 `exactInputSingle` / `exactInput` | `recipient == account` exactly | path length checked |
| Universal Router `execute` | swap recipients: account or `MSG_SENDER` (address 1); `ADDRESS_THIS` (address 2) denied; `SWEEP`/`UNWRAP_WETH`: account or address 1 | only V3_SWAP_EXACT_IN, V2_SWAP_EXACT_IN, V4_SWAP, SWEEP, UNWRAP_WETH; flags `0x80`/`0x40` denied; `payerIsUser` must be true; V4: one swap action, pool hooks must be 0, `TAKE` recipient checked, `TAKE_PORTION`/others denied |
| 0x `AllowanceHolder.exec` -> Settler `execute` | Settler `slippage.recipient == account`, `operator == target`, Settler allowlisted | actions are opaque, so the hook demands a Chainlink-proven `minOut` (fresh feed, else `StaleOracle`) |

Anything the decoder cannot prove reverts, which is a denial. That includes any calldata that is not byte-for-byte what
a canonical ABI encoder writes for the decoded value: every `abi.decode` in `SwapDecoder` is followed by a re-encode that
must equal the input (`Malformed` otherwise). A router that changes a struct (a trailing field, a new array such as
v4's `minHopPriceX36`) or a non-canonical pointer layout is therefore denied instead of being misread.

**Gas (policy, validation phase).** Kernel pays `missingAccountFunds` from the account's own ETH, so the session key must not
control how much. A UserOp with empty `paymasterAndData` needs `(preVerificationGas + verificationGasLimit + callGasLimit) *
maxFeePerGas <= maxOpWei` (overflow reverts = deny); a UserOp with a paymaster needs the paymaster in `paymasters`
(`paymasterAndData` shorter than 52 bytes is `BadCalldata`). Both are pure functions of the UserOp and the config. This
bounds ONE op. How many ops a compromised key can submit is not bounded on chain (a reverting hook check still costs gas, see
below): the owner revokes the permission, and the account's ETH balance should be kept small (top up per need).
Suggested `maxOpWei`: Base 0.002 ETH (`2e15`: 1M gas at 2 gwei, ~20x the usual Base fee); Monad 1 MON (`1e18`: 2M gas at
500 gwei); set it from the chain's gas price and the token price, and re-check when either moves a lot.

**Limits (hook, execution phase; they apply to buys; sells are never capped or counted, matching the off-chain engine).**
- Per-trade: total USDC input of the whole UserOp (all swaps in a batch) `<= perTradeCapUsdc`.
- Daily: rolling 24h, **25 hourly buckets** in a ring. A buy in hour H counts through the end of hour H+24, so every buy
  is counted for at least 24h and at most 25h: never looser than an exact sliding window (24 buckets would let 2x the cap
  through inside 23h00m01s). `spentInWindow` sums the 25 buckets that are still live (25 reads); a 25h+ gap just empties
  the window. The cost: a buy made early in an hour stays counted up to an hour longer than 24h.
- Ops/hour: fixed UTC-hour counter; every UserOp that passes the hook counts (sells too). A burst of up to 2x the limit is
  possible across an hour boundary.
- Expiry: `validUntil` is in the policy's `validationData`; the EntryPoint enforces it. The hook does not check it.
- Oracle: every swap needs a fresh Chainlink answer for its token (`StaleOracle` otherwise). `maxSlippageBps` is
  always >= 1, so every swap with a fresh price must satisfy `minOutUsdc >= inUsdc * (10000 - bps) / 10000` (a `minOut` of 0
  is never accepted; set 10000 to accept any `minOut`). A stale price blocks the session key's sells too: without a
  price there is no `minOut` floor, and a dust sell through a pool the key controls would pass. The owner exits directly.
- Config checks at install (the hook may call tokens, it runs in execution): `usdc.decimals() == 6`, every
  `TokenFeed.decimals == token.decimals()`, no duplicate tokens.
- A denied UserOp rolls back, so it consumes no budget and no op count.

**Hook (daily loss).** `NAV = USDC + sum(balance x Chainlink)` over the hook's token list. The first valuation after
00:00 UTC writes `startNav`. While `startNav - nav >= maxDailyLossUsdc`, or while any held token cannot be priced,
buys are blocked and sells pass. "Buy" is detected from balances in `postCheck`: USDC must not decrease and no
allowlisted token balance may increase. That also catches a buy hidden next to a sell in one batch (a rotation that
leaves every token balance no higher and USDC no lower is allowed).
- **Withdrawals count as loss** through the NAV delta, same as the off-chain engine. There is no separate
  `withdrawnToday` counter: it would count the same dollars twice, and the hook cannot see owner-path outflows
  directly. Deposits raise NAV and offset earlier losses the same way.
- Stale feed on a token with zero balance is ignored (nothing to price).

## Known gaps and decisions for the audit

1. **ERC-7562: satisfied by design, with one trade-off.** The policy is static (see "ERC-7562 footprint"), so a public
   bundler accepts the UserOp. The price is that amount limits are enforced after validation: a UserOp that the hook
   refuses is still included and still costs the account gas. A compromised key can burn gas this way, bounded per op by
   the policy's `maxOpWei` and overall only by the account's ETH balance; the owner revokes the permission or pauses. Do not install the policy without the hook.
2. **Gas.** `checkUserOpPolicy` measured 29k-68k gas (median 38k) in tests; `preCheck` 32k-195k (the daily-cap window reads
   25 buckets, NAV reads each token and feed). Cold storage adds more. Monad bills the gas limit, so set
   `verificationGasLimit` / `callGasLimit` from a simulation, not a blanket value.
3. **Router layouts are pinned and enforced.** Universal Router/v4 decoding follows the layouts deployed in 2025 (v4 structs
   without `minHopPriceX36`). A router upgrade that changes a layout makes the decoder deny (every decode is re-encoded and
   compared, see "Swaps"); it never mis-allows. Re-test against
   the live router when an address changes (the Base fork test does this for SwapRouter02, Permit2 and Universal Router V3;
   **V4 and the 0x path are not covered by a live-chain test**).
4. **0x Settler rotates.** Settler addresses change per release; the owner must `setConfig` the new Settler into the
   allowlist. Until then 0x calls are denied.
5. **`minOut` is always enforced** (`maxSlippageBps >= 1`) against a fresh Chainlink price; with a stale feed the session
   key cannot swap that token at all, so an agent's exit waits for the feed (the owner can still sell). Recommended value: 100-300 bps.
6. **Chainlink only.** No L2 sequencer-uptime check (known gap, audit L3: after a sequencer outage a feed can be fresh by
   timestamp but stale in fact; mitigated by a short `maxOracleAge`, not closed); a feed with a long heartbeat needs `maxOracleAge >= heartbeat`.
   Monad has an ETH/USD feed only (verified in `notes/evm-vendors.md`); other tokens have no on-chain price there.
7. **Approvals are not amount-capped** (infinite approvals to allowlisted spenders are normal). The risk is a malicious
   or upgradeable allowlisted spender, so the allowlist is the trust root.
8. **Pause is owner-only** by design. The Krexa server cannot pause on chain (a guardian-pause role was left out); its
   kill switch is the off-chain engine plus revoking the permission.
9. Native ETH is not valued in NAV and not spendable by the session key (value is always 0).
10. USDC is assumed to have 6 decimals; tokens carry their own decimals in config.

## Deploy

`script/DeployEvmHome.s.sol` deploys both contracts with CREATE2 through the canonical deterministic deployer
(`0x4e59b448...956C`, salt `keccak256("krexa.evm-home.v1")`), so the addresses are identical on every chain for the same
compiler settings. It reads `PRIVATE_KEY` from the environment only and writes `deployments/<chainid>-evm-home.json`.
It has not been run against any network.
