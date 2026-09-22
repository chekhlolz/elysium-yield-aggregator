# Hypeback Solidity — Test Plan (Foundry / forge-test)

**Scope.** Полный test plan для 5 non-interface контрактов из `solidity/src/`:

1. `aggregator/YieldAggregator.sol` — ERC-4626 vault с role-based allocation
2. `delegation/TradeOnlyAgent.sol` — EIP-712 trade-delegation standard
3. `keeper/RegimeDetector.sol` — read-only regime classifier
4. `legs/BasisHedgeLeg.sol`, `legs/KHYPELeg.sol`, `legs/PerpFundingLeg.sol`, `legs/SpotStakingLeg.sol` — 4 `IYieldLeg` реализации

Всё написано в Foundry idiom: `forge test`, `forge coverage`, `forge invariant`, `forge fuzz`. Цель — по этому плану можно сразу писать `.t.sol` файлы без дополнительного brainstorming.

**Контекст.** Round-2 external review findings, которые мы должны покрытe:

- **FIX-12** — `cancelPending` role-gated (owner OR keeper only), не open-to-anyone
- **FIX-14** — per-venue `maxNotional` cap в `TradeOnlyAgent.recordExecution`
- **FIX-7** — `expiresAt == 0` handling в `TradeOnlyAgent.isValidDelegation` (short-circuit "never expires")
- **Two-speed framing** — slow weight changes (timelocked `requestAllocation` → `executePending`) vs fast execution within current weights (`harvestFromAllLegs`, leg-internal perp flips)

**Конвенции test harness.** Общий набор мьюлов, за которые держит `foundry.toml`:

```toml
[profile.default]
src = "src"
test = "test"
libs = ["lib"]
solc = "0.8.26"
evm_version = "shanghai"
```

**Модули, которые мы должны написать (не часть этого плана — сам план описывает, что mock-овать):**

- `test/mocks/MockERC20.sol` — ERC-20 with `mint`, `setAllowance`, `setReturn(bool)`, `setEmptyReturn()`.
- `test/mocks/MockYieldLeg.sol` — реализация `IYieldLeg` с управляемыми `currentValue`, `expectedApy`, `allocated`, `harvested`, `reduced`, и optional callbacks для reentrancy-тестов.
- `test/mocks/MockRouter.sol` — `IERC20Router` с фиксированной rate `USDC_PER_HYPE = 1e6 * X` и настраиваемым slippage.
- `test/mocks/MockWriter.sol` — `IElysiumCoreWriter` с логируемым invocation log, настраиваемыми `open`/`close` fee и optional USDC-crediting для harvest-тестов.
- `test/mocks/MockStakingPool.sol` — `IStakingPool` с фиксированной `exchangeRate`, настраиваемым `unbondingPeriod`, и мгновенным `creditUnbonded`.
- `test/mocks/MockOracle.sol` — `IPriceOracle` с фиксированными ценами / APY, и optional revert-режим для catch-тестов.
- `test/mocks/MockFundingSource.sol` — `IFundingSource` с фиксированным signed `int64` funding rate.
- `test/mocks/MockMarketDataFeed.sol` — `IMarketDataFeed` (локальная копия из `RegimeDetector.sol`).
- `test/mocks/MaliciousLeg.sol` — `IYieldLeg` с reentrancy-колбэком на `allocateTo` / `harvest` / `reduceFrom` для reentrancy-тестов.
- `test/mocks/MaliciousRouter.sol` / `MaliciousWriter.sol` — для reentrancy-тестов legs.
- `test/utils/TestUtils.sol` — `SIGNER`, `KEEPS`, helper для EIP-712 signature construction через `vm.sign`.

**Общие правила naming / style:**

- Test functions: `snake_case`, `test_<method>_<condition>` (e.g. `test_cancelPending_revertsForNonRole`, `test_deposit_zeroDepositReverts`).
- Fuzz test functions: префикс `testFuzz_` + named parameters (`uint256 bound`).
- Invariants: префикс `invariant_` (e.g. `invariant_totalSharesConsistentWithShareBalances`).
- Setup helper: `setUp()` в базовом `TestBase.t.sol`, специфичные setup — в подклассах.
- Прогресс через `vm.warp`, `vm.prank`, `vm.expectRevert` для проверок reverting paths.
- Event assertions через `vm.expectEmit(true, false, true, false)` (indexed arg pattern: `caller, receiver, value`).

---

## Contract: `aggregator/YieldAggregator.sol`

### Mocks

- **`MockERC20`** для `asset_` (USDC stand-in).
- **`MockYieldLeg × 4`** для `_legs[0..3]` — каждый с управляемым `currentValue()`, `expectedApy()`, `allocateTo`/`reduceFrom`/`harvest` логирующими и возвращающими ожидаемое.
- **`MaliciousLeg`** для reentrancy-сценариев — колбэк на `allocateTo` / `reduceFrom` обратно в aggregator.
- **Ethereum precompile `0x00...0cafe` (ECDSA)** не нужен — но `vm.sign` в `TestUtils` для EIP-712 в TradeOnlyAgent-тестах.

### Test cases

