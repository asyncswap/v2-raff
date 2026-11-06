// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {NativeClaims} from "@async-swap/NativeClaims.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Mints native ERC-6909 claims (id 0) to any address inside a real PoolManager unlock.
contract NCRClaimMinter {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function mint(address to, uint256 amount) external payable {
        pm.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        pm.settle{value: amount}();
        pm.mint(to, 0, amount);
        return "";
    }
}

/// @dev Recipient that, while receiving the redeemed ETH, records `_redeeming` (slot 0) and tries a
///      nested `redeem(r', a')`.
contract NCRProbe {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    NativeClaims immutable claims;
    address public nestedRecipient;
    uint256 public nestedAmount;
    bytes32 public seenFlag;
    bool public nestedTried;
    bool public nestedOk;
    bytes public nestedRet;

    constructor(NativeClaims c) {
        claims = c;
    }

    function arm(address r, uint256 a) external {
        nestedRecipient = r;
        nestedAmount = a;
    }

    receive() external payable {
        seenFlag = vm.load(address(claims), bytes32(0));
        nestedTried = true;
        (nestedOk, nestedRet) =
            address(claims).call(abi.encodeCall(NativeClaims.redeem, (nestedRecipient, nestedAmount)));
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/NativeClaimsRedeem.lean`.
contract NativeClaimsRedeemFormalTest is FormalBase {
    NativeClaims claims;
    NCRClaimMinter minter;
    bytes32 constant REDEEMING_SLOT = bytes32(0); // `bool private _redeeming` (immutables take no slot)

    function setUp() public override {
        super.setUp();
        claims = new NativeClaims(manager);
        minter = new NCRClaimMinter(manager);
    }

    /* ---------------- helpers ---------------- */

    function _give(address to, uint256 amount) internal {
        if (amount == 0) return;
        vm.deal(address(minter), amount);
        minter.mint(to, amount);
    }

    function _flag() internal view returns (bytes32) {
        return vm.load(address(claims), REDEEMING_SLOT);
    }

    struct Oracle {
        bool ok;
        bytes ret;
        uint256 ownerClaim;
        uint256 recBal;
        uint256 allowance;
    }

    /// @dev `poolManager.unlock(abi.encode(sender, recipient, amount))` as the NativeClaims contract,
    ///      from the `locked` world (`_redeeming = true`); the world is restored afterwards.
    function _oracle(address sender, address recipient, uint256 amount) internal returns (Oracle memory r) {
        uint256 snap = vm.snapshotState();
        vm.store(address(claims), REDEEMING_SLOT, bytes32(uint256(1)));
        vm.prank(address(claims));
        (r.ok, r.ret) =
            address(manager).call(abi.encodeCall(IPoolManager.unlock, (abi.encode(sender, recipient, amount))));
        r.ownerClaim = manager.balanceOf(sender, 0);
        r.recBal = recipient.balance;
        r.allowance = manager.allowance(sender, address(claims), 0);
        vm.revertToState(snap);
    }

    function _redeem(address sender, address recipient, uint256 amount) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(claims).call(abi.encodeCall(NativeClaims.redeem, (recipient, amount)));
    }

    /// @dev Fuzzed state: alice holds `claim` native claims and approved `allow` to NativeClaims.
    function _state(uint96 claim, uint256 allow) internal {
        _give(alice, claim);
        vm.prank(alice);
        manager.approve(address(claims), 0, allow);
    }

    /* ---------------- theorems ---------------- */

    /// @notice formal/Refinement/Swarm/NativeClaimsRedeem.lean:29 — redeem = ReentrantRedemption if _redeeming, else
    ///         InvalidRedemption if recipient == 0 or amount == 0, else unlock(abi.encode(msg.sender, recipient, amount))
    ///         from the locked world, with _redeeming cleared on success.
    function testFuzz_redeem_run(
        address sender,
        bool senderIsAlice,
        bool locked,
        address recipient,
        uint256 amount,
        uint96 claim,
        uint256 allow
    ) public {
        _state(claim, allow);
        if (senderIsAlice) sender = alice;
        if (amount % 2 == 0) amount = bound(amount, 0, uint256(claim) + 1); // reach the success path often
        if (locked) vm.store(address(claims), REDEEMING_SLOT, bytes32(uint256(1)));

        Oracle memory o = _oracle(sender, recipient, amount);
        (bool ok, bytes memory ret) = _redeem(sender, recipient, amount);

        if (locked) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(NativeClaims.ReentrantRedemption.selector));
        } else if (recipient == address(0) || amount == 0) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(NativeClaims.InvalidRedemption.selector));
        } else {
            assertEq(ok, o.ok, "redeem succeeds iff its unlock succeeds");
            if (!ok) {
                assertEq(ret, o.ret, "unlock's revert propagates");
                assertEq(_flag(), bytes32(0));
            } else {
                assertEq(manager.balanceOf(sender, 0), o.ownerClaim);
                assertEq(recipient.balance, o.recBal);
                assertEq(manager.allowance(sender, address(claims), 0), o.allowance);
                assertEq(_flag(), bytes32(0), "_redeeming cleared");
            }
        }
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsRedeem.lean:53 — with _redeeming set, redeem reverts ReentrantRedemption.
    function testFuzz_redeem_reentrant(address sender, address recipient, uint256 amount, uint96 claim) public {
        _state(claim, type(uint256).max);
        vm.store(address(claims), REDEEMING_SLOT, bytes32(uint256(1)));
        vm.prank(sender);
        vm.expectRevert(NativeClaims.ReentrantRedemption.selector);
        claims.redeem(recipient, amount);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsRedeem.lean:59 — with _redeeming clear and recipient == 0 or amount == 0,
    ///         redeem reverts InvalidRedemption.
    function testFuzz_redeem_invalid(
        address sender,
        address recipient,
        uint256 amount,
        bool zeroRecipient,
        uint96 claim
    ) public {
        _state(claim, type(uint256).max);
        if (zeroRecipient) recipient = address(0);
        else amount = 0;
        vm.prank(sender);
        vm.expectRevert(NativeClaims.InvalidRedemption.selector);
        claims.redeem(recipient, amount);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsRedeem.lean:67 — success implies _redeeming was clear, recipient and amount
    ///         nonzero, unlock was called with abi.encode(msg.sender, recipient, amount), and _redeeming is clear after.
    function testFuzz_redeem_ok(
        address sender,
        address recipient,
        uint256 amount,
        uint96 claim,
        uint256 allow,
        bool easy
    ) public {
        _state(claim, allow);
        if (easy) {
            // drive the success path: alice, fresh EOA recipient, amount within claim & allowance
            sender = alice;
            recipient = address(uint160(uint256(keccak256(abi.encode("rcpt", recipient)))));
            vm.prank(alice);
            manager.approve(address(claims), 0, type(uint256).max);
            amount = bound(amount, 1, uint256(claim) + 1);
            if (claim != 0) amount = bound(amount, 1, claim);
        }
        bool expectOk = easy && claim != 0;
        if (expectOk) {
            vm.expectCall(
                address(manager), abi.encodeCall(IPoolManager.unlock, (abi.encode(sender, recipient, amount))), 1
            );
        }
        bytes32 flagBefore = _flag();
        uint256 recBefore = recipient.balance;
        uint256 claimBefore = manager.balanceOf(sender, 0);
        (bool ok,) = _redeem(sender, recipient, amount);
        if (expectOk) assertTrue(ok);
        if (ok) {
            assertEq(flagBefore, bytes32(0));
            assertTrue(recipient != address(0));
            assertTrue(amount != 0);
            assertEq(_flag(), bytes32(0));
            // the owner word handed to the pool manager was msg.sender: its claim paid for the redemption
            assertEq(manager.balanceOf(sender, 0), claimBefore - amount);
            if (recipient != address(manager)) assertEq(recipient.balance, recBefore + amount);
        }
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsRedeem.lean:88 — redeem reverts iff _redeeming, recipient == 0, amount == 0,
    ///         or unlock(abi.encode(msg.sender, recipient, amount)) from the locked world reverts.
    function testFuzz_redeem_reverts_iff(
        address sender,
        bool senderIsAlice,
        bool locked,
        address recipient,
        uint256 amount,
        uint96 claim,
        uint256 allow
    ) public {
        _state(claim, allow);
        if (senderIsAlice) sender = alice;
        if (amount % 2 == 0) amount = bound(amount, 0, uint256(claim) + 1);
        if (locked) vm.store(address(claims), REDEEMING_SLOT, bytes32(uint256(1)));
        Oracle memory o = _oracle(sender, recipient, amount);
        bool rhs = locked || recipient == address(0) || amount == 0 || !o.ok;
        (bool ok,) = _redeem(sender, recipient, amount);
        assertEq(!ok, rhs);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsRedeem.lean:109 — during the pool-manager call _redeeming is true, and after
    ///         a successful redeem it is false again.
    function testFuzz_redeem_ok_state(uint96 claim, uint256 amount) public {
        claim = uint96(bound(claim, 1, type(uint96).max));
        amount = bound(amount, 1, claim);
        _state(claim, type(uint256).max);
        NCRProbe probe = new NCRProbe(claims);
        probe.arm(address(0), 0);
        vm.prank(alice);
        claims.redeem(address(probe), amount);
        assertTrue(probe.nestedTried());
        assertEq(probe.seenFlag(), bytes32(uint256(1)), "_redeeming = true during the call");
        assertEq(_flag(), bytes32(0), "_redeeming = false after success");
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsRedeem.lean:117 — any nested redeem(r', a') from the locked world reverts
    ///         ReentrantRedemption (whatever r', a').
    function testFuzz_redeem_nested_reverts(uint96 claim, uint256 amount, address r2, uint256 a2) public {
        claim = uint96(bound(claim, 1, type(uint96).max));
        amount = bound(amount, 1, claim);
        _state(claim, type(uint256).max);
        NCRProbe probe = new NCRProbe(claims);
        probe.arm(r2, a2);
        vm.prank(alice);
        claims.redeem(address(probe), amount);
        assertTrue(probe.nestedTried());
        assertFalse(probe.nestedOk());
        assertEq(probe.nestedRet(), abi.encodeWithSelector(NativeClaims.ReentrantRedemption.selector));
    }
}
