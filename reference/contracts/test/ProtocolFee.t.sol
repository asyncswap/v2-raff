// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {SetupHook} from "./SetupHook.t.sol";

contract ProtocolFeeTest is SetupHook {
    function _fee(uint256 x) internal pure returns (uint256) {
        return Math.mulDiv(x, 2, 10_000, Math.Rounding.Ceil);
    }

    function test_fillPaysMinimumAndChargesTradeFeeBothSides() public {
        address maker = makeAddr("maker");
        address filler = makeAddr("filler");
        topUp(maker, 1 ether);
        topUp(filler, 100_000_000);
        AsyncOrder memory order = AsyncOrder(key, maker, true, 1 ether, 99_700_000, 100_000, 2 ** 96, bytes32(0));
        vm.startPrank(maker);
        token0.approve(address(router), 1 ether);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), 99_700_000, 100_000)));
        vm.stopPrank();
        order.salt = _expectedSalt(maker, 1 ether, 99_700_000);
        uint256 makerBefore = token1.balanceOf(maker);
        uint256 fillerBefore = token0.balanceOf(filler);
        vm.startPrank(filler);
        token1.approve(address(router), 100_000_000);
        vm.expectRevert("Price exceeds maxPrice");
        router.fillOrder(order, 99_699_999, "");
        assertEq(token1.balanceOf(filler), 100_000_000);
        router.fillOrder(order, 99_700_000, "");
        vm.stopPrank();
        assertEq(token1.balanceOf(maker) - makerBefore, 99_700_000 - _fee(99_700_000), "maker gets minimum less fee");
        assertEq(token0.balanceOf(filler) - fillerBefore, 1 ether - _fee(1 ether), "filler gets input less fee");
        assertEq(token1.balanceOf(filler), 100_000_000 - 99_700_000, "filler pays exactly the minimum");
        assertEq(manager.balanceOf(address(hook.feeVault()), currency0.toId()), _fee(1 ether));
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), _fee(99_700_000) + 100_000);
    }

    function test_noFillerSurcharge() public view {
        assertEq(hook.calculatePoolFee(0x800000, 0.997 ether), 0);
        assertEq(hook.calculatePoolFee(0x800000, 997_000), 0);
        assertEq(hook.calculatePoolFee(0x800000, 333), 0);
    }

    function testFuzz_noFillerSurcharge(uint24 lpFee, uint256 amount) public view {
        assertEq(hook.calculatePoolFee(lpFee, amount), 0);
    }
}