| # | Name | Precondition | Action | Expected outcome |
|---|------|--------------|--------|------------------|
| 1 | `test_constructor_revertsWhenWeightsSumNot10000` | weights `[4000, 3000, 3000, 100]` (sum=10100) | deploy | revert with `"weights sum != 10000"` |
| 2 | `test_constructor_revertsWhenLegAddressIsZero` | `_legsParams = [0, L1, L2, L3]` | deploy | revert with `"zero leg"` |
| 3 | `test_constructor_setsInitialState` | normal inputs, weights `[2500,2500,2500,2500]` | deploy | `owner == msg.sender`, `keeper == _keeper`, `timelockSeconds == _ts`, `legsView() == [L0,L1,L2,L3]`, `pendingAllocationId == 0`, `paused == false` |
| 4 | `test_deposit_emitsShareEventAndIncreasesTotalShares` | no deposits yet, `MockYieldLeg` возвращает `currentValue=0` (bootstrap 1:1) | `vm.prank(alice); ag.deposit(1_000e6, alice)` | return `1_000e6` (1:1); `totalShares == 1_000e6`; `shares(alice) == 1_000e6`; emit `Transfer(0, alice, 1_000e6)` + `Deposit(alice, alice, 1_000e6, 1_000e6)` |
| 5 | `test_deposit_zeroAmountReverts` | any state | `ag.deposit(0, alice)` | revert with `"zero deposit"` |
| 6 | `test_deposit_fromPausedStateReverts` | `setPaused(true)` via owner | `ag.deposit(...)` | revert with `"paused"` |
| 7 | `test_deposit_nonStandardTokenWithEmptyReturnWorks` | `MockERC20` configured with `setEmptyReturn()` (safeTransferFrom returns empty data) | `ag.deposit(...)` | не revert; `totalShares` растёт |
| 8 | `test_mint_emitsDepositEventWithCorrectSharesAndAssets` | bootstrap 1:1 | `ag.mint(500e6, alice)` | return `500e6`; `totalShares == 500e6`; emit `Transfer(0, alice, 500e6)` + `Deposit(alice, alice, 500e6, 500e6)` |
| 9 | `test_mint_dustSharesReverts` | state with `totalShares > 0` и `totalAssets < 1` | `ag.mint(1, alice)` | revert with `"dust assets"` |
| 10 | `test_withdraw_selfOwner_noAllowanceRequired` | alice deposited 1000e6 | `vm.prank(alice); ag.withdraw(100e6, alice, alice)` | return `100e6` shares; `shares(alice) == 900e6`; emit `Withdraw(alice, alice, alice, 100e6, 100e6)`; alice USDC balance +100e6 |
| 11 | `test_withdraw_thirdPartyRequiresTokenAllowance` | alice deposited 1000e6, alice approves `ag` 50e6 | `vm.prank(bob); ag.withdraw(50e6, bob, alice)` | success; `alice allowance(ag, bob) == 0` (разобран до `0`) |
| 12 | `test_withdraw_thirdPartyInsufficientAllowanceReverts` | alice approves 10e6, bob запрашивает 20e6 | `vm.prank(bob); ag.withdraw(20e6, bob, alice)` | revert with `"insufficient token allowance"` |
| 13 | `test_withdraw_maxAllowanceDoesNotDecreaseAllowance` | alice approves `type(uint256).max` | `ag.withdraw(100e6, alice, alice)` | `allowance(alice, ag) == type(uint256).max` (не уменьшается) |
| 14 | `test_redeem_thirdPartyRequiresShareAllowance` | alice holds shares, alice approves `ag` for X | `vm.prank(bob); ag.redeem(X, bob, alice)` | decrement allowance; return assets |
| 15 | `test_redeem_badSharesBalanceReverts` | owner has 100 shares, запрос 200 | `ag.redeem(200, alice, alice)` | revert with `"bad shares balance"` |
| 16 | `test_requestAllocation_nonKeeperReverts` | alice не keeper | `vm.prank(alice); ag.requestAllocation(...)` | revert with `"not keeper"` |
| 17 | `test_requestAllocation_revertsWhenPendingExists` | pending allocation уже есть | keeper вызывает `requestAllocation` снова | revert with `"pending exists"` |
| 18 | `test_requestAllocation_badWeightSumReverts` | keeper, weights sum ≠ 10000 | keeper вызывает | revert with `"weights sum != 10000"` |
| 19 | `test_requestAllocation_emitsEventWithDeterministicId` | keeper, valid weights `[0, 1000, 6000, 3000]` | keeper вызывает | return `id == keccak256(abi.encodePacked(keeper, executesAt, weights, block.number))`; emit `AllocationRequested(id, weights, reason, executesAt)`; `pendingAllocationId == id` |
| 20 | `test_executePending_revertsWhenNothingPending` | no pending | `ag.executePending()` | revert with `"nothing pending"` |
| 21 | `test_executePending_revertsBeforeTimelock` | pending set, `block.timestamp < executesAt` | `ag.executePending()` | revert with `"not yet"` |
| 22 | `test_executePending_afterTimelockMovesWeightsAndTransfers` | pending set, `vm.warp(executesAt)` | `ag.executePending()` (кем угодно) | `weights() == newWeights`; `pendingAllocationId == 0`; emit `AllocationExecuted(id, newWeights)`; legs получившие новый target вызваны `allocateTo(delta)` / `reduceFrom(delta)` |
| 23 | `test_executePending_openToAnyone` | pending set, time elapsed | `vm.prank(random); ag.executePending()` | success (open after timelock, по spec §3.5) |
| 24 | `test_executePending_transfersBetweenLegs` | pending weights увеличивают leg[2], уменьшают leg[0]; `MockYieldLeg.currentValue` = allocated | execute | `MockYieldLeg[2].allocatedAlloc += delta2`; `MockYieldLeg[0].allocated -= delta0`; leg calls logged in order |
| 25 | `test_executePending_zeroWeightLegSendsZeroDelta` | pending с нулевым weight на leg | execute | leg-вызовы на нулевой вес: `newTarget=0, oldTarget>0` → `reduceFrom(oldTarget)`; если oldTarget=0 → skip |
| 26 | `test_cancelPending_beforeTimelock_ownerOk` | pending set, time < executesAt | `vm.prank(owner); ag.cancelPending(id)` | success; `pendingAllocationId == 0`; emit `AllocationCancelled(id)` |
| 27 | `test_cancelPending_beforeTimelock_keeperOk` | pending set | `vm.prank(keeper); ag.cancelPending(id)` | success |
| 28 | `test_cancelPending_revertsForRandomUser` | pending set | `vm.prank(random); ag.cancelPending(id)` | **revert with `"cancelPending: owner or keeper only"`** — FIX-12 |
| 29 | `test_cancelPending_revertsWhenNothingPending` | no pending | anyone calls `cancelPending(id)` | revert with `"nothing pending"` |
| 30 | `test_cancelPending_wrongIdReverts` | pending set with id X | `ag.cancelPending(bytes32(1))` | revert with `"wrong id"` |
| 31 | `test_harvestFromAllLegs_nonKeeperReverts` | alice not keeper | `vm.prank(alice); ag.harvestFromAllLegs()` | revert with `"not keeper"` |
| 32 | `test_harvestFromAllLegs_callsHarvestOnAllFourLegs` | keeper, legs with accrued yield | keeper calls | each `MockYieldLeg.harvest()` called once; emit `Harvested(sumCurrentValue)`; `_allocatedTotal == totalLegValue()` |
| 33 | `test_harvestFromAllLegs_fastLoopWithinCurrentWeights` | weights `[1000, 2000, 5000, 2000]`, legs accrued yield | keeper calls harvest, затем weights проверяются | `weights()` не изменены — harvest ≠ rebalance (two-speed framing) |
| 34 | `test_setPaused_ownerOnly` | alice, bob | `vm.prank(alice); ag.setPaused(true)` | revert; `vm.prank(owner)` → success; emit `PausedUpdated(true)` |
| 35 | `test_setKeeper_ownerOnlyZeroAddressReverts` | owner | `ag.setKeeper(0)` | revert with `"zero keeper"`; then `ag.setKeeper(bob)` → success; emit `KeeperUpdated(bob)` |
| 36 | `test_setTimelock_ownerOnly` | alice | `vm.prank(alice); ag.setTimelock(60)` | revert |
| 37 | `test_legAt_outOfRangeReverts` | any state | `ag.legAt(4)` | revert with `"bad leg index"` |
| 38 | `test_currentValueOfLeg_outOfRangeReverts` | same | `ag.currentValueOfLeg(4)` | revert |
| 39 | `test_currentApyBps_weightedAverage` | legs return `[1000, 2000, 5000, 6000]` bps; weights `[1000, 3000, 5000, 1000]` | call | `currentApyBps == (1000*1000 + 2000*3000 + 5000*5000 + 6000*1000) / 10000 == 3400` |
| 40 | `test_previewFunctions_matchActualReturns` | various weights/deposits | call previews + execute real | `previewDeposit(a) == deposit(a)`; `previewMint(s) == mint(s)`; `previewWithdraw(a) == withdraw(a)`; `previewRedeem(s) == redeem(s)` — ERC-4626 "no decrease" property |
| 41 | `test_convertToShares_bootstrap1to1` | `totalShares == 0` | `ag.convertToShares(12345)` | return `12345` |
| 42 | `test_convertToAssets_bootstrap1to1` | `totalShares == 0` | `ag.convertToAssets(12345)` | return `12345` |
| 43 | `test_convertToShares_afterYieldAccrual` | 1:1 bootstrap, then deposit 100e6, then leg returns +10e6 on `currentValue` | `convertToShares(10e6)` | return `= (10e6 * 100e6) / 110e6 ≈ 9.09e6` (условный рост стоимости share) |
| 44 | `test_withdraw_partialLegUnderflow_saturated` | `_allocatedTotal < delta` при executePending | execute | `_allocatedTotal == 0` (saturating), не underflow |
| 45 | `test_depositsAfterRebalanceUseNewWeights` | pending weights executed, затем deposit | `ag.deposit(...)` | leg allocations идут по новым `_weights`, не старым |
| 46 | `test_twoSpeed_slowWeightChangeThenFastHarvest` | pending set, warp, execute, then keeper harvest | full flow | `AllocationExecuted` emit → weights changed → `Harvested` emit → `_allocatedTotal` re-synced |
| 47 | `test_executePending_withdrawingFromLegsDuringRebalance` | leg returns less than `delta` requested (mock leg returns `allocated - delta + short`) | execute | не revert; `_allocatedTotal` saturates properly |
| 48 | `test_maxNotional_viaLegAllocation_indirect` | aggregator allocateTo к legs — нет прямого cap, cap в legs/TOA | deposit + rebalance | verify legs received only `delta` (не больше) — cap в каждом leg, aggregator не нарушает |

### Invariants (forge-invariant)

1. **`invariant_weightsSumTo10000`** — `uint256(sum(weights())) == 10_000` always.
2. **`invariant_totalSharesConsistentWithShareBalances`** — `totalShares == sum(shareBalances[all accounts that ever interacted])` (via `vm.getRecordedLogs` or known-address set).
3. **`invariant_previewWithdrawDoesNotIncreaseAfterWithdraw`** — `previewWithdraw(n)` монотонно не растёт после выполнения `withdraw(n)` с теми же весами.
4. **`invariant_totalAssetsNonNegative`** — `totalAssets() >= 0` (trivial, но задокументировано).
5. **`invariant_executePendingClearsPendingId`** — после любого вызова `executePending()` от любого вызывающего — `pendingAllocationId() == 0`.
6. **`invariant_allocationsDoNotExceedTotalAssets`** — `totalLegValue() <= totalAssets()` (каждый leg currentValue <= его allocation; если legs mock честный).
7. **`invariant_currentApyBpsInRange`** — `currentApyBps() <= max(legs[i].expectedApy())` (weighted avg ≤ max).
8. **`invariant_deposit_then_withdraw_returnsSameOrMoreAssets`** — если нет harvest между, `withdraw(deposit(a)) <= a` (1:1 bootstrap) — это ERC-4626 "conservative" invariant.

### Fuzz inputs

- `weights`: `uint16[4]` fuzzed, filtered так что сумма = 10_000 (или reject non-matching).
- `deposit amounts`: `[1, 1e6, 1e12, type(uint256).max/2]`.
- `timelockSeconds`: `[0, 1, 3600, 86400, uint32.max]`.
- `newShares / assets` in mint/withdraw: wide range, включая dust (1, 2, 3 wei).

### Fork tests

- **`test_fork_elysiumMainnet_fullDepositWithdrawRoundtrip`** (deferred). Форма: форк Elysium mainnet через `--fork-url`, деплой всех контрактов, интеграция через mock precompile. Требуется:
  - Elysium fork URL + chainId.
  - Precompile stub для `ElysiumCoreWriter` (т.к. predeploy ещё не shipped — test только через mock).
  - Реальная USDC 6-decimals от HyperCore.
  - Настоящий `ITradeOnlyAgent` deploy для signing test.
- **`test_fork_hypercore_99801_deploySanity`** (deferred). Форма: форк HyperCore chainId (TBD — Elysium chain IDs unpublished at launch), проверка что `block.chainid` совпадает с published Elysium chain ID и базовая deploy работает.

### Griefing vectors to test

1. **FIX-12: `cancelPending` role-gating.** Тесты 26–30 (особенно **28**). Дополнительно: adversarial keeper с compromised key — `cancelPending` от random address revert.
2. **FIX-14: per-venue `maxNotional`** — в aggregator нет прямого `maxNotional`, cap живёт в `TradeOnlyAgent.recordExecution` и `ITradeOnlyAgent.Delegation.maxNotional`. Test 48 проверяет, что allocation через legs передаёт ровно `delta`, ничего больше. Более глубоко: тесты в `TradeOnlyAgent` секции.
3. **FIX-7: `expiresAt=0` behavior** — через legs: `BasisHedgeLeg._nextDelegation` и `PerpFundingLeg._nextDelegation` задают `expiresAt: 0` — то есть **никогда не expires**. Тест 48 косвенно проверяет, что legs успешно вызывают writer; глубокие тесты в `TradeOnlyAgent`.
4. **Two-speed transitions:** Тесты 22, 33, 46, 47. Ключевое: `executePending` не трогает вес, пока timelock не истёк; `harvestFromAllLegs` не меняет вес, а только sync'ит `_allocatedTotal`.
5. **Extra griefing scenarios:**
   - **Sandwiched `executePending`**: attacker вызывает executePending перед keeper — verify `executePending` идемпотентен и open-to-anyone (по spec).
   - **`_allocatedTotal` inflation attack**: mock leg возвращает `allocateTo(amount) > amount` — verify `_allocatedTotal` не растёт сверх `totalLegValue()`.
   - **Weight manipulation via keeper compromise**: keeper с compromised key запрашивает 100% в один leg → timelock даёт owner окно для `setPaused(true)` + `setKeeper`.

