// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetupHook} from "../test/SetupHook.t.sol";
import {MockERC20} from "../test/utils/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {FeeVault} from "@async-swap/FeeVault.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";

/// @dev Settles each signed v4 delta separately: accrued fees can offset a liquidity deposit.
contract AccountingLiquidityProvider is IUnlockCallback {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params, bool claims)
        external
        payable
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        (delta, fees) = abi.decode(
            manager.unlock(abi.encode(msg.sender, key, params, claims)), (BalanceDelta, BalanceDelta)
        );
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "native refund failed");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address payer, PoolKey memory key, ModifyLiquidityParams memory params, bool claims) =
            abi.decode(data, (address, PoolKey, ModifyLiquidityParams, bool));
        (BalanceDelta delta, BalanceDelta fees) = manager.modifyLiquidity(key, params, "");
        _settle(key.currency0, payer, delta.amount0(), claims);
        _settle(key.currency1, payer, delta.amount1(), claims);
        return abi.encode(delta, fees);
    }

    function _settle(Currency currency, address payer, int128 amount, bool claims) private {
        if (amount < 0) currency.settle(manager, payer, uint256(-int256(amount)), false);
        if (amount > 0) currency.take(manager, payer, uint256(int256(amount)), claims);
    }
}

contract MultiPoolLiquidityAccountingTest is SetupHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    bytes32 constant CREATED = keccak256("AsyncOrderCreated(bytes32,bytes32,address,bool,uint256,uint256,bytes32)");
    bytes32 constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant DONATE = keccak256("Donate(bytes32,address,uint256,uint256)");
    uint256 donationCount;
    bytes32 constant LP_FILLED = keccak256("AsyncOrderLiquidityFilled(bytes32,bytes32,address,uint256,uint256)");
    address[3] actors;
    MockERC20 alt;
    PoolKey[3] markets;
    AsyncOrder[] tracked;
    AccountingLiquidityProvider provider;
    uint128[3][3] positions;
    int256[2][3] reserves;
    uint256[2][3] lastFeeGrowth;
    uint256[3] fills;
    uint256 nativeTotal;
    bool traceCampaign;
    event LPStateCheckpoint(uint256 indexed step, bytes32 digest);
    event LPActionCount(uint256 indexed action, uint256 successes);
    receive() external payable {}

    function setUp() public override {
        vm.txGasPrice(0);
        vm.deal(address(this), 1000 ether);
        _deployManager();
        deployCodeTo(
            "compat/current/test/utils/MockERC20.sol:MockERC20", abi.encode("Asset", "AST", uint8(18)), address(0x10000)
        );
        deployCodeTo(
            "compat/current/test/utils/MockERC20.sol:MockERC20",
            abi.encode("USD Coin", "USDC", uint8(6)),
            address(0x20000)
        );
        deployCodeTo(
            "compat/current/test/utils/MockERC20.sol:MockERC20",
            abi.encode("Eight decimals", "ALT", uint8(8)),
            address(0x30000)
        );
        token0 = MockERC20(address(0x10000));
        token1 = MockERC20(address(0x20000));
        alt = MockERC20(address(0x30000));
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        _deployRouter();
        _deployHook();
        _createKey();
        markets[0] = key;
        markets[1] = PoolKey(currency1, Currency.wrap(address(alt)), key.fee, 1, hook);
        markets[2] = PoolKey(Currency.wrap(address(0)), currency1, key.fee, 1, hook);
        for (uint256 p; p < 3; ++p) {
            manager.initialize(markets[p], _sqrt(p));
        }
        for (uint256 i; i < 3; ++i) {
            actors[i] = vm.addr(0xA11CE + i);
            _fund(actors[i]);
        }
    }

    function _sqrt(uint256 p) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(p == 1 ? int24(0) : int24(-200311));
    }

    function _fund(address who) internal {
        token0.mint(who, 10000 ether);
        token1.mint(who, 100_000_000e6);
        alt.mint(who, 10000e8);
        vm.deal(who, 100 ether);
        vm.startPrank(who);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        alt.approve(address(router), type(uint256).max);
        for (uint256 p; p < 3; ++p) {
            hook.setExecutor(markets[p].toId(), address(router), true);
        }
        vm.stopPrank();
    }

    function _order(uint256 p, address who, bool sell, uint256 quantity, uint256 price)
        internal
        view
        returns (AsyncOrder memory)
    {
        uint256 quote = quantity * price / (p == 1 ? 1e8 : 1 ether);
        return AsyncOrder(
            markets[p], who, sell != (p == 1), sell ? quantity : quote, sell ? quote : quantity, 100_000, _sqrt(p), 0
        );
    }

    function _id(AsyncOrder memory o) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, o.key.toId(), o.owner, o.zeroForOne, o.salt));
    }

    function _live(AsyncOrder memory o) internal view returns (uint256) {
        return hook.asyncOrder(o.key.toId(), _id(o));
    }

    function _submit(AsyncOrder memory o) internal returns (AsyncOrder memory) {
        Currency input = o.zeroForOne ? o.key.currency0 : o.key.currency1;
        uint256 value = (Currency.unwrap(input) == address(0) ? o.amountIn : 0) + router.mevTax();
        vm.recordLogs();
        vm.prank(o.owner);
        router.swap{value: value}(
            o, abi.encode(AsyncSwap.UserParams(o.owner, address(router), o.amountOutMin, o.priorityFee))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _observeSwaps(logs);
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length != 0 && logs[i].topics[0] == CREATED) {
                (,,, o.salt) = abi.decode(logs[i].data, (bool, uint256, uint256, bytes32));
                found = true;
                break;
            }
        }
        assertTrue(found, "real creation event required");
        // Closed identities can be reused in one block. Count each current identity once.
        for (uint256 i; i < tracked.length; ++i) {
            if (_id(tracked[i]) == _id(o)) {
                tracked[i] = o;
                return o;
            }
        }
        tracked.push(o);
        return o;
    }

    function _cancel(AsyncOrder memory o) internal {
        vm.prank(o.owner);
        router.cancelOrder(o);
    }

    function _fill(AsyncOrder memory o, address taker) internal {
        (o.amountIn, o.amountOutMin) = hook.asyncOrderInfo(o.key.toId(), _id(o));
        Currency output = o.zeroForOne ? o.key.currency1 : o.key.currency0;
        uint256 value = (Currency.unwrap(output) == address(0) ? o.amountOutMin : 0) + router.mevTax();
        vm.prank(taker);
        router.fillOrder{value: value}(o, o.amountOutMin, "");
    }

    function _book(AsyncOrder memory o) internal view returns (bytes32) {
        (uint256 a, uint256 b) = hook.asyncOrderInfo(o.key.toId(), _id(o));
        return keccak256(
            abi.encode(
                a,
                b,
                hook.asyncOrderPriorityFee(o.key.toId(), _id(o)),
                hook.orderCreatedSequence(o.key.toId(), _id(o)),
                hook.orderReprices(o.key.toId(), _id(o))
            )
        );
    }

    function _singleCurrency(Currency c) internal pure returns (Currency[] memory cs) {
        cs = new Currency[](1);
        cs[0] = c;
    }

    function _singleAmount(uint256 amount) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function _wallets() internal view returns (address[11] memory) {
        return [
            actors[0],
            actors[1],
            actors[2],
            address(this),
            address(hook),
            address(router),
            address(hook.feeVault()),
            address(token0),
            address(token1),
            address(alt),
            address(provider)
        ];
    }

    function _start() internal {
        provider = new AccountingLiquidityProvider(manager);
        _fund(address(this));
        vm.deal(address(this), 1000 ether);
        token0.approve(address(provider), type(uint256).max);
        token1.approve(address(provider), type(uint256).max);
        alt.approve(address(provider), type(uint256).max);
        address[11] memory wallets = _wallets();
        nativeTotal = address(manager).balance;
        for (uint256 i; i < wallets.length; ++i) {
            nativeTotal += wallets[i].balance;
        }
        _assertCustody();
    }

    function _range(uint256 p, uint256 r) internal pure returns (int24 lower, int24 upper) {
        int24 center = p == 1 ? int24(0) : int24(-200311);
        if (r == 0) return (center - 600, center + 600);
        if (r == 1) return (center - 60, center + 60);
        return (center + 700, center + 1300);
    }

    function _base(uint256 p) internal pure returns (uint128) {
        return p == 1 ? 1e11 : 5e15;
    }

    function _modify(uint256 p, uint256 r, int256 change, bool claims) internal {
        bytes32[3] memory before;
        for (uint256 i; i < 3; ++i) {
            before[i] = _poolState(i);
        }
        (int24 lower, int24 upper) = _range(p, r);
        // Liquidity delta is independent of token amounts; v4 returns the signed settlement cashflow.
        (BalanceDelta delta,) = provider.modify{value: p == 2 && change > 0 ? 20 ether : 0}(
            markets[p], ModifyLiquidityParams(lower, upper, change, bytes32(r)), claims
        );
        positions[p][r] = uint128(uint256(int256(uint256(positions[p][r])) + change));
        reserves[p][0] -= delta.amount0();
        reserves[p][1] -= delta.amount1();
        for (uint256 i; i < 3; ++i) {
            if (i != p) assertEq(_poolState(i), before[i], "LP edit cannot mutate another pool");
        }
        _assertCustody();
    }

    function _observeSwaps(Vm.Log[] memory logs) internal {
        int128[2][3] memory pending;
        bool[3] memory seen;
        uint256[2][3] memory donations;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2) continue;
            uint256 p;
            while (p < 3 && logs[i].topics[1] != PoolId.unwrap(markets[p].toId())) ++p;
            if (p == 3) continue;
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP) {
                (pending[p][0], pending[p][1],,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                seen[p] = true;
                donations[p] = [uint256(0), uint256(0)];
            } else if (logs[i].emitter == address(manager) && logs[i].topics[0] == DONATE) {
                (donations[p][0], donations[p][1]) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == LP_FILLED) {
                // recordLogs may expose reverted inner attempts. Commit only a completed hook LP fill.
                assertTrue(seen[p], "completed LP fill has a v4 swap");
                reserves[p][0] -= pending[p][0];
                reserves[p][1] -= pending[p][1];
                reserves[p][0] += int256(donations[p][0]);
                reserves[p][1] += int256(donations[p][1]);
                if (donations[p][0] + donations[p][1] != 0) ++donationCount;
                seen[p] = false;
                ++fills[p];
            }
        }
    }

    function _retry(AsyncOrder memory order) internal {
        uint256 tax = router.mevTax();
        vm.recordLogs();
        router.fillFromPoolLiquidity{value: tax}(order);
        _observeSwaps(vm.getRecordedLogs());
    }

    function _poolState(uint256 p) internal view returns (bytes32 digest) {
        {
            (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(markets[p].toId());
            (uint256 f0, uint256 f1) = manager.getFeeGrowthGlobals(markets[p].toId());
            digest =
                keccak256(abi.encode(price, tick, protocolFee, lpFee, manager.getLiquidity(markets[p].toId()), f0, f1));
        }
        for (uint256 r; r < 3; ++r) {
            (int24 lower, int24 upper) = _range(p, r);
            (uint128 liquidity, uint256 last0, uint256 last1) =
                manager.getPositionInfo(markets[p].toId(), address(provider), lower, upper, bytes32(r));
            digest = keccak256(abi.encode(digest, liquidity, last0, last1));
        }
        for (uint256 i; i < tracked.length; ++i) {
            if (PoolId.unwrap(tracked[i].key.toId()) == PoolId.unwrap(markets[p].toId())) {
                digest = keccak256(abi.encode(digest, _id(tracked[i]), _book(tracked[i])));
            }
        }
    }

    function _assertCustody() internal {
        Currency[4] memory cs = [currency0, currency1, Currency.wrap(address(alt)), Currency.wrap(address(0))];
        address[11] memory wallets = _wallets();
        for (uint256 c; c < cs.length; ++c) {
            uint256 id = uint160(Currency.unwrap(cs[c]));
            uint256 owed;
            for (uint256 i; i < tracked.length; ++i) {
                AsyncOrder memory o = tracked[i];
                if ((o.zeroForOne ? o.key.currency0 : o.key.currency1) == cs[c]) owed += _live(o);
                if (cs[c] == currency1) owed += hook.asyncOrderPriorityFee(o.key.toId(), _id(o));
            }
            assertEq(manager.balanceOf(address(hook), id), owed, "all pools: escrow equals open inputs plus bids");
            uint256 claims;
            uint256 held;
            for (uint256 i; i < wallets.length; ++i) {
                claims += manager.balanceOf(wallets[i], id);
                held += id == 0 ? wallets[i].balance : MockERC20(address(uint160(id))).balanceOf(wallets[i]);
            }
            uint256 backing =
                id == 0 ? address(manager).balance : MockERC20(address(uint160(id))).balanceOf(address(manager));
            int256 poolBacking;
            for (uint256 p; p < 3; ++p) {
                assertGe(reserves[p][0], 0, "currency0 LP reserve nonnegative");
                assertGe(reserves[p][1], 0, "currency1 LP reserve nonnegative");
                if (markets[p].currency0 == cs[c]) poolBacking += reserves[p][0];
                if (markets[p].currency1 == cs[c]) poolBacking += reserves[p][1];
            }
            assertEq(
                backing, claims + uint256(poolBacking), "custody equals claims plus independently tracked LP reserves"
            );
            assertEq(
                held + backing,
                id == 0 ? nativeTotal : MockERC20(address(uint160(id))).totalSupply(),
                "wallet and custody supply conserved"
            );
        }
        for (uint256 p; p < 3; ++p) {
            (, int24 tick,, uint24 fee) = manager.getSlot0(markets[p].toId());
            assertEq(fee, 0, "temporary LP fee restored");
            uint256 active;
            for (uint256 r; r < 3; ++r) {
                (int24 lower, int24 upper) = _range(p, r);
                (uint128 actual,,) =
                    manager.getPositionInfo(markets[p].toId(), address(provider), lower, upper, bytes32(r));
                assertEq(actual, positions[p][r], "position liquidity matches independent model");
                if (lower <= tick && tick < upper) active += positions[p][r];
            }
            assertEq(manager.getLiquidity(markets[p].toId()), active, "active liquidity follows current ranges");
            (uint256 f0, uint256 f1) = manager.getFeeGrowthGlobals(markets[p].toId());
            assertGe(f0, lastFeeGrowth[p][0], "fee growth0 monotone");
            assertGe(f1, lastFeeGrowth[p][1], "fee growth1 monotone");
            lastFeeGrowth[p] = [f0, f1];
        }
        assertFalse(manager.isUnlocked(), "manager relocked");
        assertEq(manager.getNonzeroDeltaCount(), 0, "all deltas settled");
    }

    function _withdraw(address recipient, Currency c) internal returns (bool) {
        uint256 amount = manager.balanceOf(recipient, uint160(Currency.unwrap(c)));
        if (amount == 0) return false;
        vm.prank(recipient);
        manager.approve(address(router), uint160(Currency.unwrap(c)), amount);
        vm.prank(recipient);
        router.withdrawClaims(_singleCurrency(c), _singleAmount(amount));
        return true;
    }

    function _finish() internal {
        vm.txGasPrice(0);
        for (uint256 p; p < 3; ++p) {
            for (uint256 r; r < 3; ++r) {
                if (positions[p][r] != 0) {
                    _modify(p, r, -int256(uint256(positions[p][r])), true);
                }
            }
        }
        for (uint256 i; i < tracked.length; ++i) {
            if (_live(tracked[i]) != 0) {
                _cancel(tracked[i]);
                _assertCustody();
            }
        }
        Currency[4] memory cs = [currency0, currency1, Currency.wrap(address(alt)), Currency.wrap(address(0))];
        for (uint256 c; c < 4; ++c) {
            hook.feeVault().collect(cs[c], address(this));
            for (uint256 a; a < 4; ++a) {
                _withdraw(a == 3 ? address(this) : actors[a], cs[c]);
                _assertCustody();
            }
        }
        for (uint256 p; p < 3; ++p) {
            assertEq(manager.getLiquidity(markets[p].toId()), 0, "all liquidity withdrawn");
        }
    }

    function _digest() internal view returns (bytes32 digest) {
        for (uint256 p; p < 3; ++p) {
            digest = keccak256(abi.encode(digest, _poolState(p), reserves[p], fills[p]));
        }
        Currency[4] memory cs = [currency0, currency1, Currency.wrap(address(alt)), Currency.wrap(address(0))];
        address[11] memory wallets = _wallets();
        for (uint256 c; c < 4; ++c) {
            for (uint256 w; w <= wallets.length; ++w) {
                address who = w == wallets.length ? address(manager) : wallets[w];
                uint256 id = uint160(Currency.unwrap(cs[c]));
                uint256 balance = id == 0 ? who.balance : MockERC20(address(uint160(id))).balanceOf(who);
                digest = keccak256(
                    abi.encode(digest, balance, manager.balanceOf(who, id), manager.allowance(who, address(router), id))
                );
            }
        }
    }

    function test_LP_removeAllThenRestoreLiquidityAcrossThreePools() public {
        _start();
        for (uint256 p; p < 3; ++p) {
            AsyncOrder memory waiting =
                _submit(_order(p, actors[0], true, p == 1 ? 1e6 : 0.01 ether, p == 1 ? 50e6 : 1000e6));
            assertGt(_live(waiting), 0, "no liquidity: order rests");
            _modify(p, 2, int256(uint256(_base(p))), false);
            bytes32 before = _poolState(p);
            _retry(waiting);
            assertEq(_poolState(p), before, "out-of-range retry rolls back all pool and order state");
            _modify(p, 0, int256(uint256(_base(p))), false);
            _retry(waiting);
            assertEq(_live(waiting), 0, "restored liquidity fills resting order");
            assertGt(fills[p], 0, "real LP fill required in every pool");
            _modify(p, 0, 0, true);
            _modify(p, 0, -int256(uint256(positions[p][0])), true);
            assertEq(manager.getLiquidity(markets[p].toId()), 0, "out-of-range inventory is not active liquidity");
            _assertCustody();
        }
        _finish();
    }

    function test_LP_deterministicChangingLiquidity() public {
        traceCampaign = true;
        uint256[11] memory counts = _campaignLP(0x1a11c0ffee);
        assertGt(donationCount, 0, "dynamic-fee LP donations exercised");
        for (uint256 i; i < counts.length; ++i) {
            emit LPActionCount(i, counts[i]);
            assertGt(counts[i], 0, "every LP campaign action executed");
        }
    }

    function testFuzz_LP_accountingAfterEveryLiquidityAndOrderAction(uint256 seed) public {
        _campaignLP(seed);
    }

    function _randomOrder(uint256 p, uint256 seed) internal {
        uint256 unit = p == 1 ? 1e8 : 1 ether;
        uint256 price = (p == 1 ? 50 + (seed >> 64) % 151 : 1000 + (seed >> 64) % 4001) * 1e6;
        AsyncOrder memory fresh =
            _order(p, actors[(seed >> 24) % 3], seed & 0x80000000 != 0, unit / 100 + (seed >> 96) % (unit / 10), price);
        if (seed & 0x40000000000 == 0) fresh.priorityFee = 0;
        _submit(fresh);
    }

    function _campaignLP(uint256 seed) internal returns (uint256[11] memory counts) {
        _start();
        for (uint256 p; p < 3; ++p) {
            _modify(p, 0, int256(uint256(_base(p))), false);
            AsyncOrder memory filled =
                _submit(_order(p, actors[0], true, p == 1 ? 1e6 : 0.01 ether, p == 1 ? 50e6 : 1000e6));
            assertEq(_live(filled), 0, "campaign must execute real LP fills");
            assertGt(fills[p], 0, "LP fill observed");
            _assertCustody();
        }
        for (uint256 step; step < 64; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            vm.roll(2000 + step / 4);
            vm.warp(200_000 + step / 4);
            vm.fee(1 gwei);
            vm.txGasPrice(1 gwei + (seed >> 32) % 3 * 1 gwei);
            uint256 action = seed % 11;
            uint256 p = (seed >> 8) % 3;
            uint256 r = (seed >> 16) % 3;
            uint256 index;
            bool live;
            for (uint256 i; i < tracked.length; ++i) {
                index = ((seed >> 24) + i) % tracked.length;
                if (_live(tracked[index]) != 0) {
                    live = true;
                    break;
                }
            }
            if (action >= 4 && action <= 8 && !live) action = 3;
            if (action == 1 && positions[p][r] == 0) action = 0;
            if (action == 2 && positions[p][r] == 0) {
                r = 0;
                if (positions[p][r] == 0) action = 0;
            }
            if (action == 0) {
                _modify(p, r, int256(uint256(_base(p) / 2)), false);
            } else if (action == 1) {
                uint128 amount = seed & 0x10000000000 == 0 ? positions[p][r] : positions[p][r] / 2;
                _modify(p, r, -int256(uint256(amount)), seed & 0x20000000000 != 0);
            } else if (action == 2) {
                _modify(p, r, 0, seed & 0x20000000000 != 0);
            } else if (action == 3) {
                _randomOrder(p, seed);
            } else if (action == 4) {
                _cancel(tracked[index]);
            } else if (action == 5) {
                vm.prank(tracked[index].owner);
                router.topUpPriorityFee(tracked[index], 100_000);
            } else if (action == 6) {
                AsyncOrder memory o = tracked[index];
                (, uint256 minimum) = hook.asyncOrderInfo(o.key.toId(), _id(o));
                vm.prank(o.owner);
                hook.updatePrice(o, minimum / 2 + 1);
            } else if (action == 7) {
                _retry(tracked[index]);
            } else if (action == 8) {
                _fill(tracked[index], actors[(seed >> 24) % 3]);
            } else if (action == 9) {
                Currency c = (seed >> 48) % 2 == 0 ? currency1 : Currency.wrap(address(0));
                if (!_withdraw(address(this), c)) {
                    hook.feeVault().collect(c, address(this));
                    action = 10;
                }
            } else {
                hook.feeVault()
                    .collect(seed & 0x10000000000 == 0 ? currency1 : Currency.wrap(address(0)), address(this));
            }
            ++counts[action];
            _assertCustody();
            if (traceCampaign) emit LPStateCheckpoint(step, _digest());
        }
        _finish();
        if (traceCampaign) emit LPStateCheckpoint(64, _digest());
    }
}
