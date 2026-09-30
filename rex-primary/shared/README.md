# `/shared` — the frozen REX interface package (INIT-1/2/3)

Imported by `contracts/` via the `@rex-shared/` and `@rex-shared-mocks/` remappings
(`contracts/foundry.toml`). **Version: `1.12.0`, marked by the git tag `shared-v1.12`.** Bump the tag on any
change to a frozen declaration — a breaking change also implies a new wire version and, per ADR-011, a
`REXPrimary` redeploy.

> **This header went stale for six versions (2026-09-12).** It still read `1.5.0` while the tags ran to
> `shared-v1.10`, and the entries for 1.6 through 1.10 below were never written. They are not
> reconstructed here: inventing a changelog after the fact would make this file look authoritative
> about releases nobody recorded. Read `git tag -l 'shared-v*'` and
> `git diff shared-v<n>..shared-v<n+1> -- shared/src/` for those.
>
> **Do not treat an unchanged tag as proof the interface is unchanged.** Session web-6e observed the
> tag failing to move across three consecutive deploys while `shared/src` and the extracted ABI both
> changed — including at `1.3.1`, where the tag was only cut after the deploy, in response to that
> observation. What actually catches this is the dApp's drift check, which compares **extracted ABI
> output** rather than the tag. A release checklist that reasons "same tag, same interface" has been
> wrong every time it has been tried here.

- **1.12.0** (`shared-v1.12`) — **breaking**: `IREXPrimary` loses `previewRedeem` and `nav()` (moved off the
  money-path contract to the new stateless `IREXLens`, ADR-028 D6 / SC13, to keep `REXPrimary` under
  EIP-170); `IREXRedeem` gains `redemptionFeeOf(uint64 epochId)`; `IEpochSchedule` gains
  `periodIfOpen(uint64 timestamp)` (ADR-029 — the epoch trigger now opens only inside a window, not
  indefinitely once due); new interface `IREXLens` (`previewRedeem`, `shutDownBlockers`), one deployment per
  chain. The wire moves to a new version, `WIRE_VERSION_V2` (ADR-028, canonical micro-units, decimals read
  from the tokens): `@rex/wire` adds `decodeAnyVersion` (reads either v1 or v2) and exports `rexLensAbi`. A
  consumer still calling the removed `IREXPrimary` views, or decoding a `1.4.0` deployment's wire with the
  old strict `decode`, breaks; per ADR-011 this is also a `REXPrimary` redeploy (`1.4.0`).
- **1.11.0** (`shared-v1.11`) — additive: `IREXPrimary.RedeemEpochAccrued(uint64 epochId, uint64 batchId,
  uint256 netIn)`, emitted by `initiateSubEpoch` where it writes `red.batchId` (1.3.1). Closes the window in
  which the redeem batch id existed on chain but appeared in no event until that batch bridged or released,
  so an accruing redeem position read a null batch through the API. No signature changed, nothing removed;
  consumers that ignore the event are unaffected.

- **1.5.0** (`shared-v1.5`) — additive: `IPruvExecutor.abortDeposit(uint64)` declared + implemented by
  `PruvExecutor` (SC4b, try-then-abort recovery, spec §7.5); the `BatchAlreadyResolved` @dev corrected to name
  only `abortDeposit`; `MockCollateralWarpRoute` gains a receive-side `deliverTokens` (models the abort's USDC
  collateral unlock). No wire change (`RequestKind`/`Codec`/`Instruction` unchanged from v1.4). Backward-compatible.
- **1.4.0** (`shared-v1.4`) — additive: `RequestKind.SubAborted` appended to the wire enum (+ reserved
  `RedeemAborted`, decoded by no contract until SC5); errors `AbortBeforeDeadline`/`BatchAlreadyResolved`
  (spec §12); events `SubBatchAborted` (`IREXSubscribe`, implemented and emitted by `REXPrimary`, SC4a)
  and `SubDepositAborted` (`IPruvExecutor`, declared now — emitted once `abortDeposit` builds at SC4b).
  Wire freeze-note carve-out (ADR-016): appending a `RequestKind` decoded only by the redeployable
  `REXPrimary` is byte-additive within a wire version and needs no bump; a new executor-inbound kind
  does — `WIRE_VERSION_V1` is unchanged. Backward-compatible, no wire change.
- **1.3.0** (`shared-v1.3`) — additive: `IREXMatching` (the epoch-matching event surface —
  `MatchingToggled`/`MatchingPerformed`/`BatchReleased`, spec §8), implemented by `REXPrimary` (SC3), plus
  the deployed `NavOracleConsumer` ABI (`NavUpdated` feed + `ReporterEnrolled`, spec §3.3) so the indexer
  (BE4) builds matching + NAV against committed signatures. Backward-compatible, no wire change.