### Reentrancy scenarios

- **`executePending` → `legs[i].reduceFrom` → callback into `ag`** — `MaliciousLeg.reduceFrom` вызывает `ag.deposit(1e6, victim)` во время `executePending`. Проверить что `executePending` не подчиняется reentrancy (сейчас **нет** `nonReentrant` guard — это **найденная уязвимость**, см. "Surprises").
- **`harvestFromAllLegs` → `legs[i].harvest` → callback** — `MaliciousLeg.harvest` вызывает `ag.withdraw(1, msg.sender, victim)`. Аналогично.
- **`deposit` → `asset_.transferFrom` → callback** — malicious ERC20 token. SafeERC20 использует raw call и проверяет return, так что callback от token в `deposit` возможен, но требует `transferFrom` от token — проверяем через `MaliciousERC20.transferFrom → ag.deposit(...)`.

---

## Contract: `delegation/TradeOnlyAgent.sol`

### Mocks

- **Nикаких external mocks** — контракт самодостаточен. Только EVM primitives (`vm.sign` для EIP-712 signatures).
- **`TestUtils.sol`** — helper `_computeDigest` и `_sign` для EIP-712.

### Test cases

| # | Name | Precondition | Action | Expected outcome |
|---|------|--------------|--------|------------------|
| 1 | `test_isValidDelegation_zeroKeeperReverts` | any | `d.keeper == 0` | return `false` |
| 2 | `test_isValidDelegation_zeroMaxNotionalReturnsFalse` | `d.maxNotional == 0` | `isValidDelegation(...)` | return `false` — FIX-14 (zero cap invalid) |
| 3 | `test_isValidDelegation_zeroMaxPerOrderReturnsFalse` | `d.maxPerOrder == 0` | call | return `false` |
| 4 | `test_isValidDelegation_expiresAtZeroNeverExpires` | `d.expiresAt == 0`, valid sig | call at `block.timestamp + 1000000` | **return `true`** — FIX-7 (sentinel "never expires") |
| 5 | `test_isValidDelegation_expiresAtNonZeroBeforeExpiration` | `d.expiresAt == now + 1000`, valid sig | call now | return `true` |
| 6 | `test_isValidDelegation_expiresAtNonZeroAfterExpiration` | `d.expiresAt == now - 10`, valid sig | `vm.warp(now+1); isValidDelegation` | return `false` |
| 7 | `test_isValidDelegation_expiresAtBoundaryExactlyNow` | `d.expiresAt == now` | call | return `true` (условие `> expiresAt`, не `>=`) |
| 8 | `test_isValidDelegation_revokedReturnsFalse` | delegated to K, `revoke(K)`, valid sig | `isValidDelegation(d(keeper=K))` | return `false` |
| 9 | `test_isValidDelegation_validSignatureAccepted` | sig from `from` via `vm.sign` | call | return `true` |
| 10 | `test_isValidDelegation_wrongSignerReverts` | sig from wrong address | call | return `false` (ecrecover mismatch) |
| 11 | `test_isValidDelegation_badVValueReverts` | `sig.v = 26` or `29` | call | revert with `"bad v"` |
| 12 | `test_isValidDelegation_saltAndNoncePartOfDigest` | d с разными salt/nonce | call | подписанная delegation on salt1 не проходит для salt2 |
| 13 | `test_isValidDelegation_assetIdsEncodedIntoDigest` | `assetIds = [1,2]` vs `[1,3]` | call | разные digest, разные sig |
| 14 | `test_isValidDelegation_emptyAssetIdsMeantAllAssets` | `assetIds = []` | call with valid sig | return `true` (empty = all assets по spec) |
| 15 | `test_revoke_zeroAddressReverts` | any | `revoke(0)` | revert with `"zero keeper"` |
| 16 | `test_revoke_emitsRevokedEvent` | any | `revoke(K)` | emit `Revoked(msg.sender, K)` |
| 17 | `test_revoke_multipleKeepersIndependent` | `revoke(K1)`, `revoke(K2)` | check | `isRevoked(K1)` true, `isRevoked(K2)` true, `isRevoked(K3)` false |
| 18 | `test_isRevoked_checksCallerContext` | alice `revoke(K)`, bob проверяет | `vm.prank(bob); isRevoked(K)` | false (revocation per `(delegator, keeper)` key) |
| 19 | `test_recordExecution_notVenueReverts` | alice не venue | `ag.recordExecution(...)` | revert with `"not venue"` |
| 20 | `test_recordExecution_venueCallsFirstTimeInitializesCap` | venue calls first time | call | `delegationCap[key] == d.maxNotional`; emit `TradeExecuted(...)`; return `true` |
| 21 | `test_recordExecution_withinCapAccepted` | `d.maxNotional = 100e6`, executed 40e6 | call with 50e6 | return `true`; `usedNotional = 90e6` |
| 22 | `test_recordExecution_overCapRejected` | executed 80e6 | call with 30e6 | **return `false`** (не revert!) — FIX-14 (per-venue cap) |
| 23 | `test_recordExecution_exactlyAtCapAccepted` | executed 50e6 | call with 50e6 | return `true`; `used == cap` |
| 24 | `test_recordExecution_overCapByOneWeiRejected` | executed cap - 1 | call with 2 | return `false` |
| 25 | `test_recordExecution_venueLocalKeys` | venue1 calls, venue2 calls с тем же d | both succeed | keys независимы: `usedNotional[venue1] != usedNotional[venue2]` — это per-venue cap, не cross-venue (спецификация §9) |
| 26 | `test_recordExecution_differentNonceDifferentKey` | same venue/delegator/keeper, different nonce | both succeed | разные `bytes32` keys — nonce part of key |
| 27 | `test_recordExecution_zeroNotionalAcceptedTrivially` | cap 100 | call with 0 | return `true`, `used == 0` (edge case: 0+0 <= 100) |
| 28 | `test_remainingNotional_zeroCapReturnsZero` | `d.maxNotional == 0` | call | return `0` (cap=0, used=0) |
| 29 | `test_remainingNotional_underCapReturnsRemaining` | cap 100, used 40 | call | return `60` |
| 30 | `test_remainingNotional_overCapReturnsZero` | used 120, cap 100 | call | return `0` (saturating) |
| 31 | `test_recordExecution_doesNotOverwriteExistingCap` | `delegationCap[key]` set once | call again с другим `d.maxNotional` | cap остаётся original, `used + notional > orig_cap` — FIX-14 (first-write wins) |
| 32 | `test_revoke_doesNotBlockAlreadyExpired` | `revoke(K)`, then delegation expires | `isValidDelegation(d expired)` | return `false` из-за expiry (не revoke) — приоритет expiry-check over revoke-check |
| 33 | `test_domainSeparator_chainIdSensitivity` | deploy on chainId 1 vs Elysium-mainnet-chainId (TBD, fork) | compute digest | different digest → cross-chain signature reuse не работает |
| 34 | `test_domainSeparator_contractAddressSensitivity` | different TOA contracts | compute digest | different domainSeparator |
| 35 | `test_typeHashStableAcrossSolidityVersions` | compute constant | hash | `keccak256("Delegation(address keeper,uint256[] assetIds,uint256 maxNotional,uint256 maxPerOrder,uint64 expiresAt,uint64 nonce,bytes32 salt)")` — pinned literal в коде |

### Invariants

1. **`invariant_remainingNotionalNeverNegative`** — `remainingNotional(v, d, k) <= d.maxNotional` и `>= 0`.
2. **`invariant_recordExecutionOverCapRejects`** — после `used + notional > cap` → `accepted == false`.
3. **`invariant_revoke_isPermitDelegator`** — `revoke` не влияет на другие delegators с тем же keeper.
4. **`invariant_expiresAtZero_isNeverExpiring`** — `isValidDelegation(d.expiresAt == 0, ...)` true вне зависимости от `block.timestamp`.

### Fuzz inputs

- `d.maxNotional`: `[0, 1, 1e6, 1e18, type(uint256).max]`.
- `d.maxPerOrder`: `[0, 1, 1e6, 1e18]`.
- `d.expiresAt`: `[0, 1, uint64(block.timestamp), uint64.max]`.
- `d.nonce`: wide uint64 range.
- `d.salt`: `bytes32.random()`.
- `d.keeper`: `[address(0), random address, known keeper]`.
- `notional` in `recordExecution`: from 0 up to `cap + 100`.
- Sequence of `recordExecution` calls: `used + 1`, `used + notional == cap`, `used + notional > cap`.

### Fork tests

- **`test_fork_chainId99801_domainSeparator`** (deferred). Форма: форк Elysium mainnet (chainId TBD), deploy TradeOnlyAgent, проверка что `domainSeparator()` включает Elysium mainnet chainId. Ключевой cross-chain protection.
- **`test_fork_chainIdCrossReuse_rejected`** (deferred). Форма: signature, подписанная на chainId 1, отклоняется на Elysium mainnet chainId (TBD).

### Griefing vectors to test

