// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../../SetupHook.t.sol";
import {Permit2Bytecode} from "../../utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface IPermit2DomainPoc {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev Signed-order helpers copied from test/SignedOrders.t.sol (not inherited, so its tests do not rerun here).
abstract contract PocSignedBase is SetupHook {
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH_POC = keccak256("TokenPermissions(address token,uint256 amount)");

    uint256 makerPk = 0xA11CE;
    address maker;
    address relayer = makeAddr("relayer");
    address attacker = makeAddr("attacker");
    address bob = makeAddr("bob");

    uint256 constant AMOUNT_IN = 1 ether;
    uint256 constant AMOUNT_OUT_MIN = 0.95 ether;

    function setUp() public virtual override {
        super.setUp();
        vm.etch(Permit2Bytecode.PERMIT2, Permit2Bytecode.RUNTIME);
        maker = vm.addr(makerPk);
        vm.prank(owner);
        token0.transfer(maker, 10 ether);
        token1.mint(maker, 1 ether);
        vm.prank(maker);
        token1.approve(address(router), type(uint256).max);
        vm.prank(maker);
        token0.approve(Permit2Bytecode.PERMIT2, type(uint256).max);
        topUp(bob, 100 ether);
        topUp(attacker, 100 ether);
    }

    function _signedOrder(uint256 amountOutMin) internal view returns (AsyncOrder memory) {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: true,
            amountIn: AMOUNT_IN,
            amountOutMin: amountOutMin,
            priorityFee: 100_000,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _permit(AsyncOrder memory order, uint256 nonce, uint256 deadline)
        internal
        view
        returns (Router.PermitData memory)
    {
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                OrderSignatures.PERMIT2_WITNESS_TYPE
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typehash,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH_POC, Currency.unwrap(currency0), order.amountIn)),
                address(router),
                nonce,
                deadline,
                OrderSignatures.hashOrder(order)
            )
        );
        bytes32 digest = _digest(IPermit2DomainPoc(Permit2Bytecode.PERMIT2).DOMAIN_SEPARATOR(), structHash);
        return Router.PermitData({nonce: nonce, deadline: deadline, signature: _sign(digest)});
    }

    function _grant(uint256 nonce, uint256 deadline) internal view returns (Router.ExecutorGrant memory) {
        bytes32 structHash = OrderSignatures.hashSetExecutor(key, maker, address(router), true, nonce, deadline);
        return Router.ExecutorGrant({
            nonce: nonce, deadline: deadline, signature: _sign(_digest(hook.DOMAIN_SEPARATOR(), structHash))
        });
    }

    function _id(AsyncOrder memory order) internal view returns (bytes32) {
        return _orderIdFor(order.owner, order.zeroForOne, order.salt);
    }

    function _cancelSig(AsyncOrder memory order, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        bytes32 structHash = OrderSignatures.hashCancel(
            order, _id(order), hook.orderCreatedSequence(poolId, _id(order)), nonce, deadline
        );
        return _sign(_digest(router.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev A maker's signed reprice of `order` from `amountIn` to `newAmountOutMin`, against its current reprice count.
    function _repriceSig(
        AsyncOrder memory order,
        uint256 amountIn,
        uint256 newAmountOutMin,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 id = _id(order);
        bytes32 structHash = OrderSignatures.hashUpdatePrice(
            order,
            id,
            amountIn,
            newAmountOutMin,
            hook.orderCreatedSequence(poolId, id),
            hook.orderReprices(poolId, id),
            nonce,
            deadline
        );
        return _sign(_digest(hook.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev Plain Router order (RouterMulticall pattern), salt predicted.
    function _plainOrder(address who, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 priorityFee)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: who,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: priorityFee,
            sqrtPrice: 2 ** 96,
            salt: keccak256(
                abi.encode(block.timestamp, block.number, address(manager), who, amountIn, amountOutMin, priorityFee)
            )
        });
    }

    function _submit(AsyncOrder memory order) internal {
        MockERC20 input = order.zeroForOne ? token0 : token1;
        vm.startPrank(order.owner);
        input.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: order.owner,
                    executor: address(router),
                    amountOutMin: order.amountOutMin,
                    priorityFee: order.priorityFee
                })
            )
        );
        vm.stopPrank();
    }
}
