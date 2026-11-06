// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {TokenClaims} from "@async-swap/TokenClaims.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

interface ITokenReceiver {
    function onTokenReceived() external;
}

/// @notice ERC20 that refuses transfers to one address and calls back one other on receipt.
contract HookedERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public blocked;
    address public observer;

    function setBlocked(address who) external {
        blocked = who;
    }

    function setObserver(address who) external {
        observer = who;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != blocked, "blocked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to == observer) ITokenReceiver(to).onTokenReceived();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Recipient that tries to redeem again while its first redemption is being paid out.
contract ReenteringRedeemer is ITokenReceiver {
    TokenClaims immutable claims;
    Currency immutable currency;
    bool public blocked;
    bytes4 public reentryError;

    constructor(TokenClaims _claims, Currency _currency) {
        claims = _claims;
        currency = _currency;
    }

    function onTokenReceived() external {
        try claims.redeem(currency, address(this), 1) {}
        catch (bytes memory reason) {
            blocked = true;
            if (reason.length >= 4) reentryError = bytes4(reason);
        }
    }
}

/// @notice `TokenClaims` redeems the ERC-6909 claims that direct matches credit, end to end.
contract TokenClaimsTest is SetupHook {
    using PoolIdLibrary for PoolKey;

    uint256 constant AMOUNT = 10 ether;
    /// @dev What each side of an AMOUNT-for-AMOUNT match is credited: AMOUNT less the 0.02% trade fee, rounded up.
    uint256 constant CREDITED = AMOUNT - (AMOUNT * 2 + 9_999) / 10_000;

    address alice = makeAddr("alice"); // seller of token0
    address bob = makeAddr("bob"); // buyer of token0
    address carol = makeAddr("carol"); // redemption recipient

    TokenClaims claims;

    event ClaimsRedeemed(address indexed owner, address indexed recipient, Currency indexed currency, uint256 amount);

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
        claims = new TokenClaims(manager);
    }

    function _swap(PoolKey memory poolKey, address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
    {
        AsyncOrder memory order = AsyncOrder(poolKey, maker, zeroForOne, amountIn, amountOutMin, 100_000, 2 ** 96, 0);
        vm.prank(maker);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), amountOutMin, 100_000)));
    }

    /// @dev Alice sells AMOUNT token0 to Bob at 1:1: Alice is credited token1 claims, Bob token0 claims.
    function _match() internal {
        vm.prank(alice);
        token0.approve(address(router), AMOUNT);
        _swap(key, alice, true, AMOUNT, AMOUNT);
        _swap(key, bob, false, AMOUNT, AMOUNT);
        assertEq(manager.balanceOf(alice, currency1.toId()), CREDITED, "seller credited quote claims");
        assertEq(manager.balanceOf(bob, currency0.toId()), CREDITED, "buyer credited asset claims");
    }

    function test_redeemPartialToChosenRecipientThenNoDoubleSpend() public {
        _match();
        vm.startPrank(alice);
        manager.approve(address(claims), currency1.toId(), CREDITED);

        vm.expectEmit(true, true, true, true, address(claims));
        emit ClaimsRedeemed(alice, carol, currency1, 4 ether);
        claims.redeem(currency1, carol, 4 ether);
        assertEq(manager.balanceOf(alice, currency1.toId()), CREDITED - 4 ether, "claims burned");
        assertEq(token1.balanceOf(carol), 4 ether, "recipient paid in ERC20");

        claims.redeem(currency1, carol, CREDITED - 4 ether);
        vm.expectRevert();
        claims.redeem(currency1, carol, 1);
        vm.stopPrank();

        assertEq(manager.balanceOf(alice, currency1.toId()), 0);
        assertEq(token1.balanceOf(carol), CREDITED);
        assertEq(manager.allowance(alice, address(claims), currency1.toId()), 0, "allowance consumed");
    }

    function test_redeemsEachCurrencySeparately() public {
        _match();
        uint256 bobToken0Before = token0.balanceOf(bob);
        vm.startPrank(bob);
        manager.approve(address(claims), currency0.toId(), AMOUNT);
        // Bob holds token0 claims only; token1 is a different claim id.
        vm.expectRevert();
        claims.redeem(currency1, bob, 1);
        claims.redeem(currency0, bob, CREDITED);
        vm.stopPrank();
        assertEq(token0.balanceOf(bob) - bobToken0Before, CREDITED);
        assertEq(manager.balanceOf(bob, currency0.toId()), 0);
    }

    function test_RevertWhen_RedeemingWithoutApproval() public {
        _match();
        vm.prank(alice);
        vm.expectRevert();
        claims.redeem(currency1, alice, 1 ether);
        assertEq(manager.balanceOf(alice, currency1.toId()), CREDITED);
    }

    function test_RevertWhen_RedeemingAnotherOwnersClaims() public {
        _match();
        vm.prank(alice);
        manager.approve(address(claims), currency1.toId(), AMOUNT);
        // The approval lets TokenClaims burn only the caller's own claims: Carol has none.
        vm.prank(carol);
        vm.expectRevert();
        claims.redeem(currency1, carol, 1 ether);
        assertEq(manager.balanceOf(alice, currency1.toId()), CREDITED);
        assertEq(token1.balanceOf(carol), 0);
    }

    function test_RevertWhen_InvalidRedemption() public {
        vm.expectRevert(TokenClaims.InvalidRedemption.selector);
        claims.redeem(currency1, address(0), 1);
        vm.expectRevert(TokenClaims.InvalidRedemption.selector);
        claims.redeem(currency1, carol, 0);
    }

    function test_RevertWhen_CallbackNotFromPoolManager() public {
        _match();
        vm.prank(alice);
        manager.approve(address(claims), currency1.toId(), AMOUNT);
        vm.expectRevert(TokenClaims.OnlyPoolManager.selector);
        claims.unlockCallback(abi.encode(alice, currency1, carol, AMOUNT));
        assertEq(manager.balanceOf(alice, currency1.toId()), CREDITED);
    }

    /* ---------------------------- token with transfer hooks ---------------------------- */

    HookedERC20 hooked;
    PoolKey hookedKey;

    /// @dev A second pool, the hooked token against the numeraire. Bob sells hooked tokens to Alice,
    ///      so Alice is credited hooked-token claims.
    function _matchHooked() internal returns (Currency hookedCurrency) {
        hooked = new HookedERC20();
        hookedCurrency = Currency.wrap(address(hooked));
        bool hookedIsZero = address(hooked) < Currency.unwrap(currency1);
        hookedKey = PoolKey({
            currency0: hookedIsZero ? hookedCurrency : currency1,
            currency1: hookedIsZero ? currency1 : hookedCurrency,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: hook
        });
        manager.initialize(hookedKey, 2 ** 96);
        PoolId hookedPoolId = hookedKey.toId();

        hooked.mint(bob, AMOUNT);
        vm.startPrank(bob);
        hook.setExecutor(hookedPoolId, address(router), true);
        hooked.approve(address(router), AMOUNT);
        vm.stopPrank();
        vm.prank(alice);
        hook.setExecutor(hookedPoolId, address(router), true);

        _swap(hookedKey, bob, hookedIsZero, AMOUNT, AMOUNT);
        _swap(hookedKey, alice, !hookedIsZero, AMOUNT, AMOUNT);
        assertEq(manager.balanceOf(alice, hookedCurrency.toId()), CREDITED, "buyer credited hooked claims");
    }

    function test_failedTransferPreservesClaimsAndAllowance() public {
        Currency hc = _matchHooked();
        hooked.setBlocked(carol);
        vm.startPrank(alice);
        manager.approve(address(claims), hc.toId(), AMOUNT);
        vm.expectRevert();
        claims.redeem(hc, carol, CREDITED);
        assertEq(manager.balanceOf(alice, hc.toId()), CREDITED, "claims restored");
        assertEq(manager.allowance(alice, address(claims), hc.toId()), AMOUNT, "allowance restored");

        // The same claims redeem to an address the token accepts.
        claims.redeem(hc, alice, CREDITED);
        vm.stopPrank();
        assertEq(hooked.balanceOf(alice), CREDITED);
        assertEq(manager.balanceOf(alice, hc.toId()), 0);
    }

    function test_reentrantRedemptionIsBlocked() public {
        Currency hc = _matchHooked();
        ReenteringRedeemer recipient = new ReenteringRedeemer(claims, hc);
        hooked.setObserver(address(recipient));
        vm.startPrank(alice);
        manager.approve(address(claims), hc.toId(), AMOUNT);
        claims.redeem(hc, address(recipient), CREDITED);
        vm.stopPrank();
        assertTrue(recipient.blocked(), "nested redeem was attempted and failed");
        assertEq(recipient.reentryError(), TokenClaims.ReentrantRedemption.selector);
        assertEq(hooked.balanceOf(address(recipient)), CREDITED);
        assertEq(manager.balanceOf(alice, hc.toId()), 0);
    }
}