1. **FIX-7 (expiresAt == 0 short-circuit):** Тесты 4, 5, 6, 7, 32. Ключевой: sentinel `0` — единственный случай, когда `isValidDelegation` возвращает `true` до revocation/sig check.
2. **FIX-14 (maxNotional per-venue):** Тесты 20–24, 31. Ключевой: cap first-write wins — venue не может повторно увеличить cap подставив `d.maxNotional = bigger`.
3. **`maxPerOrder` vs `maxNotional`:** Тесты 2, 3, 22. `maxPerOrder` не проверяется в `recordExecution` — только `maxNotional` агрегируется. Это intentional: venue сам проверяет `maxPerOrder` (см. spec §9). Тест должен зафиксировать это поведение.
4. **Revocation griefing:** Тесты 8, 17, 32. После `revoke(K)`, keeper больше не проходит `isValidDelegation` для новых delegations, но уже принятые venue-м (через `recordExecution`) не отменяются.
5. **Salt/nonce replay:** Тест 12. Одна и та же signature не может быть replayed с другим salt — digest включает salt и nonce.
6. **Non-venue caller:** Тест 19. `msg.sender == venue` check блокирует случайные calls.

### Reentrancy

TradeOnlyAgent не имеет external calls к другим контрактам — все calls чистые (`external view`/`external`) или state-modifying но без внешних `call`. `recordExecution` и `revoke` не вызывают внешних контрактов, так что **reentrancy здесь отсутствует**. Достаточно unit-тестов.

---

## Contract: `keeper/RegimeDetector.sol`

### Mocks

- **`MockMarketDataFeed`** — реализация `IMarketDataFeed` (интерфейс объявлен inline в `RegimeDetector.sol`), с настраиваемыми:
  - `fundingRateBps(string coin)` → `int64`
  - `realizedVolBps(string coin, uint32 hours)` → `uint256`
  - `spotPrice(string coin)` → `uint256`
  - `perpMarkPrice(string coin)` → `uint256`

### Test cases

| # | Name | Precondition | Action | Expected outcome |
|---|------|--------------|--------|------------------|
| 1 | `test_constructor_setsDefaultThresholds` | normal | deploy | `thresholds.strongApyBps == 800`, `weakApyBps == 300`, `highVolBps == 9000` |
| 2 | `test_setThresholds_anyoneCanCall` | any | `vm.prank(random); rd.setThresholds(T{200, 100, 8000})` | **success** — **surprise: нет ownership guard** (см. "Surprises") |
| 3 | `test_setThresholds_persists` | set new thresholds | observe | новые thresholds применяются |
| 4 | `test_observe_fundingStrong_regime0` | mock feed: fundingRateBps = 1 bps/hr (annual 8760 bps ≈ 87.6%) | `rd.observe()` | `lastSnapshot.regime == 0` (FUNDING_STRONG); emit `RegimeUpdated(0, 8760, ts)` |
| 5 | `test_observe_fundingWeak_betweenThresholds` | funding=0.05 bps/hr → ~438 bps annual | observe | regime == 1 (FUNDING_WEAK) |
| 6 | `test_observe_fundingNegative` | funding=-0.1 bps/hr | observe | regime == 2 (FUNDING_NEG); `fundingApyBps_24h == 876` (abs) |
| 7 | `test_observe_highVolOverwritesOtherRegimes` | high vol 9500 bps, funding=1 bps/hr | observe | regime == 3 (HIGH_VOL), не FUNDING_STRONG (priorities) |
| 8 | `test_observe_noEmitWhenRegimeUnchanged` | observe twice с одинаковым input | observe | emit только при смене; second time — нет emit |
| 9 | `test_observe_emitsOnRegimeChange` | regime 1 → 0 | observe | emit `RegimeUpdated(0, ...)` |
| 10 | `test_observe_spotPriceZero_handlesGracefully` | spotPrice == 0 | observe | `basisBps == 0` (guarded), no division by zero |
| 11 | `test_observe_perpMarkBelowSpot_negativeBasis` | perp=100, spot=120 | observe | `basisBps == (100-120)*10000/120 == -1666` (signed) |
| 12 | `test_current_returnsLastSnapshot` | observe once | `current()` | returns last snapshot |
| 13 | `test_current_returnsDefaultZeroIfNoObserve` | never observe | `current()` | `RegimeSnapshot{regime=0, fundingApyBps_24h=0, ..., observedAt=0}` |
| 14 | `test_computeRegime_highVolFirst` | vol=9500, apySigned=1000 | `computeRegime(1000, 9500)` | return `3` (HIGH_VOL) |
| 15 | `test_computeRegime_negativeApy` | apySigned=-100 | `computeRegime(-100, 100)` | return `2` (FUNDING_NEG) |
| 16 | `test_computeRegime_zeroApyFallsToWeak` | apySigned=0 | `computeRegime(0, 100)` | return `1` (FUNDING_WEAK — default) |
| 17 | `test_computeRegime_strongAbove800` | apySigned=801 | call | return `0` |
| 18 | `test_computeRegime_weakBetween300And800` | apySigned=400 | call | return `1` |
| 19 | `test_computeRegime_below300_stillWeak` | apySigned=100 | call | return `1` (default, по коду — последний return) |
| 20 | `test_weightsForRegime_strong` | any | `weightsForRegime(0)` | `[0, 1000, 6000, 3000]` — sum=10000 |
| 21 | `test_weightsForRegime_weak` | any | `weightsForRegime(1)` | `[2000, 2000, 4000, 2000]` — sum=10000 |
| 22 | `test_weightsForRegime_negative` | any | `weightsForRegime(2)` | `[4000, 6000, 0, 0]` — sum=10000 |
| 23 | `test_weightsForRegime_highVol` | any | `weightsForRegime(3)` | `[5000, 5000, 0, 0]` — sum=10000 |
| 24 | `test_weightsForRegime_unknownRegimeId_fallback` | regime=255 | call | returns `[5000, 5000, 0, 0]` (default branch) |
| 25 | `test_weightsForRegime_allSumsTo10000` | each regime | call | assert `sum(weights) == 10000` (invariant) |
| 26 | `test_observe_apyBpsOversizedFundingDoesNotOverflow` | funding = int64.max/8760 | observe | no overflow; apy ≈ int64.max (bounded) |
| 27 | `test_observe_negativeApyAbsValueStoredCorrectly` | funding=-1 bps/hr → apy=-8760 | observe | `fundingApyBps_24h == 8760` (abs, uint256) |
| 28 | `test_observe_observedAtTimestamp` | block.timestamp = T | observe | `lastSnapshot.observedAt == T` |
| 29 | `test_thresholds_sensitivityBoundary` | apy=799 vs 800 | call | 799 → WEAK, 800 → STRONG (inclusive `>=`) |
| 30 | `test_thresholds_volBoundary` | vol=8999 vs 9000 | call | 8999 → не HIGH_VOL, 9000 → HIGH_VOL |

### Invariants

1. **`invariant_weightsForRegimeAlwaysSumTo10000`** — for any `uint8 regime`, `sum(weightsForRegime(regime)) == 10_000`.
2. **`invariant_lastSnapshotObservedAtMonotonic`** — `lastSnapshot.observedAt` never decreases (each `observe()` writes `block.timestamp`).
3. **`invariant_regimeClassification_isTotalFunction`** — for any `(apySigned, volBps)` pair, `computeRegime` returns a valid `uint8` in `[0..3]`.
4. **`invariant_regimePriorities`** — HIGH_VOL > FUNDING_NEG > FUNDING_STRONG > FUNDING_WEAK (priority chain).

### Fuzz inputs

- `apySigned`: `-type(int64).max..type(int64).max`.
- `volBps`: `0..1e12` (wide uint256 range, но bounded разумно).
- `spotPrice`: `0, 1, 1e6, 1e12, type(uint256).max`.
- `perpMarkPrice`: same.
- Sequence of `observe()` calls with varying inputs.

### Fork tests

- **`test_fork_elysiumMarketDataPrecompile`** (deferred). Форма: форк Elysium mainnet с реальным market-data precompile (после +4 weeks post-mainnet). Проверяет что:
  - `feed.fundingRateBps("HYPE")` возвращает sensible value.
  - `feed.realizedVolBps("HYPE", 24)` returns sensible value.
  - `observe()` на реальных данных даёт разумный regime.
- **`test_fork_precompileNotYetShipped_usesMockFallback`** (deferred). Форма: пока precompile не shipped, deploy с mock feed — проверяем что contract всё ещё работает.

### Griefing vectors to test

RegimeDetector read-only, не управляющий средствами. Griefing vectors:

1. **Threshold manipulation (unauthorized):** Тест 2. `setThresholds` **open to anyone** (TODO ownership). Attacker может установить `strongApyBps = 0`, и любой funding > 0 будет классифицироваться как FUNDING_STRONG → 60% perp funding / 30% basis hedge — потенциальный grief для keeper strategy. **Это surprise finding** — нужно зафиксировать как known issue.
2. **Market-data feed manipulation:** злой feed может возвращать экстремальные значения. Тест 26 проверяет что contract gracefully обрабатывает overflow-safety.
3. **Stale-data attack:** если feed всегда возвращает устаревшие значения, regime "застревает" в неверном состоянии. Нет freshness check — только `observedAt` timestamp, без staleness detection. Test фиксирует текущее поведение.

### Reentrancy

RegimeDetector не имеет external calls, кроме `feed.*` (view). **Reentrancy не применяется.** Если feed станет mutating, это отдельная история.

---

## Contract: `legs/BasisHedgeLeg.sol`

### Mocks

