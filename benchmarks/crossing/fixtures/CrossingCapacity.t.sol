// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetupHook} from "../../../compat/current/test/SetupHook.t.sol";
import {MockERC20} from "../../../compat/current/test/utils/MockERC20.sol";
import {AsyncSwap} from "../../../reference/contracts/src/AsyncSwap.sol";
import {AsyncOrder} from "../../../reference/contracts/src/types/AsyncOrder.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Setup is exported; only independent Anvil transaction receipts measure capacity.
contract CrossingCapacityTest is SetupHook {
    uint256 constant COUNT = 100;
    uint256 constant SIZE = 1 ether;
    uint256 constant BID = 100_000;

    function setUp() public override {
        _deployManager();
        _deployFixtureTokens();
        _deployRouter();
        _deployHook();
        _createKey();
        _initializePool();
        _mintToOwner();
    }

    function _deployFixtureTokens() internal {
        // Fixed ordering gives the fixture a real 18-decimal asset and 6-decimal quote.
        deployCodeTo(
            "compat/current/test/utils/MockERC20.sol:MockERC20",
            abi.encode("Asset", "ASSET", uint8(18)),
            address(0x100000)
        );
        deployCodeTo(
            "compat/current/test/utils/MockERC20.sol:MockERC20",
            abi.encode("Quote", "QUOTE", uint8(6)),
            address(0x200000)
        );
        token0 = MockERC20(address(0x100000));
        token1 = MockERC20(address(0x200000));
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function _fund(address actor) internal {
        topUp(actor, 1e25);
        vm.prank(actor);
        token0.approve(address(router), type(uint256).max);
    }

    function _data(address actor, bool sell, uint256 input, uint256 minimum) internal view returns (bytes memory) {
        AsyncOrder memory order = AsyncOrder(key, actor, sell, input, minimum, BID, 2 ** 96, bytes32(0));
        return
            abi.encodeCall(router.swap, (order, abi.encode(AsyncSwap.UserParams(actor, address(router), minimum, BID))));
    }

    function _quote(uint256 group, bool restingSell, bool distinct) internal pure returns (uint256) {
        if (!distinct) return 1000e6;
        // Traverse ascending asks or descending bids, removing one price level per incoming transaction.
        return (restingSell ? 1000 + group * 10 : 2000 - group * 10) * 1e6;
    }

    function _export(string memory name, uint256 depth, bool restingSell, bool distinct) internal {
        _exportBook(name, depth, restingSell, distinct, false);
    }

    function _makerQuote(uint256 index, uint256 depth, bool restingSell, bool distinct, bool perMaker)
        internal
        pure
        returns (uint256)
    {
        if (perMaker) return (restingSell ? 1000 + index : 2000 - index) * 1e6;
        return _quote(index / depth, restingSell, distinct);
    }

    function _exportBook(string memory name, uint256 depth, bool restingSell, bool distinct, bool perMaker) internal {
        for (uint256 i; i < COUNT * depth; ++i) {
            address actor = address(uint160(0x300000 + i));
            _fund(actor);
            uint256 quote = _makerQuote(i, depth, restingSell, distinct, perMaker);
            uint256 input = restingSell ? SIZE : quote;
            uint256 minimum = restingSell ? quote : SIZE;
            vm.prank(actor);
            (bool ok,) = address(router).call(_data(actor, restingSell, input, minimum));
            require(ok, "Resting order failed");
            bytes32 id = _orderIdFor(actor, restingSell, _expectedSalt(actor, input, minimum));
            assertEq(hook.asyncOrder(poolId, id), input);
            console2.log(
                string.concat("MAKER|", name, "|", vm.toString(actor), "|", vm.toString(id), "|", vm.toString(quote))
            );
        }
        for (uint256 i; i < COUNT; ++i) {
            address actor = address(uint160(0x400000 + i));
            _fund(actor);
            uint256 quote;
            for (uint256 j; j < depth; ++j) {
                quote += _makerQuote(i * depth + j, depth, restingSell, distinct, perMaker);
            }
            uint256 input = restingSell ? quote : depth * SIZE;
            uint256 minimum = restingSell ? depth * SIZE : quote;
            // Allow every price in this eight-level sweep while consuming exactly the seeded inputs.
            if (perMaker) minimum = minimum * 9 / 10;
            bytes memory data = _data(actor, !restingSell, input, minimum);
            console2.log(string.concat("TX|", name, "|", vm.toString(actor), "|", vm.toString(data)));
        }
        vm.etch(address(router), address(router).code);
        vm.etch(address(token0), address(token0).code);
        vm.etch(address(token1), address(token1).code);
        hook.asyncOrders(poolId);
        // Include the linked view library even when memory admission never calls it.
        hook.bestOrder(poolId, true);
        hook.bestOrder(poolId, false);
        vm.dumpState(string.concat("deployments/crossing-", name, ".json"));
        console2.log(
            string.concat(
                "META|",
                name,
                "|",
                vm.toString(address(router)),
                "|",
                vm.toString(address(hook)),
                "|",
                vm.toString(address(manager)),
                "|",
                vm.toString(address(hook.feeVault())),
                "|",
                vm.toString(PoolId.unwrap(poolId))
            )
        );
    }

    function test_exportBuyOneSame() public {
        _export("buy_one_same", 1, true, false);
    }

    function test_exportSellOneSame() public {
        _export("sell_one_same", 1, false, false);
    }

    function test_exportBuyEightSame() public {
        _export("buy_eight_same", 8, true, false);
    }

    function test_exportSellEightSame() public {
        _export("sell_eight_same", 8, false, false);
    }

    function test_exportBuyOneDistinct() public {
        _export("buy_one_distinct", 1, true, true);
    }

    function test_exportSellOneDistinct() public {
        _export("sell_one_distinct", 1, false, true);
    }

    function test_exportBuyEightDistinct() public {
        _export("buy_eight_distinct", 8, true, true);
    }

    function test_exportSellEightDistinct() public {
        _export("sell_eight_distinct", 8, false, true);
    }

    function test_exportBuyEightLevels() public {
        _exportBook("buy_eight_levels", 8, true, true, true);
    }

    function test_exportSellEightLevels() public {
        _exportBook("sell_eight_levels", 8, false, true, true);
    }
}
