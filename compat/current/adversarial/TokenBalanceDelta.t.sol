// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {SetupHook} from "../test/SetupHook.t.sol";
import {MockERC20} from "../test/utils/MockERC20.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @dev Matches MockERC20 storage; transfer success alone must not establish payment success.
contract BalanceFaultToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public shortfall;
    uint256 public extraDebit;
    bool public faultFrom;
    address public observer;

    constructor(uint8 d) {
        decimals = d;
    }

    function configure(uint256 missing, uint256 extra, bool from, address callback) external {
        shortfall = missing;
        extraDebit = extra;
        faultFrom = from;
        observer = callback;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount, !faultFrom);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount, faultFrom);
        return true;
    }

    function _move(address from, address to, uint256 amount, bool fault) internal {
        uint256 missing = fault ? shortfall : 0;
        uint256 extra = fault ? extraDebit : 0;
        balanceOf[from] -= amount + extra;
        balanceOf[to] += amount - missing;
        totalSupply -= extra + missing;
        if (observer != address(0)) {
            (bool ok,) = observer.call(abi.encodeWithSignature("onTransfer()"));
            require(ok);
        }
    }
}

contract TransferObserver {
    uint256 public callbacks;

    function onTransfer() external {
        ++callbacks;
    }
}

contract TokenBalanceDeltaTest is SetupHook {
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    bytes4 constant UNSUPPORTED = bytes4(keccak256("TokenNotSupported(address)"));

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
        vm.prank(alice);
        token0.approve(address(router), type(uint256).max);
        vm.prank(bob);
        token0.approve(address(router), type(uint256).max);
    }

    function _order(address maker, bool sell) internal view returns (AsyncOrder memory) {
        return AsyncOrder(key, maker, sell, 1 ether, 1 ether, 100_000, 2 ** 96, 0);
    }

    function _submit(address maker, bool sell) internal returns (AsyncOrder memory o) {
        o = _order(maker, sell);
        vm.prank(maker);
        router.swap(o, abi.encode(AsyncSwap.UserParams(maker, address(router), o.amountOutMin, o.priorityFee)));
        o.salt = _expectedSalt(maker, o.amountIn, o.amountOutMin);
    }

    function _fault(MockERC20 token, uint256 missing, uint256 extra, bool from) internal returns (BalanceFaultToken t) {
        t = new BalanceFaultToken(token.decimals());
        vm.etch(address(token), address(t).code);
        t = BalanceFaultToken(address(token));
        t.configure(missing, extra, from, address(0));
    }

    function _cancelReverts(uint256 missing, uint256 extra) internal {
        AsyncOrder memory o = _submit(alice, true);
        _submit(bob, true);
        _fault(token0, missing, extra, false);
        uint256 wallet = token0.balanceOf(alice);
        uint256 backing = token0.balanceOf(address(manager));
        uint256 escrow = manager.balanceOf(address(hook), uint160(address(token0)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UNSUPPORTED, address(token0)));
        router.cancelOrder(o);
        assertEq(token0.balanceOf(alice), wallet, "failed payout restores recipient balance");
        assertEq(token0.balanceOf(address(manager)), backing, "failed payout cannot consume another order's backing");
        assertEq(manager.balanceOf(address(hook), uint160(address(token0))), escrow, "claims restored");
        assertEq(hook.asyncOrder(poolId, _orderIdFor(alice, true, o.salt)), 1 ether, "order restored");
    }

    function testFuzz_cancelRejectsShortReceipt(uint64 missing) public {
        _cancelReverts(bound(missing, 1, 1000), 0);
    }

    function testFuzz_cancelRejectsExtraCustodyDebit(uint64 extra) public {
        _cancelReverts(0, bound(extra, 1, 1000));
    }

    function testFuzz_swapRejectsExtraSenderDebit(uint64 extra) public {
        _fault(token0, 0, bound(extra, 1, 1000), true);
        AsyncOrder memory o = _order(alice, true);
        uint256 wallet = token0.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UNSUPPORTED, address(token0)));
        router.swap(o, abi.encode(AsyncSwap.UserParams(alice, address(router), o.amountOutMin, o.priorityFee)));
        assertEq(token0.balanceOf(alice), wallet, "extra sender charge rolls back");
        assertEq(token0.balanceOf(address(manager)), 0, "failed deposit rolls back custody");
        assertEq(manager.balanceOf(address(hook), uint160(address(token0))), 0, "failed deposit creates no claims");
    }

    function testFuzz_fillRejectsShortMakerReceipt(uint64 missing) public {
        AsyncOrder memory o = _submit(alice, true);
        _fault(token1, bound(missing, 1, 1000), 0, false);
        uint256 wallet = token1.balanceOf(alice);
        uint256 payer = token1.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(UNSUPPORTED, address(token1)));
        router.fillOrder(o, 1 ether, "");
        assertEq(token1.balanceOf(alice), wallet, "maker payment rolls back");
        assertEq(token1.balanceOf(bob), payer, "filler payment refunded");
        assertEq(hook.asyncOrder(poolId, _orderIdFor(alice, true, o.salt)), 1 ether, "fill rolls back");
    }

    function testFuzz_withdrawRejectsShortReceipt(uint64 missing) public {
        _submit(alice, true);
        _submit(bob, false);
        uint256 claims = manager.balanceOf(alice, uint160(address(token1)));
        assertGt(claims, 1000, "real matched claim required");
        _fault(token1, bound(missing, 1, 1000), 0, false);
        Currency[] memory cs = new Currency[](1);
        cs[0] = currency1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claims;
        vm.prank(alice);
        manager.approve(address(router), uint160(address(token1)), claims);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UNSUPPORTED, address(token1)));
        router.withdrawClaims(cs, amounts);
        assertEq(manager.balanceOf(alice, uint160(address(token1))), claims, "short withdrawal restores claims");
        assertEq(
            manager.allowance(alice, address(router), uint160(address(token1))),
            claims,
            "short withdrawal restores allowance"
        );
    }

    function test_LP_shortOutputBubblesUnsupportedInsteadOfRestingOrder() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.startPrank(owner);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e24, 0), "");
        vm.stopPrank();
        _fault(token1, 1, 0, false);
        AsyncOrder memory o = _order(alice, true);
        o.amountOutMin = 0.5 ether;
        uint256 before = token0.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UNSUPPORTED, address(token1)));
        router.swap(o, abi.encode(AsyncSwap.UserParams(alice, address(router), o.amountOutMin, o.priorityFee)));
        assertEq(token0.balanceOf(alice), before, "unsupported LP payout rolls back incoming funding");
        assertEq(manager.balanceOf(address(hook), uint160(address(token0))), 0, "unsupported order is not left resting");
    }

    function test_callbackWithExactDeliverySucceeds() public {
        AsyncOrder memory o = _submit(alice, true);
        TransferObserver observer = new TransferObserver();
        BalanceFaultToken token = _fault(token0, 0, 0, false);
        token.configure(0, 0, false, address(observer));
        uint256 before = token0.balanceOf(alice);
        vm.prank(alice);
        router.cancelOrder(o);
        assertEq(token0.balanceOf(alice), before + 1 ether, "exact delivery despite callback");
        assertEq(observer.callbacks(), 1, "callback really executed");
    }
}