- **`MockERC20 (usdc, hype)`** — базовый ERC-20.
- **`MockRouter`** — реализация `IERC20Router` с фиксированным rate `1 HYPE = 1 USDC` (или настраиваемым slippage).
- **`MockWriter`** — реализация `IElysiumCoreWriter` с логируемым invocation log.
- **`MockTradeOnlyAgent`** — реализация `ITradeOnlyAgent` с упрощённой verification.
- **`MockOracle`** — `IPriceOracle` с `priceOf("HYPE") == 1e6` ($1.00).

### Test cases

| # | Name | Precondition | Action | Expected outcome |
|---|------|--------------|--------|------------------|
| 1 | `test_constructor_storesImmutables` | normal | deploy | `owner == msg.sender`, `usdc`, `hype`, `router`, `writer`, `tradeOnlyAgent`, `oracle`, `delegator` = args; `latestApyBps == fixedApyBps` |
| 2 | `test_name_returnsConstant` | any | `name()` | return `"BasisHedgeLeg"` |
| 3 | `test_allocateTo_nonOwnerReverts` | alice not owner | `vm.prank(alice); leg.allocateTo(100e6)` | revert with `"not owner"` |
| 4 | `test_allocateTo_zeroAmountReverts` | owner | `leg.allocateTo(0)` | revert with `"zero"` |
| 5 | `test_allocateTo_splitsHalfSpotHalfPerp` | 100e6 USDC | `leg.allocateTo(100e6)` | router.call(50e6, hype), writer.openPosition(Short, 50e6); `spotHypeBalance > 0`, `perpNotional == 50e6`, `allocatedUsd == 100e6`; emit `Allocated(100e6, 100e6)`; return `100e6` |
| 6 | `test_allocateTo_oneWeiEdgeCase` | owner, amount=1 | `leg.allocateTo(1)` | spotPortion=0 → set to 1; perpPortion=1 → 1>1 false → perpPortion=1; итог: оба portion = 1, **двойное использование** (см. Surprises) |
| 7 | `test_allocateTo_emitsEventWithAccumulatedTotal` | allocate 100e6, then 200e6 | 2nd call | emit `Allocated(200e6, 300e6)` — accumulated |
| 8 | `test_allocateTo_usesDelegationWithNonZeroNonce` | allocate once | inspect `MockWriter.log` | `d.nonce >= 1`, `d.assetIds == [1]` (HYPE_ASSET_ID), `d.keeper == address(leg)`, `d.maxNotional == perpPortion`, `d.maxPerOrder == perpPortion`, `d.expiresAt == 0` |
| 9 | `test_allocateTo_usesZeroSig` | allocate | inspect writer | `sig == Signature(27, 0, 0)` — **surprise: нулевой sig**, production TOA отклонит (см. Surprises) |
| 10 | `test_currentValue_spotPlusUsdc` | allocate 100e6 (HYPE=1 USDC, USDC=50e6 on-hand) | call | return `spotVal + 50e6` = 100e6 |
| 11 | `test_currentValue_zeroBalanceReturnsUsdcOnly` | no allocate, usdc=0 | call | return `0` |
| 12 | `test_currentValue_perpNotionalDoesNotAddDirectly` | perpNotional=50e6, spotVal=50e6, usdc=0 | call | return `50e6` (только spot + usdc, perp PnL через usdc balance) |
| 13 | `test_harvest_nonOwnerReverts` | alice | `vm.prank(alice); leg.harvest()` | revert |
| 14 | `test_harvest_withNoPositionDoesNothing` | perpNotional=0 | `leg.harvest()` | no writer call; no USDC transfer; no emit |
| 15 | `test_harvest_flipsPositionAndSweepsUsdc` | perpNotional=50e6, writer mock credits 10e6 USDC on close | `leg.harvest()` | writer.closePosition + writer.openPosition (flip); `realisedBasisPnl += 10e6`; USDC transfer to owner; `allocatedUsd -= 10e6`; emit `Harvested(10e6)` |
| 16 | `test_harvest_reducesAllocatedUsdOnRealizedYield` | perpNotional=50e6, realised=10e6 | harvest | `allocatedUsd` = 100e6 - 10e6 = 90e6 (см. Surprises: allocatedUsd semantics) |
| 17 | `test_harvest_noEmitWhenNoRealisedYield` | perpNotional>0 but writer returns 0 USDC | harvest | no `Harvested` emit, но `Allocated` history записывается |
| 18 | `test_reduceFrom_nonOwnerReverts` | alice | `vm.prank(alice); leg.reduceFrom(50e6)` | revert |
| 19 | `test_reduceFrom_zeroReverts` | owner | `leg.reduceFrom(0)` | revert with `"zero"` |
| 20 | `test_reduceFrom_overReduceReverts` | allocatedUsd=100e6 | `leg.reduceFrom(200e6)` | revert with `"overreduce"` |
| 21 | `test_reduceFrom_exactAllocated` | allocated=100e6 | `leg.reduceFrom(100e6)` | success; `allocatedUsd == 0`; perp closed pro-rata; spot sold |
| 22 | `test_reduceFrom_proRataCutsPerpAndSpot` | allocated=100e6, perp=50e6, spot=50 HYPE, reduce 20e6 | reduceFrom(20e6) | perpCut = 10e6 (pro-rata); hypeCut = 10 HYPE; `perpNotional -= 10e6`, `spotHypeBalance -= 10` |
| 23 | `test_reduceFrom_transfersReturnedUsdcToOwner` | reduce 50e6 | reduce | USDC transfer to owner (aggregator); `returnedUsd == usdc balance` |
| 24 | `test_reduceFrom_emitsEventWithRemainder` | allocated=100e6 | reduce 40e6 | emit `Reduced(40e6, 60e6)` |
| 25 | `test_setFixedApyBps_nonOwnerReverts` | alice | revert |
| 26 | `test_setFixedApyBps_ownerUpdates` | owner | `leg.setFixedApyBps(1500)` | `fixedApyBps == 1500`, **но `latestApyBps` не обновляется** до следующего `_recordApy` (см. Surprises) |
| 27 | `test_bumpNonce_nonOwnerReverts` | alice | revert |
| 28 | `test_bumpNonce_ownerIncrements` | owner, lastNonce=5 | `leg.bumpNonce()` | `lastDelegationNonce == 6` |
| 29 | `test_expectedApy_returnsLatestApyBps` | fixedApyBps=1200 | call | return `1200` |
| 30 | `test_apyHistory_circularBufferOverflow` | call `_recordApy` 20 раз (через allocate × 20) | inspect `history.length == 16`, последние 16 значений сохранены, старые сдвинуты влево |
| 31 | `test_apyHistory_readReturnsValues` | 5 observations | call | length 5, values по порядку oldest→newest |
| 32 | `test_allocateTo_oracleRevertStillProceeds` | oracle reverted | allocate | currentValue == 0 (spot price=0 → spotVal=0), но allocation всё равно происходит (см. Surprises: oracle failure не блокирует allocate) |
| 33 | `test_allocateTo_routerZeroAddress_fallbackPath` | router == address(0) | allocate | `_buyHype` возвращает `hype.balanceOf(this)` — в тестах pre-load HYPE balance |
| 34 | `test_allocateTo_writerRevert_cascadesToAllocateTo` | writer mock reverted | allocate | whole allocateTo revert, USDC не возвращён (см. Surprises: нет try/catch на writer) |

### Invariants

1. **`invariant_allocatedUsdNeverNegative`** — `allocatedUsd >= 0` (saturating subtraction в коде).
2. **`invariant_apyHistoryLengthNeverExceeds16`** — `history.length <= MAX_HISTORY == 16`.
3. **`invariant_perpNotionalLessThanOrEqualToAllocatedUsd`** — `perpNotional <= allocatedUsd` (после каждого allocate/harvest/reduce).
4. **`invariant_spotHypeValuePlusUsdcApproxAllocatedUsd`** — currentValue ≈ allocatedUsd (с учётом yield accrual).
5. **`invariant_hypeOutOnBuyIsNonZero`** — когда router != 0, `hype.balanceOf(this)` после allocate возрастает.

### Fuzz inputs

- `amount`: `[1, 1e6, 1e9, 1e12, 1e18]` (все вплоть до type(uint256).max / 100).
- Sequence of `allocateTo` + `reduceFrom` + `harvest`.
- Router rate: `0, 1, 1e6, 1e9, 1e12` HYPE per USDC.

### Fork tests

- **`test_fork_elysiumCoreWriter_realPredeploy`** (deferred). Форма: форк Elysium mainnet с реальным `ElysiumCoreWriter` predeploy. Проверяет:
  - `writer.openPosition(HYPE_ASSET_ID, Short, ...)` не revert на in-range params.
  - `writer.closePosition(...)` возвращает USDC на close.
  - Signatures проверяются venue-side.
- **`test_fork_hypercore_hypePriceFeeder`** (deferred). Форма: форк HyperCore (chainId TBD — Elysium mainnet ID published at launch) для проверки `oracle.priceOf("HYPE")`.

### Griefing vectors

1. **`maxNotional` edge cases (FIX-14 через legs):** Тест 8 проверяет что `_nextDelegation` корректно задаёт `d.maxNotional == perpPortion` и `d.maxPerOrder == perpPortion`. Venue-side проверит against `delegationCap[key]` в TOA. Если `writer` mock вернёт success, но cap в TOA будет меньше, TOA отклонит — test на уровне TOA.
2. **`expiresAt == 0` in legs (FIX-7):** Тесты 8, 9. Legs всегда задают `d.expiresAt == 0` — то есть never-expiring delegation. Это intentional по текущему дизайну (leg держит perpetual permission from delegator), но требует `delegator` подписать именно так. Production flow — future work с `submitIntent(delegation, sig, ...)`.
3. **Two-speed transitions в legs:** legs не делают weight changes (только allocator через aggregator), но `harvest()` внутри legs соответствует "fast execution" part of two-speed framing. Тесты 15, 16, 17 проверяют что harvest не трогает weights.
4. **Writer griefing:** malicious writer может вернуть success, но не выполнять trade. Leg доверяет writer — нет reconciliation.
5. **Delegator revocation:** delegator может `revoke(keeper=leg)` в TOA. Тогда `writer.openPosition` должно быть отклонено (venue-side check). Leg не проверяет это — venue-side ответственность.

