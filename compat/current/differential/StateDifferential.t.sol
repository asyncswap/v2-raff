// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {NativeClaims} from "@async-swap/NativeClaims.sol";
import {TokenClaims} from "@async-swap/TokenClaims.sol";
import {FeeVault} from "@async-swap/FeeVault.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {MockERC20} from "../test/utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice Two snapshot worlds use identical addresses, calldata and signers. Only protocol bytecode differs.
/// @dev The controller lives in memory across snapshot restores, so neither world can overwrite the oracle.
abstract contract StateDifferentialTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    AsyncSwap internal constant HOOK = AsyncSwap(payable(address(0x2888)));
    Router internal constant ROUTER = Router(payable(address(0x90000)));
    NativeClaims internal constant NATIVE = NativeClaims(address(0x90001));
    TokenClaims internal constant CLAIMS = TokenClaims(address(0x90002));
    address internal constant EXECUTOR = address(0x90003);
    MockERC20 internal constant USDC = MockERC20(address(0x10000));
    MockERC20 internal constant ASSET = MockERC20(address(0x20000));
    uint256 internal constant ACTIONS = 18;
    bytes32 internal constant CREATED =
        keccak256("AsyncOrderCreated(bytes32,bytes32,address,bool,uint256,uint256,bytes32)");
    IPoolManager internal manager;
    PoolModifyLiquidityTest internal liquidity;
    PoolKey internal key;
    PoolId internal pid;
    address[4] internal actors;
    uint256 internal solidityWorld;
    uint256 internal huffWorld;

    struct Controller {
        uint256 sol;
        uint256 huff;
        AsyncOrder[] orders;
        uint256 count;
        uint128[] levels;
        uint256 levelCount;
        uint256[ACTIONS] attempts;
        uint256[ACTIONS] successes;
    }

    struct Action {
        uint8 kind;
        address target;
        address sender;
        uint256 value;
        bytes data;
        AsyncOrder order;
    }

    struct Observation {
        bytes32 orders;
        bytes32 levels;
        bytes32 balances;
        bytes32 pool;
        bytes32 permissions;
    }
    event Compared(uint256 indexed step, uint8 indexed action, bool success, bytes32 calldataHash);
    event ActionCoverage(uint8 indexed action, uint256 attempts, uint256 successes);

    function nativeAsset() internal pure virtual returns (bool);
    function withLiquidity() internal pure virtual returns (bool);
    receive() external payable {}

    function setUp() public {
        vm.roll(1000);
        vm.warp(100_000);
        vm.txGasPrice(0);
        manager = new PoolManager(address(this));
        liquidity = new PoolModifyLiquidityTest(manager);
        deployCodeTo(
            "compat/current/test/utils/MockERC20.sol:MockERC20", abi.encode("USD Coin", "USDC", uint8(6)), address(USDC)
        );
        deployCodeTo(
            "compat/current/test/utils/MockERC20.sol:MockERC20", abi.encode("Asset", "AST", uint8(18)), address(ASSET)
        );
        key = PoolKey(
            Currency.wrap(nativeAsset() ? address(0) : address(USDC)),
            Currency.wrap(nativeAsset() ? address(USDC) : address(ASSET)),
            0x800000,
            1,
            IHooks(address(HOOK))
        );
        pid = key.toId();
        for (uint256 i; i < 4; ++i) {
            actors[i] = vm.addr(0xA11CE + i);
            vm.deal(actors[i], 10_000 ether);
            USDC.mint(actors[i], 50_000_000e6);
            ASSET.mint(actors[i], 10_000 ether);
        }
        vm.deal(address(this), 1_000_000 ether);
        USDC.mint(address(this), 1_000_000_000e6);
        ASSET.mint(address(this), 1_000_000 ether);
        uint256 base = vm.snapshotState();
        _deploy(false);
        uint256 sol = vm.snapshotState();
        assertTrue(vm.revertToState(base), "restore base");
        _deploy(true);
        uint256 huff = vm.snapshotState();
        assertTrue(vm.deleteStateSnapshot(base), "delete base");
        // Store only after both worlds exist: snapshot restores intentionally discard these controller fields.
        solidityWorld = sol;
        huffWorld = huff;
    }

    function _deploy(bool huff) private {
        bytes memory routerArgs = abi.encode(manager, HOOK, ISignatureTransfer(address(0)), uint256(0));
        bytes memory hookArgs = abi.encode(
            manager, Currency.wrap(address(USDC)), address(this), address(ROUTER), uint256(0), type(uint8).max
        );
        _install(huff, "Router", routerArgs, address(ROUTER));
        _install(huff, "AsyncSwap", hookArgs, address(HOOK));
        _install(huff, "NativeClaims", abi.encode(manager), address(NATIVE));
        _install(huff, "TokenClaims", abi.encode(manager), address(CLAIMS));
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(actors[i]);
            USDC.approve(address(ROUTER), type(uint256).max);
            ASSET.approve(address(ROUTER), type(uint256).max);
            HOOK.setExecutor(pid, address(ROUTER), true);
            manager.setOperator(address(NATIVE), true);
            manager.setOperator(address(CLAIMS), true);
            vm.stopPrank();
        }
        int24 tick = nativeAsset() ? int24(-200311) : int24(200311);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        if (withLiquidity()) {
            USDC.approve(address(liquidity), type(uint256).max);
            ASSET.approve(address(liquidity), type(uint256).max);
            liquidity.modifyLiquidity{value: nativeAsset() ? 20_000 ether : 0}(
                key, ModifyLiquidityParams(tick - 100, tick + 100, 1e20, 0), ""
            );
        }
    }

    function _install(bool huff, string memory name, bytes memory args, address target) private {
        bytes memory code;
        if (huff) {
            string memory source = string.concat(
                keccak256(bytes(name)) == keccak256("AsyncSwap") || keccak256(bytes(name)) == keccak256("Router")
                    ? "src/current/"
                    : "src/",
                name,
                ".huff"
            );
            code = HuffNeoDeployer.config().with_args(args).creation_code_with_args(source);
        } else {
            code = abi.encodePacked(vm.getCode(string.concat("reference/contracts/src/", name, ".sol:", name)), args);
        }
        vm.etch(target, code);
        (bool ok, bytes memory runtime) = target.call("");
        if (!ok) {
            assembly ("memory-safe") { revert(add(runtime, 32), mload(runtime)) }
        }
        require(runtime.length != 0, "empty runtime");
        vm.etch(target, runtime);
    }

    function testFuzz_actions(uint256 seed) public {
        _run(seed, vm.envOr("DIFF_STEPS", uint256(128)), false);
    }

    function test_actionCoverage() public {
        _run(0xD1FF2026, vm.envOr("DIFF_STEPS", uint256(128)), true);
    }

    function _run(uint256 seed, uint256 steps, bool metrics) private {
        require(steps >= 32 && steps <= 4096, "DIFF_STEPS must be 32..4096");
        Controller memory c;
        c.sol = solidityWorld;
        c.huff = huffWorld;
        c.orders = new AsyncOrder[](steps);
        c.levels = new uint128[](steps * 2);
        assertTrue(vm.revertToState(c.sol), "restore Solidity initial state");
        Observation memory initial = _observe(c);
        assertTrue(vm.revertToState(c.huff), "restore Huff initial state");
        _compare(_observe(c), initial);
        for (uint256 i; i < steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            assertTrue(stepRestore(c.sol, i == 0), "restore Solidity world");
            _clock(i);
            Action memory a = _action(c, seed, i);
            ++c.attempts[a.kind];
            vm.recordLogs();
            vm.prank(a.sender);
            (bool solOk, bytes memory solReturn) = a.target.call{value: a.value, gas: 30_000_000}(a.data);
            Vm.Log[] memory solLogs = vm.getRecordedLogs();
            if (solOk) {
                ++c.successes[a.kind];
                if (a.kind == 0) _record(c, a.order, solLogs);
            }
            _rememberLevels(c);
            Observation memory expected = _observe(c);
            c.sol = vm.snapshotState();
            assertTrue(stepRestore(c.huff, i == 0), "restore Huff world");
            _clock(i);
            vm.recordLogs();
            vm.prank(a.sender);
            (bool huffOk, bytes memory huffReturn) = a.target.call{value: a.value, gas: 30_000_000}(a.data);
            Vm.Log[] memory huffLogs = vm.getRecordedLogs();
            emit Compared(i, a.kind, huffOk, keccak256(a.data));
            assertEq(huffOk, solOk, "action success");
            assertEq(huffReturn, solReturn, "return or revert bytes");
            assertEq(keccak256(abi.encode(huffLogs)), keccak256(abi.encode(solLogs)), "ordered logs");
            _compare(_observe(c), expected);
            c.huff = vm.snapshotState();
        }
        assertGt(c.successes[0], 0, "campaign must create orders");
        if (metrics) {
            for (uint8 k; k < ACTIONS; ++k) {
                emit ActionCoverage(k, c.attempts[k], c.successes[k]);
            }
        }
        assertTrue(vm.deleteStateSnapshot(c.sol), "delete Solidity world");
        assertTrue(vm.deleteStateSnapshot(c.huff), "delete Huff world");
    }

    function stepRestore(uint256 snapshot, bool initial) private returns (bool) {
        return initial ? vm.revertToState(snapshot) : vm.revertToStateAndDelete(snapshot);
    }

    function _clock(uint256 step) private {
        // Four consecutive actions share a block, exercising salt reuse and same-block pool reference pricing.
        vm.roll(1000 + step / 4);
        vm.warp(100_000 + step / 4);
    }

    function _action(Controller memory c, uint256 entropy, uint256 step) private returns (Action memory a) {
        uint256 who = (entropy >> 8) % 4;
        a.kind = uint8(entropy % 24);
        if (a.kind >= ACTIONS || step < 4) a.kind = 0;
        a.sender = actors[who];
        a.target = address(HOOK);
        uint256 nonce = (entropy >> 32) % 8;
        uint256 deadline = block.timestamp + 100;
        if (a.kind == 0) {
            bool sell = step < 4 ? step % 2 == 0 : entropy & 0x10000 != 0;
            uint256 quantity = step < 4 ? 1 ether : 1e12 + ((entropy >> 64) % 1 ether);
            uint256 price = step < 4 ? 2000e6 : (1000 + (entropy >> 128) % 3001) * 1e6;
            uint256 quote = quantity * price / 1 ether;
            uint256 bid = step < 4 ? 100_000 : (entropy >> 48) % 5 == 0 ? 0 : 100_000 + (entropy >> 96) % 10e6;
            a.order = AsyncOrder(
                key,
                a.sender,
                sell == nativeAsset(),
                sell ? quantity : quote,
                sell ? quote : quantity,
                bid,
                TickMath.getSqrtPriceAtTick(nativeAsset() ? int24(-200311) : int24(200311)),
                0
            );
            a.target = address(ROUTER);
            a.value = nativeAsset() && sell ? a.order.amountIn : 0;
            a.data = abi.encodeCall(
                Router.swap,
                (a.order, abi.encode(AsyncSwap.UserParams(a.sender, address(ROUTER), a.order.amountOutMin, bid)))
            );
            return a;
        }
        a.order = _pick(c, entropy);
        bytes32 id = _id(a.order);
        (uint256 remaining, uint256 minimum) = HOOK.asyncOrderInfo(pid, id);
        // Most maker operations are authorized; the rest deliberately exercise rollback and error ordering.
        if (entropy & 0x40000 == 0) a.sender = a.order.owner;
        if (a.kind == 1 || a.kind == 15) {
            a.target = address(ROUTER);
            a.data = a.kind == 1
                ? abi.encodeCall(Router.cancelOrder, (a.order))
                : abi.encodeCall(Router.cancelAndWithdraw, (a.order));
        } else if (a.kind == 2 || a.kind == 13) {
            uint256 next = minimum == 0 ? 1 : minimum * (50 + (entropy >> 96) % 151) / 100;
            if (a.kind == 2) {
                a.data = abi.encodeCall(AsyncSwap.updatePrice, (a.order, next));
            } else {
                bytes32 hash = OrderSignatures.hashUpdatePrice(
                    a.order,
                    id,
                    remaining,
                    next,
                    HOOK.orderCreatedSequence(pid, id),
                    HOOK.orderReprices(pid, id),
                    nonce,
                    deadline
                );
                a.data = abi.encodeCall(
                    AsyncSwap.updatePriceWithSig,
                    (a.order, remaining, next, nonce, deadline, _sign(a.order.owner, hash, HOOK.DOMAIN_SEPARATOR()))
                );
            }
        } else if (a.kind == 3) {
            a.target = address(ROUTER);
            a.data = abi.encodeCall(
                Router.topUpPriorityFee, (a.order, (entropy >> 48) % 7 == 0 ? 0 : 100_000 + (entropy >> 96) % 10e6)
            );
        } else if (a.kind == 4) {
            a.target = address(ROUTER);
            a.data = abi.encodeCall(Router.matchBook, (key, uint8((entropy >> 96) % 10)));
        } else if (a.kind == 5 || a.kind == 6) {
            a.sender = actors[who];
            Currency currency = Currency.wrap(a.kind == 5 ? address(USDC) : nativeAsset() ? address(0) : address(ASSET));
            uint256 balance = manager.balanceOf(a.sender, uint160(Currency.unwrap(currency)));
            uint256 amount = balance == 0 ? 1 : 1 + (entropy >> 64) % balance;
            if (a.kind == 6 && nativeAsset()) {
                a.target = address(NATIVE);
                a.data = abi.encodeCall(NativeClaims.redeem, (actors[(who + 1) % 4], amount));
            } else {
                a.target = address(CLAIMS);
                a.data = abi.encodeCall(TokenClaims.redeem, (currency, actors[(who + 1) % 4], amount));
            }
        } else if (a.kind == 7) {
            a.target = address(HOOK.feeVault());
            a.sender = entropy & 0x40000 == 0 ? address(this) : actors[who];
            a.data =
                abi.encodeCall(FeeVault.collect, (entropy & 0x20000 == 0 ? key.currency0 : key.currency1, actors[who]));
        } else if (a.kind == 8) {
            a.target = address(ROUTER);
            a.data = abi.encodeCall(Router.fillFromPoolLiquidity, (a.order));
        } else if (a.kind == 9) {
            a.target = address(ROUTER);
            a.sender = actors[who];
            a.value = nativeAsset() && !a.order.zeroForOne ? minimum : 0;
            a.data = abi.encodeCall(Router.fillOrder, (a.order, type(uint256).max, bytes("")));
        } else if (a.kind == 10) {
            a.sender = actors[who];
            a.data = abi.encodeCall(AsyncSwap.invalidateNonce, (nonce));
        } else if (a.kind == 11 || a.kind == 12) {
            a.sender = actors[who];
            address executor = entropy & 0x80000 == 0 ? EXECUTOR : address(ROUTER);
            bool allow = entropy & 0x20000 != 0;
            if (a.kind == 11) {
                a.data = abi.encodeCall(AsyncSwap.setExecutor, (pid, executor, allow));
            } else {
                bytes32 hash = OrderSignatures.hashSetExecutor(key, a.sender, executor, allow, nonce, deadline);
                bytes memory signature = _sign(a.sender, hash, HOOK.DOMAIN_SEPARATOR());
                a.data = abi.encodeCall(
                    AsyncSwap.setExecutorWithSig, (key, a.sender, executor, allow, nonce, deadline, signature)
                );
                a.sender = actors[(who + 1) % 4];
            }
        } else if (a.kind == 14) {
            a.target = address(ROUTER);
            bytes32 hash = OrderSignatures.hashCancel(a.order, id, HOOK.orderCreatedSequence(pid, id), nonce, deadline);
            a.data = abi.encodeCall(
                Router.cancelWithSig, (a.order, nonce, deadline, _sign(a.order.owner, hash, ROUTER.DOMAIN_SEPARATOR()))
            );
        } else if (a.kind == 16) {
            a.sender = address(this);
            a.data = abi.encodeCall(AsyncSwap.transferOwnership, (actors[who]));
        } else {
            a.sender = actors[who];
            a.data = abi.encodeCall(AsyncSwap.acceptOwnership, ());
        }
    }

    function _pick(Controller memory c, uint256 entropy) private view returns (AsyncOrder memory o) {
        if (c.count == 0) return AsyncOrder(key, actors[0], nativeAsset(), 1, 1, 0, 0, 0);
        uint256 index = (entropy >> 24) % c.count;
        if (entropy & 0x100000 == 0) {
            for (uint256 n; n < c.count; ++n) {
                uint256 candidate = (index + n) % c.count;
                if (HOOK.asyncOrder(pid, _id(c.orders[candidate])) != 0) return c.orders[candidate];
            }
        }
        return c.orders[index];
    }

    function _sign(address maker, bytes32 hash, bytes32 domain) private view returns (bytes memory) {
        uint256 privateKey;
        for (uint256 i; i < 4; ++i) {
            if (actors[i] == maker) privateKey = 0xA11CE + i;
        }
        require(privateKey != 0, "unknown maker");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, keccak256(abi.encodePacked(hex"1901", domain, hash)));
        return abi.encodePacked(r, s, v);
    }

    function _record(Controller memory c, AsyncOrder memory o, Vm.Log[] memory logs) private pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(HOOK) && logs[i].topics.length > 0 && logs[i].topics[0] == CREATED) {
                (,,, o.salt) = abi.decode(logs[i].data, (bool, uint256, uint256, bytes32));
                c.orders[c.count++] = o;
                return;
            }
        }
        revert("successful submission missing creation log");
    }

    function _id(AsyncOrder memory o) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, pid, o.owner, o.zeroForOne, o.salt));
    }

    function _rememberLevels(Controller memory c) private view {
        uint256 scratch;
        assembly ("memory-safe") { scratch := mload(0x40) }
        _rememberLevelsAllocated(c);
        // Only scalar keys were copied into the controller's preallocated level array.
        assembly ("memory-safe") { mstore(0x40, scratch) }
    }

    function _rememberLevelsAllocated(Controller memory c) private view {
        for (uint256 i; i < c.count; ++i) {
            (,,, uint128 price,,,) = HOOK.orderBookOrder(pid, _id(c.orders[i]));
            if (price == 0) continue;
            bool seen;
            for (uint256 n; n < c.levelCount; ++n) {
                if (c.levels[n] == price) {
                    seen = true;
                    break;
                }
            }
            if (!seen) c.levels[c.levelCount++] = price;
        }
    }

    function _read(address target, bytes memory data) private view returns (bytes memory) {
        (bool ok, bytes memory result) = target.staticcall(data);
        require(ok, "state getter reverted");
        return result;
    }

    function _observe(Controller memory c) private view returns (Observation memory result) {
        result = Observation(0, 0, 0, 0, 0);
        uint256 scratch;
        assembly ("memory-safe") { scratch := mload(0x40) }
        Observation memory observed = _observeAllocated(c);
        // Hashes are value types. Reclaim getter/ABI scratch memory after copying them,
        // so observer allocations do not make long sequences exhaust the test's memory.
        assembly ("memory-safe") {
            mcopy(result, observed, 0xa0)
            mstore(0x40, scratch)
        }
    }

    function _observeAllocated(Controller memory c) private view returns (Observation memory s) {
        for (uint256 i; i < c.count; ++i) {
            bytes32 id = _id(c.orders[i]);
            s.orders = keccak256(
                abi.encode(
                    s.orders,
                    id,
                    _read(address(HOOK), abi.encodeCall(AsyncSwap.orderBookOrder, (pid, id))),
                    _read(address(HOOK), abi.encodeCall(AsyncSwap.asyncOrderInfo, (pid, id))),
                    HOOK.asyncOrder(pid, id),
                    HOOK.asyncOrderPriorityFee(pid, id),
                    HOOK.orderCreatedSequence(pid, id),
                    HOOK.orderReprices(pid, id)
                )
            );
        }
        s.levels = keccak256(
            abi.encode(
                _read(address(HOOK), abi.encodeCall(AsyncSwap.bestOrder, (pid, true))),
                _read(address(HOOK), abi.encodeCall(AsyncSwap.bestOrder, (pid, false)))
            )
        );
        for (uint256 i; i < c.levelCount; ++i) {
            s.levels = keccak256(
                abi.encode(
                    s.levels,
                    c.levels[i],
                    _read(address(HOOK), abi.encodeCall(AsyncSwap.orderBookLevel, (pid, true, c.levels[i]))),
                    _read(address(HOOK), abi.encodeCall(AsyncSwap.orderBookLevel, (pid, false, c.levels[i])))
                )
            );
        }
        address[10] memory accounts = [
            actors[0],
            actors[1],
            actors[2],
            actors[3],
            address(HOOK),
            address(ROUTER),
            address(HOOK.feeVault()),
            address(manager),
            address(NATIVE),
            address(CLAIMS)
        ];
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            s.balances = keccak256(
                abi.encode(
                    s.balances,
                    account,
                    account.balance,
                    USDC.balanceOf(account),
                    ASSET.balanceOf(account),
                    manager.balanceOf(account, uint160(Currency.unwrap(key.currency0))),
                    manager.balanceOf(account, uint160(Currency.unwrap(key.currency1)))
                )
            );
        }
        for (uint256 i; i < 4; ++i) {
            uint256 nonces;
            for (uint256 n; n < 8; ++n) {
                if (HOOK.nonceUsed(actors[i], n)) nonces |= 1 << n;
            }
            s.permissions = keccak256(
                abi.encode(
                    s.permissions,
                    nonces,
                    HOOK.isExecutor(pid, actors[i], address(ROUTER)),
                    HOOK.isExecutor(pid, actors[i], EXECUTOR),
                    USDC.allowance(actors[i], address(ROUTER)),
                    ASSET.allowance(actors[i], address(ROUTER)),
                    manager.isOperator(actors[i], address(NATIVE)),
                    manager.isOperator(actors[i], address(CLAIMS))
                )
            );
        }
        s.permissions = keccak256(
            abi.encode(
                s.permissions, HOOK.owner(), HOOK.pendingOwner(), HOOK.DOMAIN_SEPARATOR(), ROUTER.DOMAIN_SEPARATOR()
            )
        );
        (uint160 sqrtPrice, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(pid);
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(pid);
        s.pool = keccak256(
            abi.encode(
                sqrtPrice,
                tick,
                protocolFee,
                lpFee,
                fee0,
                fee1,
                manager.getLiquidity(pid),
                HOOK.minAssetAmount(pid),
                _read(address(HOOK), abi.encodeWithSignature("asyncOrders(bytes32)", pid))
            )
        );
        assertFalse(manager.isUnlocked(), "manager lock restored");
        assertEq(manager.getNonzeroDeltaCount(), 0, "no outstanding currency deltas");
    }

    function _compare(Observation memory actual, Observation memory expected) private pure {
        assertEq(actual.orders, expected.orders, "all order fields after action");
        assertEq(actual.levels, expected.levels, "best orders and touched price levels after action");
        assertEq(actual.balances, expected.balances, "wallets, claims, escrow and vault balances after action");
        assertEq(actual.pool, expected.pool, "pool state after action");
        assertEq(actual.permissions, expected.permissions, "ownership, nonces and permissions after action");
    }
}

contract NativeStateDifferentialTest is StateDifferentialTest {
    function nativeAsset() internal pure override returns (bool) {
        return true;
    }

    function withLiquidity() internal pure override returns (bool) {
        return false;
    }
}

contract NativeLPStateDifferentialTest is StateDifferentialTest {
    function nativeAsset() internal pure override returns (bool) {
        return true;
    }

    function withLiquidity() internal pure override returns (bool) {
        return true;
    }
}

contract TokenStateDifferentialTest is StateDifferentialTest {
    function nativeAsset() internal pure override returns (bool) {
        return false;
    }

    function withLiquidity() internal pure override returns (bool) {
        return false;
    }
}

contract TokenLPStateDifferentialTest is StateDifferentialTest {
    function nativeAsset() internal pure override returns (bool) {
        return false;
    }

    function withLiquidity() internal pure override returns (bool) {
        return true;
    }
}
