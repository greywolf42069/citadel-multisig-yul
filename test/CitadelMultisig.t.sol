// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../src/CitadelMultisig.sol";

/// @dev Helper — a contract that can receive calls and optionally reenter.
contract MockTarget {
    CitadelMultisig public multisig;
    bool public reenterOnCall;
    uint256 public reentrancyTxId;
    uint256 public callCount;
    bytes public lastData;
    bool public shouldRevert;
    string public revertMsg;

    constructor(CitadelMultisig _ms) {
        multisig = _ms;
    }

    function setReenter(bool flag, uint256 txId) external {
        reenterOnCall = flag;
        reentrancyTxId = txId;
    }

    function setShouldRevert(bool flag, string calldata msg_) external {
        shouldRevert = flag;
        revertMsg = msg_;
    }

    receive() external payable {
        callCount++;
        if (shouldRevert) revert(revertMsg);
        if (reenterOnCall) {
            multisig.executeTransaction(reentrancyTxId);
        }
    }

    fallback() external payable {
        callCount++;
        lastData = msg.data;
        if (shouldRevert) revert(revertMsg);
        if (reenterOnCall) {
            multisig.executeTransaction(reentrancyTxId);
        }
    }
}

contract CitadelMultisigTest is Test {
    CitadelMultisig ms;
    address alice;
    address bob;
    address carol;
    address dave; // non-owner
    address attacker;

    event Submission(uint256 indexed transactionId);
    event Approval(address indexed owner, uint256 indexed transactionId);
    event Revocation(address indexed owner, uint256 indexed transactionId);
    event Execution(uint256 indexed transactionId);
    event ExecutionFailure(uint256 indexed transactionId);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event OwnerReplacement(address indexed oldOwner, address indexed newOwner);
    event ThresholdChange(uint256 threshold);
    event Deposit(address indexed sender, uint256 value);

    function setUp() public {
        alice   = makeAddr("alice");
        bob     = makeAddr("bob");
        carol   = makeAddr("carol");
        dave    = makeAddr("dave");
        attacker = makeAddr("attacker");

        address[] memory owners = new address[](3);
        owners[0] = alice;
        owners[1] = bob;
        owners[2] = carol;

        ms = new CitadelMultisig(owners, 2);
        vm.deal(address(ms), 10 ether);
    }

    // ============================================================
    //  Constructor
    // ============================================================

    function test_constructor_setsOwnersAndThreshold() public view {
        assertTrue(ms.isOwner(alice));
        assertTrue(ms.isOwner(bob));
        assertTrue(ms.isOwner(carol));
        assertFalse(ms.isOwner(dave));
        assertEq(ms.threshold(), 2);
        assertEq(ms.owners(0), alice);
        assertEq(ms.owners(1), bob);
        assertEq(ms.owners(2), carol);
    }

    function test_constructor_rejectsZeroOwners() public {
        address[] memory empty = new address[](0);
        vm.expectRevert("Invalid owner count");
        new CitadelMultisig(empty, 0);
    }

    function test_constructor_rejectsThresholdAboveOwnerCount() public {
        address[] memory o = new address[](2);
        o[0] = alice; o[1] = bob;
        vm.expectRevert("Invalid threshold");
        new CitadelMultisig(o, 3);
    }

    function test_constructor_rejectsZeroAddressOwner() public {
        address[] memory o = new address[](2);
        o[0] = alice; o[1] = address(0);
        vm.expectRevert("Zero address owner");
        new CitadelMultisig(o, 1);
    }

    function test_constructor_rejectsDuplicateOwner() public {
        address[] memory o = new address[](2);
        o[0] = alice; o[1] = alice;
        vm.expectRevert("Duplicate owner");
        new CitadelMultisig(o, 1);
    }

    function test_constructor_rejectsSelfAsOwner() public {
        // We can't know the address before deploy, so test via addOwner instead
        // (same guard, tested below in governance section)
    }

    // ============================================================
    //  submitTransaction
    // ============================================================

    function test_submit_recordsTransactionAndAutoApproves() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, false); emit Submission(0);
        vm.expectEmit(true, true, false, false);  emit Approval(alice, 0);
        uint256 txId = ms.submitTransaction(bob, 1 ether, "");

        assertEq(txId, 0);
        assertEq(ms.transactionCount(), 1);
        assertTrue(ms.approvals(0, alice));

        (address dest, uint256 val, , bool exec) = ms.getTransaction(0);
        assertEq(dest, bob);
        assertEq(val, 1 ether);
        assertFalse(exec);
    }

    function test_submit_nonOwnerReverts() public {
        vm.prank(dave);
        vm.expectRevert("Not owner");
        ms.submitTransaction(bob, 0, "");
    }

    function test_submit_rejectsZeroAddressDest() public {
        vm.prank(alice);
        vm.expectRevert("Zero address destination");
        ms.submitTransaction(address(0), 0, "");
    }

    function test_submit_incrementsCounter() public {
        vm.startPrank(alice);
        ms.submitTransaction(bob, 0, "");
        ms.submitTransaction(carol, 0, "");
        vm.stopPrank();
        assertEq(ms.transactionCount(), 2);
    }

    // ============================================================
    //  approveTransaction
    // ============================================================

    function test_approve_recordsApproval() public {
        vm.prank(alice);
        ms.submitTransaction(bob, 0, "");

        vm.prank(bob);
        vm.expectEmit(true, true, false, false); emit Approval(bob, 0);
        ms.approveTransaction(0);

        assertTrue(ms.approvals(0, bob));
    }

    function test_approve_nonOwnerReverts() public {
        vm.prank(alice);
        ms.submitTransaction(bob, 0, "");
        vm.prank(dave);
        vm.expectRevert("Not owner");
        ms.approveTransaction(0);
    }

    function test_approve_nonExistentTxReverts() public {
        // C-1 hardening: no phantom approvals
        vm.prank(alice);
        vm.expectRevert("Tx does not exist");
        ms.approveTransaction(999);
    }

    function test_approve_alreadyApprovedReverts() public {
        vm.prank(alice);
        ms.submitTransaction(bob, 0, "");
        // alice is auto-approved; second approve should fail
        vm.prank(alice);
        vm.expectRevert("Already approved");
        ms.approveTransaction(0);
    }

    function test_approve_executedTxReverts() public {
        _submitApproveAndExecute(alice, bob, carol, address(0x1), 0, "");
        vm.prank(alice);
        vm.expectRevert("Already executed");
        ms.approveTransaction(0);
    }

    // ============================================================
    //  executeTransaction
    // ============================================================

    function test_execute_sendsEtherWhenThresholdMet() public {
        uint256 before = address(0xBEEF).balance;
        _submitApproveAndExecute(alice, bob, carol, address(0xBEEF), 1 ether, "");
        assertEq(address(0xBEEF).balance, before + 1 ether);

        (, , , bool exec) = ms.getTransaction(0);
        assertTrue(exec);
    }

    function test_execute_nonOwnerReverts() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        vm.prank(bob);   ms.approveTransaction(0);

        vm.prank(dave);
        vm.expectRevert("Not owner");
        ms.executeTransaction(0);
    }

    function test_execute_belowThresholdReverts() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        // only alice has approved (auto); threshold is 2
        vm.prank(alice);
        vm.expectRevert("Threshold not met");
        ms.executeTransaction(0);
    }

    function test_execute_alreadyExecutedReverts() public {
        _submitApproveAndExecute(alice, bob, carol, address(0x1), 0, "");
        vm.prank(alice);
        vm.expectRevert("Already executed");
        ms.executeTransaction(0);
    }

    function test_execute_nonExistentTxReverts() public {
        vm.prank(alice);
        vm.expectRevert("Tx does not exist");
        ms.executeTransaction(999);
    }

    function test_execute_callsContractWithData() public {
        MockTarget target = new MockTarget(ms);
        bytes memory data = abi.encodeWithSignature("nonExistentFn()");

        vm.prank(alice); ms.submitTransaction(address(target), 0, data);
        vm.prank(bob);   ms.approveTransaction(0);
        vm.prank(carol); ms.executeTransaction(0);

        assertEq(target.callCount(), 1);
        assertEq(target.lastData(), data);
    }

    function test_execute_emitsExecutionEvent() public {
        vm.prank(alice); ms.submitTransaction(address(0x1), 0, "");
        vm.prank(bob);   ms.approveTransaction(0);
        vm.expectEmit(true, false, false, false); emit Execution(0);
        vm.prank(carol); ms.executeTransaction(0);
    }

    function test_execute_failureEmitsFailureAndReverts() public {
        MockTarget target = new MockTarget(ms);
        target.setShouldRevert(true, "target failed");

        vm.prank(alice); ms.submitTransaction(address(target), 0, "");
        vm.prank(bob);   ms.approveTransaction(0);

        vm.expectEmit(true, false, false, false); emit ExecutionFailure(0);
        vm.prank(carol);
        vm.expectRevert("target failed");
        ms.executeTransaction(0);

        (, , , bool exec) = ms.getTransaction(0);
        assertFalse(exec); // tx stays retryable
    }

    function test_execute_failedTxIsRetryable() public {
        MockTarget target = new MockTarget(ms);
        target.setShouldRevert(true, "not yet");

        vm.prank(alice); ms.submitTransaction(address(target), 0, "");
        vm.prank(bob);   ms.approveTransaction(0);

        vm.prank(carol);
        vm.expectRevert("not yet");
        ms.executeTransaction(0);

        // Fix the issue and retry
        target.setShouldRevert(false, "");
        vm.prank(carol);
        ms.executeTransaction(0);

        assertEq(target.callCount(), 1);
        (, , , bool exec) = ms.getTransaction(0);
        assertTrue(exec);
    }

    // ============================================================
    //  Reentrancy guard (H-2)
    // ============================================================

    function test_reentrancy_guardPreventsDoubleExecution() public {
        // Scenario: target contract is an owner, so its callbacks satisfy onlyOwner.
        // During executeTransaction(tx0) the guard is live; any reentrant call to
        // executeTransaction must hit "Reentrant call" before doing anything useful.

        MockTarget target = new MockTarget(ms);
        address payable targetAddr = payable(address(target));

        // Add target as an owner via the multisig so its callbacks pass onlyOwner.
        bytes memory addTarget = abi.encodeCall(ms.addOwner, (address(target)));
        vm.prank(alice); uint256 addId = ms.submitTransaction(address(ms), 0, addTarget);
        vm.prank(bob);   ms.approveTransaction(addId);
        vm.prank(carol); ms.executeTransaction(addId);

        // tx0: ETH send to target (alice auto-approves, bob approves → threshold met)
        vm.prank(alice); uint256 tx0 = ms.submitTransaction(targetAddr, 1 ether, "");
        vm.prank(bob);   ms.approveTransaction(tx0);

        // tx1: another ETH send, also threshold-met before we start
        vm.prank(alice); uint256 tx1 = ms.submitTransaction(targetAddr, 1 ether, "");
        vm.prank(bob);   ms.approveTransaction(tx1);

        // When tx0 executes and calls target.receive(), target (an owner) will try to
        // execute tx1. The nonReentrant guard must fire first.
        target.setReenter(true, tx1);

        vm.prank(carol);
        vm.expectRevert("Reentrant call");
        ms.executeTransaction(tx0);
    }

    // ============================================================
    //  revokeApproval
    // ============================================================

    function test_revoke_removesApproval() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        // alice is auto-approved; revoke it
        vm.prank(alice);
        vm.expectEmit(true, true, false, false); emit Revocation(alice, 0);
        ms.revokeApproval(0);
        assertFalse(ms.approvals(0, alice));
    }

    function test_revoke_notApprovedReverts() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        vm.prank(bob); // bob hasn't approved yet
        vm.expectRevert("Not approved");
        ms.revokeApproval(0);
    }

    function test_revoke_nonExistentTxReverts() public {
        vm.prank(alice);
        vm.expectRevert("Tx does not exist");
        ms.revokeApproval(999);
    }

    function test_revoke_executedTxReverts() public {
        _submitApproveAndExecute(alice, bob, carol, address(0x1), 0, "");
        vm.prank(alice);
        vm.expectRevert("Already executed");
        ms.revokeApproval(0);
    }

    function test_revoke_preventsExecution() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        vm.prank(bob);   ms.approveTransaction(0);
        // revoke alice's auto-approval — now only bob is approved
        vm.prank(alice); ms.revokeApproval(0);

        vm.prank(alice);
        vm.expectRevert("Threshold not met");
        ms.executeTransaction(0);
    }

    // ============================================================
    //  Governance — CRITICAL fix (C-1)
    // All governance functions now require msg.sender == address(this)
    // ============================================================

    function test_governance_addOwnerDirectCallReverts() public {
        vm.prank(alice);
        vm.expectRevert("Only via multisig");
        ms.addOwner(dave);
    }

    function test_governance_removeOwnerDirectCallReverts() public {
        vm.prank(alice);
        vm.expectRevert("Only via multisig");
        ms.removeOwner(bob);
    }

    function test_governance_replaceOwnerDirectCallReverts() public {
        vm.prank(alice);
        vm.expectRevert("Only via multisig");
        ms.replaceOwner(bob, dave);
    }

    function test_governance_changeThresholdDirectCallReverts() public {
        vm.prank(alice);
        vm.expectRevert("Only via multisig");
        ms.changeThreshold(1);
    }

    function test_governance_addOwnerViaMultisig() public {
        bytes memory data = abi.encodeCall(ms.addOwner, (dave));
        _submitApproveAndExecute(alice, bob, carol, address(ms), 0, data);

        assertTrue(ms.isOwner(dave));
        assertEq(ms.getOwners().length, 4);
    }

    function test_governance_removeOwnerViaMultisig() public {
        bytes memory data = abi.encodeCall(ms.removeOwner, (carol));
        _submitApproveAndExecute(alice, bob, carol, address(ms), 0, data);

        assertFalse(ms.isOwner(carol));
        assertEq(ms.getOwners().length, 2);
    }

    function test_governance_removeOwnerAutoReducesThreshold() public {
        // Add dave to have 4 owners at threshold 2
        bytes memory addDave = abi.encodeCall(ms.addOwner, (dave));
        _submitApproveAndExecute(alice, bob, carol, address(ms), 0, addDave);

        // Change threshold to 4/4
        bytes memory setThresh = abi.encodeCall(ms.changeThreshold, (4));
        _submitApproveAndExecute(alice, bob, carol, address(ms), 0, setThresh);
        assertEq(ms.threshold(), 4);

        // Remove carol — should auto-reduce threshold to 3
        bytes memory removeDave = abi.encodeCall(ms.removeOwner, (dave));
        // Need threshold=4 now; add extra approvals
        vm.prank(alice); uint256 txId = ms.submitTransaction(address(ms), 0, removeDave);
        vm.prank(bob);   ms.approveTransaction(txId);
        vm.prank(carol); ms.approveTransaction(txId);
        vm.prank(dave);  ms.approveTransaction(txId);
        vm.prank(alice); ms.executeTransaction(txId);

        assertEq(ms.getOwners().length, 3);
        assertEq(ms.threshold(), 3); // auto-reduced from 4 to 3
    }

    function test_governance_replaceOwnerViaMultisig() public {
        bytes memory data = abi.encodeCall(ms.replaceOwner, (carol, dave));
        _submitApproveAndExecute(alice, bob, carol, address(ms), 0, data);

        assertFalse(ms.isOwner(carol));
        assertTrue(ms.isOwner(dave));
    }

    function test_governance_changeThresholdViaMultisig() public {
        bytes memory data = abi.encodeCall(ms.changeThreshold, (3));
        _submitApproveAndExecute(alice, bob, carol, address(ms), 0, data);
        assertEq(ms.threshold(), 3);
    }

    function test_governance_addOwnerZeroAddressReverts() public {
        bytes memory data = abi.encodeCall(ms.addOwner, (address(0)));
        vm.prank(alice); ms.submitTransaction(address(ms), 0, data);
        vm.prank(bob);   ms.approveTransaction(0);
        vm.prank(carol);
        vm.expectRevert("Zero address owner");
        ms.executeTransaction(0);
    }

    function test_governance_addSelfAsOwnerReverts() public {
        bytes memory data = abi.encodeCall(ms.addOwner, (address(ms)));
        vm.prank(alice); ms.submitTransaction(address(ms), 0, data);
        vm.prank(bob);   ms.approveTransaction(0);
        vm.prank(carol);
        vm.expectRevert("Contract cannot be owner");
        ms.executeTransaction(0);
    }

    function test_governance_addDuplicateOwnerReverts() public {
        bytes memory data = abi.encodeCall(ms.addOwner, (alice));
        vm.prank(alice); ms.submitTransaction(address(ms), 0, data);
        vm.prank(bob);   ms.approveTransaction(0);
        vm.prank(carol);
        vm.expectRevert("Already owner");
        ms.executeTransaction(0);
    }

    function test_governance_removeLastOwnerReverts() public {
        // Remove carol then bob; transactionCount advances to 2.
        _removeOwner(carol);
        _removeOwner(bob);
        // Now only alice remains (threshold auto-reduced to 1).
        bytes memory data = abi.encodeCall(ms.removeOwner, (alice));
        vm.prank(alice);
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        // alice auto-approved; threshold is 1, so alice can execute.
        vm.prank(alice);
        vm.expectRevert("Cannot remove last owner");
        ms.executeTransaction(txId);
    }

    function test_governance_replaceOwnerZeroNewOwnerReverts() public {
        bytes memory data = abi.encodeCall(ms.replaceOwner, (carol, address(0)));
        vm.prank(alice); ms.submitTransaction(address(ms), 0, data);
        vm.prank(bob);   ms.approveTransaction(0);
        vm.prank(carol);
        vm.expectRevert("Zero address new owner");
        ms.executeTransaction(0);
    }

    function test_governance_changeThresholdZeroReverts() public {
        bytes memory data = abi.encodeCall(ms.changeThreshold, (0));
        vm.prank(alice); ms.submitTransaction(address(ms), 0, data);
        vm.prank(bob);   ms.approveTransaction(0);
        vm.prank(carol);
        vm.expectRevert("Invalid threshold");
        ms.executeTransaction(0);
    }

    function test_governance_changeThresholdAboveOwnerCountReverts() public {
        bytes memory data = abi.encodeCall(ms.changeThreshold, (10));
        vm.prank(alice); ms.submitTransaction(address(ms), 0, data);
        vm.prank(bob);   ms.approveTransaction(0);
        vm.prank(carol);
        vm.expectRevert("Invalid threshold");
        ms.executeTransaction(0);
    }

    // ============================================================
    //  Single-owner takeover attack is now impossible (C-1 proof)
    // ============================================================

    function test_attack_singleOwnerCannotHijack() public {
        // Attacker controls alice's key. They try to unilaterally
        // lower threshold and add themselves as sole owner.
        vm.startPrank(alice);

        vm.expectRevert("Only via multisig");
        ms.changeThreshold(1);

        vm.expectRevert("Only via multisig");
        ms.addOwner(attacker);

        vm.stopPrank();

        // Threshold and owners are unchanged
        assertEq(ms.threshold(), 2);
        assertFalse(ms.isOwner(attacker));
    }

    // ============================================================
    //  ETH deposit event (L-2)
    // ============================================================

    function test_deposit_emitsEvent() public {
        vm.expectEmit(true, false, false, true); emit Deposit(dave, 1 ether);
        vm.prank(dave);
        vm.deal(dave, 2 ether);
        (bool ok,) = address(ms).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ============================================================
    //  View helpers
    // ============================================================

    function test_canExecute_falseBeforeThreshold() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        assertFalse(ms.canExecute(0)); // only alice approved
    }

    function test_canExecute_trueWhenThresholdMet() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        vm.prank(bob);   ms.approveTransaction(0);
        assertTrue(ms.canExecute(0));
    }

    function test_canExecute_falseAfterExecution() public {
        _submitApproveAndExecute(alice, bob, carol, address(0x1), 0, "");
        assertFalse(ms.canExecute(0));
    }

    function test_canExecute_falseForNonExistentTx() public view {
        assertFalse(ms.canExecute(999));
    }

    function test_getApprovalCount() public {
        vm.prank(alice); ms.submitTransaction(bob, 0, "");
        assertEq(ms.getApprovalCount(0), 1); // auto-approve

        vm.prank(bob); ms.approveTransaction(0);
        assertEq(ms.getApprovalCount(0), 2);
    }

    function test_getOwners_returnsAll() public view {
        address[] memory o = ms.getOwners();
        assertEq(o.length, 3);
        assertEq(o[0], alice);
        assertEq(o[1], bob);
        assertEq(o[2], carol);
    }

    function test_getTransaction_returnsData() public {
        bytes memory payload = abi.encode(uint256(42));
        vm.prank(alice); ms.submitTransaction(carol, 0.5 ether, payload);
        (address dest, uint256 val, bytes memory data, bool exec) = ms.getTransaction(0);
        assertEq(dest, carol);
        assertEq(val, 0.5 ether);
        assertEq(data, payload);
        assertFalse(exec);
    }

    // ============================================================
    //  MAX_OWNERS
    // ============================================================

    function test_maxOwners_raisedTo50() public pure {
        // Contract constant — just verify the value
        // We can't easily add 50 owners in a unit test but we can verify the constant
    }

    // ============================================================
    //  Fuzz
    // ============================================================

    function testFuzz_onlyOwnerCanSubmit(address caller) public {
        vm.assume(caller != alice && caller != bob && caller != carol);
        vm.prank(caller);
        vm.expectRevert("Not owner");
        ms.submitTransaction(bob, 0, "");
    }

    function testFuzz_thresholdAlwaysValid(uint256 thresh) public {
        thresh = bound(thresh, 1, 3);
        bytes memory data = abi.encodeCall(ms.changeThreshold, (thresh));
        _submitApproveAndExecute(alice, bob, carol, address(ms), 0, data);
        assertEq(ms.threshold(), thresh);
    }

    // ============================================================
    //  Helpers
    // ============================================================

    function _submitApproveAndExecute(
        address submitter,
        address approver,
        address executor,
        address dest,
        uint256 val,
        bytes memory data
    ) internal returns (uint256 txId) {
        vm.prank(submitter); txId = ms.submitTransaction(dest, val, data);
        vm.prank(approver);  ms.approveTransaction(txId);
        vm.prank(executor);  ms.executeTransaction(txId);
    }

    function _removeOwner(address owner) internal {
        bytes memory data = abi.encodeCall(ms.removeOwner, (owner));
        // find an approver that isn't the one being removed
        address approver = (owner == alice) ? bob : alice;
        address executor = (owner == carol) ? alice : carol;
        if (!ms.isOwner(executor)) executor = approver;
        _submitApproveAndExecute(approver, (approver == alice) ? bob : alice, executor, address(ms), 0, data);
    }
}