### Reentrancy

**CRITICAL**: `allocateTo`, `harvest`, `reduceFrom` все делают external calls на `router.swapExact*` и `writer.openPosition/closePosition`. **Нет reentrancy guard.** Scenarios:

1. **Router reenters into `allocateTo`:** `MaliciousRouter.swapExactUSDCForToken` → callback `leg.allocateTo(1e6)` внутри `allocateTo(100e6)`. Проверить что state transitions последовательны и `allocatedUsd` корректно накапливается (сейчас — потенциальная проблема).
2. **Writer reenters into `harvest`:** `MaliciousWriter.closePosition` → callback `leg.harvest()` — infinite recursion до stack depth. Нужно `nonReentrant` modifier на `allocateTo`, `harvest`, `reduceFrom`.
3. **Cross-call reentrancy:** `MaliciousRouter.swapExactTokenForUSDC` (внутри `reduceFrom`) → callback `leg.allocateTo(...)`. Проверить что `allocatedUsd` не gets corrupted.

**Все три сценария должны зафиксировать текущее поведение (уязвимость)** — тесты, которые **fail** при отсутствии `nonReentrant` guard.

---

## Contract: `legs/KHYPELeg.sol`

### Mocks

- **`MockERC20 (usdc, hype)`**
- **`MockRouter`** — IERC20Router с фиксированным rate.
- **`MockStakingPool`** — IStakingPool с фиксированной `exchangeRate = 1e18` (1:1 initially), настраиваемым `unbondingPeriod`, мгновенным `creditUnbonded`.
- **`MockOracle`** — `IPriceOracle` с `priceOf("HYPE") == 1e6` и `getApy("kHYPE") == 3000`.

### Test cases

| # | Name | Precondition | Action | Expected outcome |
|---|------|--------------|--------|------------------|
| 1 | `test_constructor_storesImmutables` | normal | deploy | all immutables set correctly |
| 2 | `test_name_returnsConstant` | any | `name()` | return `"KHYPELeg"` |
| 3 | `test_allocateTo_nonOwnerReverts` | alice | revert |
| 4 | `test_allocateTo_zeroReverts` | owner | `leg.allocateTo(0)` revert |
| 5 | `test_allocateTo_swapsUsdcToHypeThenStakes` | 100e6 USDC | `leg.allocateTo(100e6)` | router.call(100e6) → 100 HYPE; pool.stake(100) → kHYPE balance; `khypeBalance += 100`, `allocatedUsd == 100e6`; emit `Allocated(100e6, 100e6)` |
| 6 | `test_allocateTo_accumulatesAcrossCalls` | allocate twice | second call | `allocatedUsd == sum`, `khypeBalance == sum` |
| 7 | `test_allocateTo_emitsEventWithAccumulatedTotal` | same | same | emit `Allocated(amount, totalAllocated)` |
| 8 | `test_harvest_nonOwnerReverts` | alice | revert |
| 9 | `test_harvest_noUsdcOnHand_noEmit` | harvest без USDC balance | call | no `Harvested` emit; `allocatedUsd` не меняется |
| 10 | `test_harvest_withUsdcOnHand_sweepsToOwner` | manually mint USDC to leg | `leg.harvest()` | USDC transfer to owner; `allocatedUsd -= u`; emit `Harvested(u)` |
| 11 | `test_harvest_recordsApyInHistory` | harvest twice | inspect history | `history` растёт |
| 12 | `test_reduceFrom_nonOwnerReverts` | alice | revert |
| 13 | `test_reduceFrom_zeroReverts` | owner | `leg.reduceFrom(0)` revert |
| 14 | `test_reduceFrom_badAmountKhypeBalanceLessThanAmountReverts` | khypeBalance=50, amount=100e6 | `leg.reduceFrom(100e6)` | **revert with `"bad amount"`** — **unit mismatch**: khypeBalance в HYPE-stake tokens, amount в USDC (см. Surprises) |
| 15 | `test_reduceFrom_zeroUnbondingPeriod_immediateCredit` | khypeBalance=100, unbondingPeriod=0 | `leg.reduceFrom(50)` | pool.unstake + pool.creditUnbonded; USDC returned to owner; `khypeBalance -= 50`, `allocatedUsd -= 50` |
| 16 | `test_reduceFrom_nonZeroUnbondingPeriod_defersCredit` | khypeBalance=100, unbondingPeriod=24h | `leg.reduceFrom(50)` | pool.unstake вызван; **creditUnbonded не вызван**; `khypeBalance -= 50`, `allocatedUsd -= 50`, `returnedUsd == 0`; emit `Reduced(50, ...)` |
| 17 | `test_claimPending_zeroAmountReturnsEarly` | owner | `leg.claimPending(0)` | no pool call |
| 18 | `test_claimPending_nonZero_callsCreditUnbonded` | owner, unbonded amount ready | `leg.claimPending(50)` | pool.creditUnbonded; USDC transfer to owner; **не emit ни что** (no Reduced event — см. Surprises) |
| 19 | `test_setFixedApyBps_nonOwnerReverts` | alice | revert |
| 20 | `test_setFixedApyBps_ownerUpdates` | owner | `leg.setFixedApyBps(1500)` | `fixedApyBps == 1500`, `latestApyBps` не обновляется до следующего `_recordApy` |
| 21 | `test_expectedApy_returnsOracleValueWhenAvailable` | oracle returns 3000 | call | return `3000` |
| 22 | `test_expectedApy_fallbackToLatestApyBpsWhenOracleFails` | oracle reverts | call | return `latestApyBps` |
| 23 | `test_expectedApy_zeroOracle_fallback` | oracle == address(0) | call | return `latestApyBps` |
| 24 | `test_currentValue_zeroKhypeBalanceReturnsUsdcOnly` | khype=0, usdc=0 | call | return `0` |
| 25 | `test_currentValue_khypeBalanceCalculation` | khype=100, rate=1e18, price=1e6 | call | `hypeEq = (100 * 1e18) / 1e18 = 100`; `value = (100 * 1e6) / 1e6 = 100` (в USDC) |
| 26 | `test_currentValue_includesUsdcBalance` | khype=100, usdc=50 | call | return `100 + 50 == 150` |
| 27 | `test_currentValue_oracleFails_returnsOnlyUsdc` | oracle reverted | call | `price == 0` → `v == 0` (spot part), + usdc |
| 28 | `test_apyHistory_lengthBoundedAt16` | 20 records | inspect | length == 16, старейшие сдвинуты |
| 29 | `test_allocateTo_routerRevert_cascades` | router reverted | allocate | whole allocateTo revert |
| 30 | `test_reduceFrom_claimPendingAfterUnbond` | allocate, reduce with unbond, warp, claimPending | full flow | USDC returned only after `claimPending` |

### Invariants

1. **`invariant_allocatedUsdNonNegative`** — `allocatedUsd >= 0`.
2. **`invariant_khypeBalanceNeverNegative`** — `khypeBalance >= 0`.
3. **`invariant_apyHistoryBounded`** — `history.length <= 16`.
4. **`invariant_currentValueApproxAllocatedUsd`** — currentValue ≈ allocatedUsd (с учётом yield).
5. **`invariant_reduceFromDecreasesKhypeBalance`** — после reduce, `khypeBalance <` было до.

### Fuzz inputs

- `amount`: `[1, 1e6, 1e12]`.
- `unbondingPeriod`: `[0, 1, 24*3600, 9*24*3600, type(uint256).max]`.
- `exchangeRate`: `[0, 1e18, 2e18, 1e24]`.
- `price`: `[0, 1e6, 1e9]`.
- Sequence of allocate → harvest → reduce → claimPending.

### Fork tests

- **`test_fork_hypercore_khypePool`** (deferred). Форма: форк HyperCore (chainId TBD) с реальным kHYPE pool от Liminal. Проверяет:
  - `pool.exchangeRate()` reasonable value (1e18 or higher).
  - `pool.stake(HYPE, 100)` работает.
  - `pool.unstake(kHYPE, 100)` schedule unbonding.
  - `pool.unbondingPeriod()` — real value (обычно 24h).

### Griefing vectors

1. **Unbonding period griefing:** если pool's `unbondingPeriod` меняется между allocate и reduce, `reduceFrom` может вернуть 0 USDC. Test фиксирует текущее поведение (test 16).
2. **Router slippage:** фиксированный slippage=0 (по spec "TODO"). Test фиксирует текущее поведение.
3. **Exchange rate manipulation:** если `pool.exchangeRate()` растёт между allocate и currentValue, currentValue растёт — это intentional (yield accrual). Если падает — currentValue падает — это "depeg risk". Test проверяет корректность расчёта при любом rate.

### Reentrancy

**CRITICAL**: `allocateTo`, `harvest`, `reduceFrom`, `claimPending` — все имеют external calls (router, pool). **Нет reentrancy guard.** Scenarios:

1. **Router reenters into `allocateTo`:** `MaliciousRouter.swapExactUSDCForToken` → callback `leg.allocateTo(...)`.
2. **Pool reenters into `reduceFrom`:** `MaliciousPool.unstake` → callback `leg.claimPending(...)`.
3. **Cross-call reentrancy через `claimPending`:** `MaliciousPool.creditUnbonded` → callback `leg.reduceFrom(...)`.

