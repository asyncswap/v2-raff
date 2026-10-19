// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {OrderSignatures} from "./reference/OrderSignatures.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./reference/AsyncOrder.sol";

/// @dev Spec: `AsyncSwapSpec/Hashing.lean` — the type strings and what each hash binds.
contract OrderSignaturesTest is Test {
    using AsyncOrderLibrary for AsyncOrder;

    PoolKey k = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3000, 60, IHooks(address(0x88)));

    function _o() internal view returns (AsyncOrder memory) {
        return AsyncOrder(k, address(0xA), true, 1e18, 2e18, 5, 12345, bytes32(uint256(7)));
    }

    function test_typeStringsMatchSpec() public pure {
        assertEq(
            keccak256(bytes(OrderSignatures.permit2WitnessType())),
            keccak256(
                "AsyncOrder witness)AsyncOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,uint256 priorityFee,PoolKey pool)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)TokenPermissions(address token,uint256 amount)"
            )
        );
        assertEq(
            OrderSignatures.asyncOrderTypehash(),
            keccak256(
                "AsyncOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,uint256 priorityFee,PoolKey pool)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)"
            )
        );
        assertEq(
            OrderSignatures.setExecutorTypehash(),
            keccak256(
                "SetExecutor(address maker,address executor,bool allow,PoolKey pool,uint256 nonce,uint256 deadline)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)"
            )
        );
    }

    /// `hashOrder_inj`: the witness binds maker, tokens, amounts, bid and pool — not `sqrtPrice` nor `salt`.
    function test_witnessBinding() public view {
        AsyncOrder memory a = _o();
        AsyncOrder memory b = _o();
        b.sqrtPrice = 999;
        b.salt = bytes32(uint256(8));
        assertEq(OrderSignatures.hashOrder(a), OrderSignatures.hashOrder(b), "sqrtPrice and salt not covered");

        AsyncOrder memory c = _o();
        c.amountIn = 1e18 + 1;
        assertNotEq(OrderSignatures.hashOrder(a), OrderSignatures.hashOrder(c));
        c = _o();
        c.priorityFee = 6;
        assertNotEq(OrderSignatures.hashOrder(a), OrderSignatures.hashOrder(c));
        c = _o();
        c.zeroForOne = false;
        assertNotEq(OrderSignatures.hashOrder(a), OrderSignatures.hashOrder(c), "direction via tokens");
        c = _o();
        c.key.fee = 500;
        assertNotEq(OrderSignatures.hashOrder(a), OrderSignatures.hashOrder(c), "pool");
    }

    /// `orderId_inj`: an id fixes chain, pool, maker, direction and salt — not the amounts.
    function test_orderIdBinding() public view {
        AsyncOrder memory a = _o();
        AsyncOrder memory b = _o();
        b.amountIn = 5;
        b.amountOutMin = 6;
        b.priorityFee = 0;
        assertEq(a.orderId(), b.orderId());
        b = _o();
        b.salt = bytes32(uint256(8));
        assertNotEq(a.orderId(), b.orderId());
        b = _o();
        b.zeroForOne = false;
        assertNotEq(a.orderId(), b.orderId());
    }

    /// Type separation: no struct hash of one type equals one of another.
    function test_typeSeparation() public view {
        AsyncOrder memory o = _o();
        bytes32 h1 = OrderSignatures.hashOrder(o);
        bytes32 h2 = OrderSignatures.hashSetExecutor(k, o.owner, address(0xB), true, 1, 2);
        bytes32 h3 = OrderSignatures.hashUpdatePrice(k, o.owner, true, 1e18, 3e18, o.orderId(), 1, 2);
        bytes32 h4 = OrderSignatures.hashCancel(k, o.owner, true, 1e18, o.orderId(), 1, 2);
        bytes32 h5 = OrderSignatures.hashPoolKey(k);
        assertTrue(h1 != h2 && h1 != h3 && h1 != h4 && h1 != h5 && h2 != h3 && h2 != h4 && h3 != h4);
    }
}
