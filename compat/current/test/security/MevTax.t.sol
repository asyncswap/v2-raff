// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {PocSignedBase} from "./poc/PocSignedBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @notice The Router's MEV tax ("Priority Is All You Need", Robinson & White): every order creation and fill pays
///         `(tx.gasprice - block.basefee) * MEV_TAX_GAS` wei to the FeeVault as native claims. A transaction that bids
///         no priority pays nothing; one racing for position pays the protocol for it.
contract MevTaxTest is SetupHook {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant BASEFEE = 1 gwei;
    uint256 constant PRIORITY = 0.01 gwei;
    uint256 constant BID = 100_000;

    function setUp() public virtual override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.prank(alice);
        token0.approve(address(router), type(uint256).max);
        vm.prank(bob);
        token0.approve(address(router), type(uint256).max);
        vm.fee(BASEFEE);
    }

    function _vaultEth() internal view returns (uint256) {
        return manager.balanceOf(address(hook.feeVault()), 0);
    }

    function _order(address who, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder(key, who, zeroForOne, amountIn, amountOutMin, BID, 2 ** 96, bytes32(0));
    }

    function _swap(AsyncOrder memory o, uint256 value) internal {
        vm.prank(o.owner);
        router.swap{value: value}(o, abi.encode(AsyncSwap.UserParams(o.owner, address(router), o.amountOutMin, BID)));
    }

    function test_taxIsPriorityTimesTaxGas() public {
        vm.txGasPrice(BASEFEE + PRIORITY);
        assertEq(router.mevTax(), PRIORITY * router.MEV_TAX_GAS());
        vm.txGasPrice(BASEFEE);
        assertEq(router.mevTax(), 0, "no priority, no tax");
    }

    function test_noPriorityPaysNothing() public {
        vm.txGasPrice(BASEFEE);
        _swap(_order(alice, true, 1 ether, 0.9 ether), 0);
        assertEq(_vaultEth(), 0);
    }

    function test_swapPaysTheTaxToTheVault() public {
        vm.txGasPrice(BASEFEE + PRIORITY);
        uint256 tax = router.mevTax();
        assertGt(tax, 0);

        vm.expectRevert(bytes("msg.value != deposit + mevTax"));
        _swap(_order(alice, true, 1 ether, 0.9 ether), 0);

        vm.expectEmit(address(router));
        emit Router.MevTaxPaid(alice, tax);
        _swap(_order(alice, true, 1 ether, 0.9 ether), tax);
        assertEq(_vaultEth(), tax, "tax credited to the FeeVault as native claims");
        assertEq(address(router).balance, 0, "the Router keeps no ETH");
    }

    function test_fillOrderPaysTheTax() public {
        vm.txGasPrice(BASEFEE);
        AsyncOrder memory o = _order(alice, true, 1 ether, 0.9 ether);
        _swap(o, 0);
        o.salt = _expectedSalt(alice, 1 ether, 0.9 ether);

        vm.txGasPrice(BASEFEE + PRIORITY);
        uint256 tax = router.mevTax();
        vm.prank(bob);
        vm.expectRevert(bytes("msg.value != deposit + mevTax"));
        router.fillOrder(o, type(uint256).max, "");

        vm.prank(bob);
        router.fillOrder{value: tax}(o, type(uint256).max, "");
        assertEq(hook.asyncOrder(poolId, _orderIdFor(alice, true, o.salt)), 0, "filled");
        assertEq(_vaultEth(), tax);
    }

    function test_poolRetryPaysTheTax() public {
        vm.txGasPrice(BASEFEE);
        AsyncOrder memory o = _order(alice, true, 1 ether, 0.9 ether);
        _swap(o, 0); // no liquidity yet: rests
        o.salt = _expectedSalt(alice, 1 ether, 0.9 ether);
        _addLiquidity();

        vm.txGasPrice(BASEFEE + PRIORITY);
        uint256 tax = router.mevTax();
        vm.prank(bob);
        vm.expectRevert(bytes("msg.value != deposit + mevTax"));
        router.fillFromPoolLiquidity(o);

        vm.prank(bob);
        router.fillFromPoolLiquidity{value: tax}(o);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(alice, true, o.salt)), 0, "filled from the pool");
        assertEq(_vaultEth(), tax);
    }

    /// Cancels, claims and book cranks are not taxed: a maker racing to protect an order pays only gas.
    function test_cancelIsNotTaxed() public {
        vm.txGasPrice(BASEFEE);
        AsyncOrder memory o = _order(alice, true, 1 ether, 0.9 ether);
        _swap(o, 0);
        o.salt = _expectedSalt(alice, 1 ether, 0.9 ether);

        vm.txGasPrice(BASEFEE + PRIORITY);
        vm.prank(alice);
        router.cancelOrder(o);
        router.matchBook(key, 1);
        assertEq(_vaultEth(), 0);
    }

    /// `multicall` is not payable: a taxed action inside it needs a transaction with no priority.
    function test_multicallTaxedActionNeedsNoPriority() public {
        bytes[] memory calls = new bytes[](1);
        AsyncOrder memory o = _order(alice, true, 1 ether, 0.9 ether);
        calls[0] =
            abi.encodeCall(Router.swap, (o, abi.encode(AsyncSwap.UserParams(alice, address(router), 0.9 ether, BID))));

        vm.txGasPrice(BASEFEE + PRIORITY);
        vm.prank(alice);
        vm.expectRevert(bytes("msg.value != deposit + mevTax"));
        router.multicall(calls);

        vm.txGasPrice(BASEFEE);
        vm.prank(alice);
        router.multicall(calls);
    }

    function _addLiquidity() internal {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-887272, 887272, 1e24, 0), "");
    }
}

/// @notice A relayer submitting a signed order pays the tax for its own priority.
contract MevTaxSignedTest is PocSignedBase {
    function test_relayerPaysTheTax() public {
        vm.fee(1 gwei);
        vm.txGasPrice(1.01 gwei);
        uint256 tax = router.mevTax();
        vm.deal(relayer, tax);
        AsyncOrder memory order = _signedOrder(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        Router.ExecutorGrant memory none;
        vm.prank(maker);
        hook.setExecutor(poolId, address(router), true);

        vm.prank(relayer);
        vm.expectRevert(bytes("msg.value != deposit + mevTax"));
        router.swapWithSig(order, permit, none);

        vm.prank(relayer);
        router.swapWithSig{value: tax}(order, permit, none);
        assertEq(manager.balanceOf(address(hook.feeVault()), 0), tax);
    }
}