Все три — потенциальные проблемы. Тесты фиксируют текущее поведение и требуют `nonReentrant`.

---

## Contract: `legs/PerpFundingLeg.sol`

### Mocks

- **`MockERC20 (usdc, hype)`**
- **`MockRouter`**
- **`MockWriter`** — `IElysiumCoreWriter`
- **`MockTradeOnlyAgent`**
- **`MockFundingSource`** — `IFundingSource` с фиксированным signed `fundingApyBps`.
- **`MockOracle`** — `IPriceOracle` с `priceOf("HYPE") == 1e6`.

### Test cases

| # | Name | Precondition | Action | Expected outcome |
|---|------|--------------|--------|------------------|
| 1 | `test_constructor_storesImmutables` | normal | deploy | all immutables set; `latestApyBps == fixedApyBps` |
| 2 | `test_name_returnsConstant` | any | return `"PerpFundingLeg"` |
| 3 | `test_allocateTo_nonOwnerReverts` | alice | revert |
| 4 | `test_allocateTo_zeroReverts` | owner | revert |
| 5 | `test_allocateTo_halfSplitSpotAndPerp` | 100e6 USDC | allocate | router.call(50e6) → 50 HYPE; writer.openPosition(Short, 50e6); `spotHypeBalance=50`, `perpNotional=50e6`, `allocatedUsd=100e6` |
| 6 | `test_allocateTo_oneWeiEdgeCase` | amount=1 | allocate | `spotPortion = 0 → 1`, `perpPortion = 0` — всё в spot (см. Surprises) |
| 7 | `test_allocateTo_usesShortSide` | allocate | inspect writer log | `side == IElysiumCoreWriter.Side.Short` |
| 8 | `test_allocateTo_usesDelegationWithNonZeroNonce` | allocate | inspect writer | `d.nonce >= 1`, `d.assetIds == [HYPE_ASSET_ID=1]`, `d.keeper == address(leg)`, `d.maxNotional == perpPortion` |
| 9 | `test_allocateTo_usesZeroSig` | same | inspect | `sig == (27, 0, 0)` |
| 10 | `test_allocateTo_emitsEvent` | allocate | inspect | emit `Allocated(amount, totalAllocated)` |
| 11 | `test_harvest_nonOwnerReverts` | alice | revert |
| 12 | `test_harvest_noPosition_noOp` | perpNotional=0 | harvest | no writer call, no emit |
| 13 | `test_harvest_flipsPositionAndSweepsUsdc` | perpNotional=50e6, writer credits 10e6 on close | harvest | close + open; USDC sweep; emit `Harvested(10e6)`; `allocatedUsd -= 10e6` |
| 14 | `test_harvest_noRealisedPnl_noEmit` | perpNotional>0, writer credits 0 | harvest | no `Harvested` emit |
| 15 | `test_reduceFrom_nonOwnerReverts` | alice | revert |
| 16 | `test_reduceFrom_zeroReverts` | owner | revert |
| 17 | `test_reduceFrom_overReduceReverts` | allocated=100e6 | `reduceFrom(200e6)` | revert |
| 18 | `test_reduceFrom_proRataCuts` | allocated=100e6, perp=50e6, spot=50 HYPE, reduce 20e6 | reduce | perpCut=10e6, hypeCut=10; both closed/sold pro-rata |
| 19 | `test_reduceFrom_transfersUsdcToOwner` | reduce | inspect | USDC transfer to owner |
| 20 | `test_setFixedApyBps_ownerOnly` | alice | revert; owner → success |
| 21 | `test_bumpNonce_ownerOnly` | alice | revert; owner → +1 |
| 22 | `test_expectedApy_positiveFundingShortEarns` | fundingSource returns +1000 bps | call | return `1000` |
| 23 | `test_expectedApy_negativeFundingShortPays` | fundingSource returns -500 bps | call | return `0` (short pays → 0 by contract code) |
| 24 | `test_expectedApy_zeroFunding` | fundingSource returns 0 | call | return `0` |
| 25 | `test_expectedApy_oracleFails_fallbackToLatest` | fundingSource reverts | call | return `latestApyBps` |
| 26 | `test_expectedApy_zeroFundingSource_fallback` | fundingSource == address(0) | call | return `latestApyBps` |
| 27 | `test_currentValue_spotAndUsdc` | spot=50 HYPE, usdc=10 | call | `(50 * 1e6) / 1e6 + 10 == 60` |
| 28 | `test_currentValue_zeroSpotBalanceReturnsUsdcOnly` | spot=0, usdc=10 | call | return `10` |
| 29 | `test_currentValue_oracleFails_returnsUsdcOnly` | oracle reverted | call | `price == 0` → spot part 0, + usdc |
| 30 | `test_apyHistory_circularBufferOverflow` | 20 records | inspect | length == 16, сдвинутые |
| 31 | `test_allocateTo_routerZeroAddress_testPath` | router == 0 | allocate | `_buyHype` returns `hype.balanceOf(this)` — pre-load HYPE |
| 32 | `test_allocateTo_writerRevert_cascades` | writer reverted | allocate | whole revert |

### Invariants

1. **`invariant_allocatedUsdNonNegative`** — `allocatedUsd >= 0`.
2. **`invariant_perpNotionalLessThanOrEqualToAllocated`** — `perpNotional <= allocatedUsd`.
3. **`invariant_historyBounded16`** — `history.length <= 16`.
4. **`invariant_expectedApyNonNegative`** — `expectedApy() >= 0` (uint256 + explicit clamp на negative funding).
5. **`invariant_hypeBalanceApproximatesSpotHypeBalance`** — actual `hype.balanceOf(this) == spotHypeBalance` (после каждого allocate/reduce, если router честный).

### Fuzz inputs

- `amount`: `[1, 1e6, 1e9, 1e12, 1e18]`.
- `fundingApyBps`: `-type(int64).max..type(int64).max`.
- `spotPortion` / `perpPortion` implicit через amount.
- Sequence of allocate → harvest → reduce.

### Fork tests

- **`test_fork_elysiumCoreWriter_realPredeploy`** (deferred). Форма: форк Elysium mainnet с реальным writer. Проверяет open/close semantics и funding credit на close.
- **`test_fork_hypercore_fundingRate`** (deferred). Форма: форк HyperCore (chainId TBD) для проверки `fundingSource.fundingApyBps("HYPE")` — real rate.

### Griefing vectors

1. **`maxNotional` (FIX-14):** Тест 8 проверяет что delegation has `maxNotional = perpPortion`. Venue-side (TOA) может отклонить, если cap достигнут.
2. **`expiresAt == 0` (FIX-7):** Legs всегда задают `expiresAt == 0` — test фиксирует, что venue-side TOA принимает never-expiring delegation.
3. **Negative funding griefing:** Тесты 22–24. Если funding становится отрицательным, `expectedApy` = 0, но leg продолжает держать short. Keeper решает через regime switch в aggregator (см. §"Two-speed transitions" в YieldAggregator).
4. **Writer reverts mid-flight:** Тест 32. Если writer revert, allocateTo revert, но spot HYPE уже куплен. Потенциальный grief (см. Surprises).

### Reentrancy

**CRITICAL**: same pattern as BasisHedgeLeg — `allocateTo`, `harvest`, `reduceFrom` все с external calls. **Нет reentrancy guard.** Scenarios:

1. **Router reenters into `allocateTo`.**
2. **Writer reenters into `harvest`.**
3. **Cross-call reentrancy through `_sellHype` в `reduceFrom`.**

Тесты фиксируют текущее поведение и требуют `nonReentrant`.

---

## Contract: `legs/SpotStakingLeg.sol`

### Mocks

- **`MockERC20 (usdc, hype)`**
- **`MockRouter`**
- **`MockStakingPool`** — `IStakingPool`
- **`MockOracle`** — `IPriceOracle` с `getApy("HYPE") == 189` (1.89% стейкинг по spec).

### Test cases

| # | Name | Precondition | Action | Expected outcome |
|---|------|--------------|--------|------------------|
| 1 | `test_constructor_storesImmutables` | normal | deploy | all immutables set |
| 2 | `test_name_returnsConstant` | any | return `"SpotStakingLeg"` |
| 3 | `test_allocateTo_nonOwnerReverts` | alice | revert |
| 4 | `test_allocateTo_zeroReverts` | owner | revert |
| 5 | `test_allocateTo_swapsAndStakes` | 100e6 USDC | allocate | router.call(100e6) → 100 HYPE; pool.stake; `rewardHypeBalance += 100`, `allocatedUsd == 100e6`; emit `Allocated(100e6, 100e6)` |
| 6 | `test_allocateTo_accumulates` | allocate twice | 2nd | `allocatedUsd == sum` |
| 7 | `test_harvest_nonOwnerReverts` | alice | revert |
| 8 | `test_harvest_noUsdcOnHand_noEmit` | harvest без USDC | no `Harvested` emit |
| 9 | `test_harvest_withUsdc_sweeps` | USDC на балансе | harvest | USDC transfer to owner; `allocatedUsd -= u`; emit `Harvested(u)` |
| 10 | `test_reduceFrom_nonOwnerReverts` | alice | revert |
| 11 | `test_reduceFrom_zeroReverts` | owner | revert |
| 12 | `test_reduceFrom_badAmountRewardHypeLessThanAmountReverts` | rewardHype=50, amount=100e6 | revert with `"bad amount"` (unit mismatch, как KHYPELeg) |
| 13 | `test_reduceFrom_zeroUnbonding_immediateCredit` | unbonding=0 | reduce | immediate `creditUnbonded`, USDC returned |
| 14 | `test_reduceFrom_nonZeroUnbonding_defers` | unbonding=24h | reduce | `unstake` вызван, `creditUnbonded` не вызван, `returnedUsd == 0` |
| 15 | `test_claimPending_zeroAmountReturns` | amount=0 | no pool call |
| 16 | `test_claimPending_nonZero_callsCreditUnbonded` | amount=50 | pool.creditUnbonded; USDC transfer |
| 17 | `test_setFixedApyBps_ownerOnly` | alice | revert; owner → success |
| 18 | `test_expectedApy_oracleValue` | oracle 189 | call | return `189` |
| 19 | `test_expectedApy_oracleFails_fallback` | oracle reverted | call | return `latestApyBps` |
| 20 | `test_expectedApy_zeroOracle_fallback` | oracle == 0 | call | return `latestApyBps` |
| 21 | `test_currentValue_zeroBalanceReturnsZero` | no stake | return `0` |
| 22 | `test_currentValue_calculation` | rewardHype=100, rate=1e18, price=1e6 | call | return `100` |
| 23 | `test_currentValue_includesUsdc` | rewardHype=100, usdc=50 | call | return `150` |
| 24 | `test_apyHistory_lengthBounded` | 20 records | length == 16 |
| 25 | `test_reduceFrom_then_claimPending_fullFlow` | allocate, reduce (unbond), warp, claimPending | USDC returned only after claimPending |
| 26 | `test_unbondingPeriodConstant_vs_poolActual` | constant 24h vs pool 24h | test | constant `UNBONDING_PERIOD == 24*3600 == 86400`; pool's actual used at runtime |

