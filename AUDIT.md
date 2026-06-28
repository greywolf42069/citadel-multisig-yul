# Citadel Multisig — Security Audit & Hardening Report

**Original Self-Audit Date**: February 4, 2026
**Adversarial Review & Hardening**: June 28, 2026
**Contract**: `src/CitadelMultisig.sol`
**Language**: Solidity 0.8.27 (not Yul — original NatSpec was incorrect)
**Status**: HARDENED — prior "APPROVED" status was not warranted

---

## Original Audit Integrity Issues

The self-signed audit dated February 4, 2026 contained several materially false claims:

| Claim | Reality |
|---|---|
| "Pure Yul assembly" | Pure Solidity — no Yul/assembly blocks |
| `recoverOwner()` with EIP-191/ECDSA | Function does not exist in the contract |
| "Owner + Signature verification" on governance functions | Plain `isOwner` check only; no signature involved |
| Executed txs set "approval count to max uint256" | Not true; `executed` bool is set to `true` |
| 100% unit test coverage across 6 suites | No test files exist in this repository |
| Access Control Bypass risk rated MEDIUM | Should have been CRITICAL given the actual vulnerability |

These errors indicate the original audit was not conducted on the actual deployed bytecode.

---

## Findings from Adversarial Review

### CRITICAL — C-1: Single Owner Can Unilaterally Hijack the Multisig

**Functions affected**: `addOwner`, `removeOwner`, `replaceOwner`, `changeThreshold`

**Original guard**: `require(isOwner[msg.sender], "Not owner")`

Any single compromised owner key could execute the following attack with zero multisig approval from other owners:

1. Call `addOwner(attacker_address)` to add an attacker-controlled signer.
2. Call `changeThreshold(1)` to lower the threshold to 1-of-N.
3. Submit and immediately self-execute any transaction, draining all funds.

This makes the contract no safer than a plain EOA wallet despite advertising as a multisig.

**Fix**: All governance functions now use `onlyWallet`, requiring `msg.sender == address(this)`. They can only be reached by encoding the calldata and routing it through `submitTransaction` → `approveTransaction` → `executeTransaction`, satisfying the full threshold requirement.

---

### HIGH — H-1: Phantom Approvals on Non-Existent Transactions

**Functions affected**: `approveTransaction`, `revokeApproval`

**Original code**: No bounds check on `transactionId`.

Calling `approveTransaction(999)` on a contract with zero transactions would silently succeed, writing an approval for a transaction that doesn't exist. If that transaction ID is later created, the phantom approval would count toward threshold, allowing threshold to be met with fewer real approvals than intended.

**Fix**: `txExists(transactionId)` modifier added to both functions, reverting if `transactionId >= transactionCount`.

---

### HIGH — H-2: No Reentrancy Guard on executeTransaction

**Original code**: `executeTransaction` followed CEI for the single re-execution case but had no guard against cross-function reentrancy.

A malicious `destination` contract could reenter `executeTransaction` to execute a second pending transaction during the first transaction's callback. With no reentrancy guard, if threshold was already met on a second transaction (perhaps staged before the attack), both could execute in a single call.

**Fix**: `nonReentrant` modifier added to `executeTransaction` using a two-value slot guard (`_guardStatus`).

---

### MEDIUM — M-1: Zero Address Accepted as Transaction Destination

**Original code**: `submitTransaction` performed no validation on `destination`.

A transaction to `address(0)` would succeed on most EVM chains and permanently burn any forwarded ETH. On some chains, `address(0)` routes to a precompile.

**Fix**: `require(destination != address(0), "Zero address destination")` added to `submitTransaction`.

---

### MEDIUM — M-2: Contract Address Not Excluded from Owner Set

**Original code**: No check preventing `address(this)` from being added as an owner.

If `address(this)` were added as an owner, it could call `approveTransaction` or `submitTransaction` from within `executeTransaction` (since `msg.sender` of an internal call would be `address(this)`, satisfying `isOwner`). This could allow threshold manipulation.