- **1.2.0** (`shared-v1.2`) — additive: `ILaunchpad` surface (`depositToLaunchpad`/`cancelLaunchpad`/
  `closeLaunchpad`/`claimLaunchpad`/`refundLaunchpad` + events), implemented by `REXPrimary` (SC2); the
  launchpad calls ride in the deployed `rexPrimaryAbi`, no separate interface export. `Receipt.sol` gains
  `LAUNCHPAD_ID`. Backward-compatible, no wire change.
- **1.1.0** — additive: `IREXSubscribe` gains the `subBatch` stable projection (spec §3.1), symmetric
  with `redeemBatch`. Backward-compatible (a new function), no wire change.
- **1.0.0** (`shared-v1`) — initial freeze (INIT-1/2/3).

## Frozen (do not change a declaration without a version bump)

- `src/Wire.sol` — `RequestKind`, `Instruction` (the cross-chain payload). Appending a `RequestKind`
  decoded only by the redeployable `REXPrimary` is byte-additive within a wire version and needs no
  bump; a new executor-inbound kind does (ADR-016).
- `src/Codec.sol` — versioned `encode`/`decode` (ADR-016). A wire change is a NEW version, not an edit.
- `src/Errors.sol` — the shared error vocabulary. Adding an error is additive; changing/removing one is breaking.
- `src/Receipt.sol` — receipt-id encoding + class constants (incl. `LAUNCHPAD_ID`).
- `src/IHyperlane.sol` — the bridge interfaces REX calls.
- `src/IREXPrimary.sol` — `IREXSubscribe` (built, incl. the `subBatch` projection), `IREXMatching` (built, SC3), `ILaunchpad` (built, SC2), `IREXRedeem` (declared, wired at SC5), `IREXPrimary` union.
- `src/IPruvExecutor.sol` — the executor surface: `executeDeposit`/`abortDeposit` (built, SC4b),
  `executeRedeem`/`abortRedeem` (declared, wired at SC5).

## Explicitly NOT frozen (internal, provisional — in `contracts/src`)

- `libraries/State.sol` — `BatchStatus`, `EpochSide`, `Batch`, `Leg`. SC3 (matching fields) and SC5
  (redeem branch) still edit these. Never import them from a consumer.
- `REXPrimary.subBatchLeg(uint64)` — a flat-primitive diagnostic view of a batch's bridge leg (msgIds +
  return state); NOT frozen. Consumers read the stable `subBatch` / `redeemBatch` projections instead.

## Mocks (INIT-2, `mocks/`)

`MockMailbox`, `MockCollateralWarpRoute`, `MockSyntheticWarpRoute`, `MockRWAToken`, `MockNavOracle`
(settable NAV, retires the hardcoded `nav = 1e18`), `MockPruvExecutor` (home-side executor stand-in).

## TypeScript mirror (INIT-3, `ts/`)

`ts/` is the `@rex/wire` yarn workspace: `Wire.sol` types, the `Codec.sol` `encode`/`decode`, and
generated ABIs, consumed by `services/` and the dApp. Its tests assert byte-identical agreement with
the real Solidity via vectors emitted from `contracts/script/EmitCodecVectors.s.sol`.

**Scope rule:** an ABI is emitted only for a **deployed** contract (`REXPrimary`, `PruvExecutor`,
`NavOracleConsumer`) or a frozen interface that is **actually implemented** (`IREXSubscribe`,
`IREXMatching`, `IPruvExecutor`), plus the external Hyperlane interfaces. Declaration-only surface —
`IREXRedeem`'s `settleRedeemBatch`/`redeemBatch`/`previewRedeem` (SC5) and the `IREXPrimary` union's
`VERSION()` (SC6), `PruvExecutor.executeRedeem`/`abortRedeem` (SC5) — is omitted on
purpose and **asserted absent in tests**, so it cannot be built on by accident. `INavOracle` stays the
minimal read-surface REXPrimary imports and is deliberately not emitted as an ABI. `requestRedeem` and
`nav()` are now built (SC3), so they ride in `rexPrimaryAbi`; `abortDeposit` is now built (SC4b), so it
rides in `pruvExecutorAbi`. See [`ts/README.md`](ts/README.md) to regenerate.

## Not yet delivered (generate on demand)

- Mock API + OpenAPI (INIT-4) — BE2/Core-2.