### Invariants

1. **`invariant_allocatedUsdNonNegative`** — `allocatedUsd >= 0`.
2. **`invariant_rewardHypeBalanceNonNegative`** — `rewardHypeBalance >= 0`.
3. **`invariant_historyBounded16`** — `history.length <= 16`.
4. **`invariant_currentValueApproxAllocatedUsd`** — currentValue ≈ allocatedUsd.
5. **`invariant_claimPendingDoesNotChangeAllocatedUsd`** — `claimPending` не двигает `allocatedUsd` (см. Surprises).

### Fuzz inputs

- `amount`: `[1, 1e6, 1e12]`.
- `unbondingPeriod`: `[0, 1, 24*3600]`.
- `exchangeRate`: `[0, 1e18, 2e18]`.
- `price`: `[0, 1e6, 1e9]`.

### Fork tests

- **`test_fork_hypercore_directStakingPool`** (deferred). Форма: форк HyperCore (chainId TBD) для проверки real staking pool's `unbondingPeriod`, `exchangeRate`, `stake` semantics.
- **`test_fork_hype_staking_apy_match`** (deferred). Форма: форк HyperCore, проверка что `oracle.getApy("HYPE")` ~ 189 bps (1.89% по spec).

### Griefing vectors

1. **Unbonding period griefing:** если pool's `unbondingPeriod` увеличивается между allocate и reduce, `reduceFrom` возвращает 0 USDC (см. test 14). Keeper должен планировать `claimPending` на 24h+ позже.
2. **Exchange rate depeg:** если `pool.exchangeRate()` падает, currentValue падает. No mitigation — pure exposure.
3. **Same `maxNotional` / `expiresAt` issues как KHYPELeg через delegation** — но SpotStakingLeg не использует delegations (только stake pool), так что гл. 2 и 3.

### Reentrancy

**CRITICAL**: same pattern — `allocateTo`, `harvest`, `reduceFrom`, `claimPending` все с external calls. **Нет reentrancy guard.** Scenarios:

1. **Router reenters into `allocateTo`.**
2. **Pool reenters into `reduceFrom`.**
3. **Cross-call reentrancy через `claimPending`.**

Тесты фиксируют текущее поведение и требуют `nonReentrant`.

---

## Cross-cutting concerns

### Integration test (aggregator + 4 legs, deferred)

После unit-тестов — интеграционный тест `test/integration/EndToEnd.t.sol`:

1. Deploy `MockERC20` для USDC.
2. Deploy 4 `MockYieldLeg` (или real legs с mock router/writer/pool).
3. Deploy `YieldAggregator`.
4. Deploy `RegimeDetector` с mock feed.
5. Scenario:
   - Deposit 1_000_000 USDC.
   - Keeper `requestAllocation` (FUNDING_STRONG weights) → wait timelock → `executePending`.
   - Verify legs получили правильный allocation.
   - Keeper `harvestFromAllLegs` → verify yield swept.
   - Withdraw part → verify USDC returned.

### Round-2 review findings coverage matrix

| Finding | Contract | Tests | Covered? |
|---------|----------|-------|----------|
| **FIX-12**: cancelPending role-gating | YieldAggregator | 26, 27, 28, 29, 30 | Yes — test 28 explicit |
| **FIX-14**: per-venue maxNotional cap | TradeOnlyAgent | 22, 23, 24, 31 | Yes — tests 22, 31 |
| **FIX-7**: expiresAt==0 handling | TradeOnlyAgent | 4, 5, 6, 7 | Yes — test 4 explicit |
| **Two-speed framing** | YieldAggregator + legs | 33, 46 (aggregator); legs' harvest (fast) | Yes — tests 33, 46 |

### Surprises / bugs discovered during code reading

1. **RegimeDetector.setThresholds is open to anyone.** Комментарий в коде: `// TODO: ownership / governance check — placeholder.` Это griefing vector — attacker может установить `strongApyBps = 0` и сделать каждый funding > 0 классифицироваться как FUNDING_STRONG. Нужна owner-gate в production.
2. **Legs передают zero signature (`_zeroSig()`) в `writer.openPosition/closePosition`.** Это не проходит production TOA verification — venue отклонит. Значит, legs работают только в test/stub mode. Production flow needs `submitIntent(delegation, sig, ...)` path (комментарий TODO в коде).
3. **`KHYPELeg.reduceFrom` и `SpotStakingLeg.reduceFrom` сравнивают USDC amount с stake-token balance.** `require(khypeBalance >= amount)` — но amount в USDC, khypeBalance в HYPE. Это unit mismatch. Сейчас работает только потому что 1 kHYPE ≈ 1 HYPE и 1 HYPE ≈ 1 USDC (rate=1e18, price=1e6), но при других ценах — баг.
4. **`_allocatedTotal` может "зависнуть" если legs возвращают меньше, чем запрошено.** В `YieldAggregator.executePending` и `_redeem`, return value от `reduceFrom` не проверяется. Legs могут "потерять" часть USDC.
5. **`BasisHedgeLeg.allocateTo(1)` double-allocates.** Для amount=1: `spotPortion = 0`, затем `spotPortion = amount = 1`; `perpPortion = 1` и `perpPortion > spotPortion` false, так что `perpPortion = 1`. Итого 1 USDC → 1 HYPE + 1 USDC notional, т.е. allocated=1, но фактически 2 "порции". Аналогично edge case в `PerpFundingLeg` (там 1 → 1 spot + 0 perp, другое расхождение).
6. **`setFixedApyBps` не обновляет `latestApyBps`.** Значит, `expectedApy()` возвращает старое `latestApyBps` до следующего `_recordApy` (т.е. до следующего allocate/harvest). Это может быть intentional, но surprising.
7. **`setTimelock` — no emit.** В отличии от `setKeeper` и `setPaused`, у `setTimelock` нет event. Это minor, но inconsistent.
8. **`TradeOnlyAgent.recordExecution` accepts notional=0.** `used + 0 <= cap` всегда true. Venue может "зачислить" 0 notional в cap. Это не критично, но неочевидно.
9. **`TradeOnlyAgent` revocation check happens AFTER expiry check.** Значит, revoked delegation с expired `expiresAt` вернёт `false` из-за expiry, не из-за revocation. Это технически правильно, но confusing.
10. **No `nonReentrant` guard ни в одном контракте.** Все legs + aggregator вызывают external контракты и могут быть reentered. Это самая серьёзная "surprise finding".
11. **`YieldAggregator` deposit не проверяет `msg.sender == token.sender()`.** SafeTransferFrom вызывает `asset_.transferFrom(msg.sender, this, assets)` —ERC-20 token может быть non-standard и return empty data. SafeERC20 обрабатывает это, но token может быть malicious.
12. **`TradeOnlyAgent.revoke` не проверяет `keeper != msg.sender`.** Delegator может "self-revoke" — это не проблема, но неочевидно.
13. **`IYieldLeg.currentValue` in aggregator:** `totalLegValue()` + `asset_.balanceOf(this)` — но legs могут удерживать USDC на своих балансах, и `currentValue()` от leg уже включает эту USDC. Так что `totalAssets()` не double-counts, если legs честные.

### Summary

Общее количество запланированных test cases:

| Contract | Cases | Invariants | Fuzz inputs |
|----------|-------|------------|-------------|
| YieldAggregator | 48 | 8 | 4 (weights, amounts, timelock, mint/redeem) |
| TradeOnlyAgent | 35 | 4 | 6 (maxNotional, maxPerOrder, expiresAt, nonce, salt, notional sequence) |
| RegimeDetector | 30 | 4 | 4 (apySigned, volBps, spot, perpMark) |
| BasisHedgeLeg | 34 | 5 | 3 (amount, rate, sequence) |
| KHYPELeg | 30 | 5 | 4 (amount, unbonding, rate, price) |
| PerpFundingLeg | 32 | 5 | 3 (amount, fundingApyBps, sequence) |
| SpotStakingLeg | 26 | 5 | 4 (amount, unbonding, rate, price) |
| **Total** | **235** | **36** | **28** |

План покрывает все round-2 review findings (FIX-12, FIX-14, FIX-7, two-speed), и фиксирует текущее поведение контрактов — включая known issues (missing `nonReentrant`, missing `setThresholds` owner gate, `expiresAt == 0` sentinel, unit mismatch in stake legs).