**Fix**: `require(owner != address(this), "Contract cannot be owner")` added to constructor, `addOwner`, and `replaceOwner`.

---

### LOW — L-1: Submitter Must Make a Separate approveTransaction Call

**Original behavior**: `submitTransaction` did not record the submitter's approval.

A submitter knowing they want to approve their own proposal had to make two calls, wasting gas and creating an inconsistent UX compared to standard multisig conventions (Gnosis Safe, among others, auto-approves on submission).

**Fix**: `submitTransaction` now records the submitter's approval and emits `Approval` before returning.

---

### LOW — L-2: No ETH Deposit Event

**Original code**: `receive()` accepted ETH silently with no log.

Off-chain monitoring tools and frontends had no reliable way to track ETH inflows to the contract.

**Fix**: `Deposit(address indexed sender, uint256 value)` event added and emitted in `receive()`.

---

### LOW — L-3: MAX_OWNERS Capped at 10

**Original code**: `require(owners.length < 10, "Max owners reached")` in `addOwner`.

A cap of 10 is unnecessarily restrictive for organizations that may require larger signer sets (e.g., 7-of-15 or 10-of-20 configurations are common in DAO treasury management).

**Fix**: `MAX_OWNERS` constant raised to 50. The `getApprovalCount` loop remains O(N) but is bounded and called only at execution time.

---

### INFORMATIONAL — I-1: Callee Revert Reason Not Propagated

**Original code**: `require(success, "Execution failed")` discarded the callee's revert data.

Debugging failed executions required replaying the transaction externally to recover the error.

**Fix**: Callee return data is captured; if non-empty it is bubbled up via assembly. `ExecutionFailure` event added for off-chain indexing.

---

### INFORMATIONAL — I-2: No canExecute Helper

Off-chain tooling had to reconstruct approval state manually to determine if a transaction was ready.

**Fix**: `canExecute(uint256 transactionId)` view function added.

---

## Summary of Changes

| ID | Severity | Status |
|---|---|---|
| C-1 | Critical | Fixed — `onlyWallet` on all governance functions |
| H-1 | High | Fixed — `txExists` modifier on approve/revoke |
| H-2 | High | Fixed — `nonReentrant` on `executeTransaction` |
| M-1 | Medium | Fixed — zero-address destination check |
| M-2 | Medium | Fixed — `address(this)` excluded from owner set |
| L-1 | Low | Fixed — auto-approve on submission |
| L-2 | Low | Fixed — `Deposit` event on ETH receipt |
| L-3 | Low | Fixed — `MAX_OWNERS` raised to 50 |
| I-1 | Informational | Fixed — revert reason bubbled up |
| I-2 | Informational | Fixed — `canExecute` view added |

---

## Governance Pattern After Hardening

To execute `addOwner(newAddr)`, owners must:

1. Any owner calls `submitTransaction(address(this), 0, abi.encodeCall(this.addOwner, (newAddr)))`.
   - Submitter's approval is recorded automatically.
2. Remaining owners call `approveTransaction(txId)` until threshold is met.
3. Any owner calls `executeTransaction(txId)`, which calls `address(this).addOwner(newAddr)`.

This ensures no governance change can occur without the configured threshold of signers agreeing.

---

## Remaining Considerations (Out of Scope for This Audit)

- **No time-lock**: Transactions execute immediately once threshold is met. Consider adding an optional delay for high-value treasuries.
- **No expiry**: Transactions remain pending indefinitely. A time-based expiry could reduce stale-approval risk.
- **No batch submission**: Each transaction is a separate on-chain call.
- **Test suite**: No tests exist. A Foundry test suite covering the attack paths above should be written before mainnet deployment.

---

**DEPLOYMENT STATUS**: NOT APPROVED pending test suite and independent third-party audit.
