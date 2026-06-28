# Citadel Multisig

A production multisignature wallet written in **Solidity 0.8.27 with inline assembly** for revert-reason bubbling. No external dependencies; no OpenZeppelin.

## Architecture

All owner-set and threshold changes are enforced through the multisig itself. There is no function that a single owner can call to modify governance — every change must be proposed, approved by the threshold, and executed via the standard transaction flow.

```
submit → approve (×threshold) → execute
                                   │
                     destination == address(this)?
                     ↓ yes: governance change
                     ↓ no:  arbitrary external call
```

### Governance via self-call

To add an owner, remove an owner, replace an owner, or change the threshold, encode the call and submit it as a transaction targeting `address(this)`:

```solidity
// Example: add a new signer (requires threshold approvals)
bytes memory data = abi.encodeCall(multisig.addOwner, (newSigner));
uint256 txId = multisig.submitTransaction(address(multisig), 0, data);
// other owners call multisig.approveTransaction(txId) until threshold is met
multisig.executeTransaction(txId);
```

## Security Properties

| Property | Mechanism |
|---|---|
| No single-owner takeover | Governance functions require `msg.sender == address(this)` |
| No replay of transactions | Per-transaction `executed` flag; IDs are monotonically increasing |
| No phantom approvals | `txExists` guard rejects approvals on non-existent IDs |
| No reentrancy | `nonReentrant` guard on `executeTransaction` |
| Failed tx is retryable | If external call reverts, `executed` flag stays false |
| Self-referential ownership blocked | `address(this)` excluded from owner set |

## Functions

### User-facing

| Function | Who can call |
|---|---|
| `submitTransaction(destination, value, data)` | Any owner — auto-approves for submitter |
| `approveTransaction(txId)` | Any owner |
| `executeTransaction(txId)` | Any owner — fires when approval count ≥ threshold |
| `revokeApproval(txId)` | Any owner who previously approved |

### Governance (only callable via executeTransaction targeting address(this))

| Function | Effect |
|---|---|
| `addOwner(owner)` | Add a new signer (max 50) |
| `removeOwner(owner)` | Remove a signer; threshold auto-reduces if needed |
| `replaceOwner(old, new)` | Swap one signer for another atomically |
| `changeThreshold(n)` | Set required approvals (1 ≤ n ≤ owner count) |

### View

| Function | Returns |
|---|---|
| `getOwners()` | Current owner array |
| `getTransaction(txId)` | destination, value, data, executed |
| `getApprovalCount(txId)` | Number of owner approvals |
| `canExecute(txId)` | true if tx exists, not executed, and threshold met |

## Setup

Requires [Foundry](https://github.com/foundry-rs/foundry).

```bash
# Install dependencies
# (forge-std is vendored in lib/forge-std)

# Build
forge build --use /path/to/solc-0.8.27

# Test (58 tests including fuzz)
forge test -vv --use /path/to/solc-0.8.27
```

If Foundry can download solc automatically (`binaries.soliditylang.org` is reachable), omit `--use`:

```bash
forge test -vv
```

## Events

| Event | Emitted on |
|---|---|
| `Deposit(sender, value)` | ETH received via `receive()` |
| `Submission(txId)` | New transaction proposed |
| `Approval(owner, txId)` | Owner approves (including auto-approve on submit) |
| `Revocation(owner, txId)` | Owner revokes approval |
| `Execution(txId)` | Transaction successfully executed |
| `ExecutionFailure(txId)` | External call failed (tx stays retryable) |
| `OwnerAddition(owner)` | Owner added |
| `OwnerRemoval(owner)` | Owner removed |
| `OwnerReplacement(old, new)` | Owner swapped |
| `ThresholdChange(n)` | Threshold updated |

## Audit

See [AUDIT.md](./AUDIT.md) for the full adversarial review findings and what was hardened.
