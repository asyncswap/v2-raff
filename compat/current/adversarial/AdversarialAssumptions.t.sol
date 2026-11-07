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

/// @dev First five slots match MockERC20. Faults run real token code; no mocked protocol return values.
contract AdversarialPaymentToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public shortfall;
    bool public rejectTransfer;
    bool public rejectTransferFrom;

    constructor(uint8 d) {
        decimals = d;
    }

    function configure(uint256 missing, bool rejectOut, bool rejectIn) external {
        shortfall = missing;
        rejectTransfer = rejectOut;
        rejectTransferFrom = rejectIn;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return !rejectTransfer;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return !rejectTransferFrom;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 cut = shortfall < amount ? shortfall : amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - cut;
        totalSupply -= cut;
    }
}

contract ScopedExecutor is IUnlockCallback {
    IPoolManager immutable manager;
    AsyncSwap immutable hook;

    constructor(IPoolManager m, AsyncSwap h) {
        manager = m;
        hook = h;
    }

    function cancel(AsyncOrder calldata order) external {
        manager.unlock(abi.encode(order));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.cancelOrder(abi.decode(data, (AsyncOrder)));
        return "";
    }
}

/// @dev Identical test source runs against Solidity and the Huff SetupHook deployment adapter.
///      Assets have real 18/6/8 decimals; all pools share six-decimal USDC, in both quote orientations.
contract AdversarialAssumptionsTest is SetupHook {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    bytes32 constant CREATED = keccak256("AsyncOrderCreated(bytes32,bytes32,address,bool,uint256,uint256,bytes32)");
    address[3] actors;
    MockERC20 alt;
    PoolKey[3] markets;
    AsyncOrder[] tracked;

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
    receive() external payable {}

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

    function _fault(MockERC20 token) internal returns (AdversarialPaymentToken t) {
        t = new AdversarialPaymentToken(token.decimals());
        vm.etch(address(token), address(t).code);
        return AdversarialPaymentToken(address(token));
    }

    function _wallets() internal view returns (address[10] memory) {
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
            address(alt)
        ];
    }

    function _assertAccounting() internal view {
        Currency[4] memory currencies = [currency0, currency1, Currency.wrap(address(alt)), Currency.wrap(address(0))];
        address[10] memory wallets = _wallets();
        for (uint256 c; c < currencies.length; ++c) {
            Currency currency = currencies[c];
            uint256 id = uint160(Currency.unwrap(currency));
            uint256 owed;
            for (uint256 i; i < tracked.length; ++i) {
                AsyncOrder memory o = tracked[i];
                if ((o.zeroForOne ? o.key.currency0 : o.key.currency1) == currency) owed += _live(o);
                if (currency == currency1) owed += hook.asyncOrderPriorityFee(o.key.toId(), _id(o));
            }
            assertEq(manager.balanceOf(address(hook), id), owed, "all pools: escrow equals open inputs plus bids");
            uint256 claims;
            for (uint256 i; i < wallets.length; ++i) {
                claims += manager.balanceOf(wallets[i], id);
            }
            uint256 backing =
                id == 0 ? address(manager).balance : MockERC20(address(uint160(id))).balanceOf(address(manager));
            assertEq(backing, claims, "no LPs: every claim is backed, across all pools");
            if (id != 0) {
                uint256 held = backing;
                for (uint256 i; i < wallets.length; ++i) {
                    held += MockERC20(address(uint160(id))).balanceOf(wallets[i]);
                }
                assertEq(
                    held,
                    MockERC20(address(uint160(id))).totalSupply(),
                    "token supply conserved across wallets and custody"
                );
            }
        }
        assertFalse(manager.isUnlocked(), "manager relocked");
        assertEq(manager.getNonzeroDeltaCount(), 0, "all deltas settled");
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

    function _seedClaims() internal {
        _submit(_order(0, actors[0], true, 1 ether, 2000e6));
        _submit(_order(0, actors[1], false, 1 ether, 2000e6));
        assertGt(manager.balanceOf(actors[0], uint160(address(token1))), 0, "successful matching must credit USDC");
    }

    function test_equalSaltsAcrossPoolsDoNotAliasOrders() public {
        // Equal raw amounts deliberately collide in the salt, despite different assets and decimals.
        AsyncOrder memory raw = _order(0, actors[0], true, 1 ether, 2500e6);
        raw.amountIn = 1e8;
        raw.amountOutMin = 100e6;
        AsyncOrder memory a = _submit(raw);
        AsyncOrder memory b = _submit(_order(1, actors[0], true, 1e8, 100e6));
        assertEq(a.salt, b.salt, "same tuple and block intentionally collide at salt level");
        assertTrue(_id(a) != _id(b), "pool identity separates order IDs");
        bytes32 untouched = _book(b);
        _cancel(a);
        assertEq(_live(a), 0);
        assertEq(_book(b), untouched, "other pool unchanged");
        _assertAccounting();
    }

    function test_executorGrantIsScopedToItsPool() public {
        AsyncOrder memory a = _submit(_order(0, actors[0], true, 1 ether, 2500e6));
        AsyncOrder memory b = _submit(_order(1, actors[0], true, 1e8, 100e6));
        ScopedExecutor executor = new ScopedExecutor(manager, hook);
        vm.prank(actors[0]);
        hook.setExecutor(a.key.toId(), address(executor), true);
        bytes32 before = _book(b);
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        executor.cancel(b);
        assertEq(_book(b), before);
        executor.cancel(a);
        assertEq(_live(a), 0);
        assertEq(_book(b), before);
        _assertAccounting();
    }

    function _grantSignature(uint256 p, uint256 nonce) internal view returns (bytes memory) {
        bytes32 hash = OrderSignatures.hashSetExecutor(markets[p], actors[0], actors[2], true, nonce, type(uint256).max);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(0xA11CE, keccak256(abi.encodePacked(hex"1901", hook.DOMAIN_SEPARATOR(), hash)));
        return abi.encodePacked(r, s, v);
    }

    function test_signaturePoolBindingAndGlobalNonceReplay() public {
        bytes memory sig = _grantSignature(0, 7);
        vm.expectRevert();
        hook.setExecutorWithSig(markets[1], actors[0], actors[2], true, 7, type(uint256).max, sig);
        assertFalse(hook.nonceUsed(actors[0], 7), "invalid signature must not consume nonce");
        hook.setExecutorWithSig(markets[0], actors[0], actors[2], true, 7, type(uint256).max, sig);
        assertTrue(hook.isExecutor(markets[0].toId(), actors[0], actors[2]));
        assertFalse(hook.isExecutor(markets[1].toId(), actors[0], actors[2]));
        sig = _grantSignature(1, 7);
        vm.expectRevert();
        hook.setExecutorWithSig(markets[1], actors[0], actors[2], true, 7, type(uint256).max, sig);
        assertFalse(hook.isExecutor(markets[1].toId(), actors[0], actors[2]));
        assertFalse(hook.nonceUsed(actors[1], 7), "nonce scope is maker-specific");
        sig = _grantSignature(1, 8);
        // Cheatcodes can change chain ID mid-call; read through Vm to prevent compiler rematerialization.
        uint256 chain = vm.getChainId();
        vm.chainId(chain + 1);
        vm.expectRevert();
        hook.setExecutorWithSig(markets[1], actors[0], actors[2], true, 8, type(uint256).max, sig);
        assertFalse(hook.nonceUsed(actors[0], 8));
        vm.chainId(chain);
        hook.setExecutorWithSig(markets[1], actors[0], actors[2], true, 8, type(uint256).max, sig);
        assertTrue(hook.isExecutor(markets[1].toId(), actors[0], actors[2]));
    }

    function testFuzz_shortPaymentCannotBorrowAnotherPoolsBacking(uint32 missing) public {
        missing = uint32(bound(missing, 1, 100e6 - 1));
        AsyncOrder memory parked = _submit(_order(0, actors[0], false, 1 ether, 1000e6));
        AdversarialPaymentToken t = _fault(token1);
        t.configure(missing, false, false);
        uint256 backing = token1.balanceOf(address(manager));
        bytes32 untouched = _book(parked);
        AsyncOrder memory o = _order(1, actors[1], false, 1e8, 100e6);
        vm.prank(o.owner);
        vm.expectRevert();
        router.swap(o, abi.encode(AsyncSwap.UserParams(o.owner, address(router), o.amountOutMin, o.priorityFee)));
        assertEq(token1.balanceOf(address(manager)), backing);
        assertEq(_book(parked), untouched);
        _assertAccounting();
    }

    function test_lateMixedWithdrawalFailureRestoresNativeAndTokenClaims() public {
        _seedClaims();
        AsyncOrder memory nativeOrder = _submit(_order(2, actors[0], true, 1 ether, 2500e6));
        _cancel(nativeOrder);
        Currency[] memory cs = new Currency[](2);
        cs[0] = Currency.wrap(address(0));
        cs[1] = currency1;
        uint256[] memory amounts = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            uint256 id = uint160(Currency.unwrap(cs[i]));
            amounts[i] = manager.balanceOf(actors[0], id);
            assertGt(amounts[i], 0);
            vm.prank(actors[0]);
            manager.approve(address(router), id, amounts[i]);
        }
        uint256 nativeBefore = actors[0].balance;
        uint256 usdBefore = token1.balanceOf(actors[0]);
        AdversarialPaymentToken t = _fault(token1);
        t.configure(0, true, false);
        vm.prank(actors[0]);
        vm.expectRevert();
        router.withdrawClaims(cs, amounts);
        assertEq(actors[0].balance, nativeBefore);
        assertEq(token1.balanceOf(actors[0]), usdBefore);
        for (uint256 i; i < 2; ++i) {
            uint256 id = uint160(Currency.unwrap(cs[i]));
            assertEq(manager.balanceOf(actors[0], id), amounts[i]);
            assertEq(manager.allowance(actors[0], address(router), id), amounts[i]);
        }
        t.configure(0, false, false);
        vm.prank(actors[0]);
        router.withdrawClaims(cs, amounts);
        assertEq(actors[0].balance, nativeBefore + amounts[0]);
        assertEq(token1.balanceOf(actors[0]), usdBefore + amounts[1]);
        _assertAccounting();
    }

    function test_frozenAssetCannotBlockAnotherPoolsSettlement() public {
        AsyncOrder memory stuck = _submit(_order(0, actors[0], true, 1 ether, 2500e6));
        AdversarialPaymentToken t = _fault(token0);
        t.configure(0, true, true);
        bytes32 before = _book(stuck);
        vm.expectRevert();
        _cancel(stuck);
        assertEq(_book(stuck), before, "failed payout preserves its claim to escrow");
        _submit(_order(1, actors[0], true, 1e8, 100e6));
        _submit(_order(1, actors[1], false, 1e8, 100e6));
        assertGt(manager.balanceOf(actors[0], uint160(address(token1))), 0, "other pool settled");
        assertEq(_book(stuck), before);
        _assertAccounting();
    }

    function test_taxFailureAndDonationsDoNotContaminateLaterCalls() public {
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
        uint256 tax = router.mevTax();
        assertGt(tax, 0);
        AsyncOrder memory a = _submit(_order(0, actors[0], true, 1 ether, 2500e6));
        uint256 nativeFees = manager.balanceOf(address(hook.feeVault()), 0);
        assertEq(nativeFees, tax);
        vm.deal(address(router), 7 ether);
        AsyncOrder memory b = _order(1, actors[1], true, 1e8, 100e6);
        vm.prank(b.owner);
        vm.expectRevert(bytes("msg.value != deposit + mevTax"));
        router.swap{value: tax - 1}(
            b, abi.encode(AsyncSwap.UserParams(b.owner, address(router), b.amountOutMin, b.priorityFee))
        );
        vm.prank(b.owner);
        token1.approve(address(router), 0);
        vm.prank(b.owner);
        vm.expectRevert();
        router.swap{value: tax}(
            b, abi.encode(AsyncSwap.UserParams(b.owner, address(router), b.amountOutMin, b.priorityFee))
        );
        assertEq(manager.balanceOf(address(hook.feeVault()), 0), nativeFees, "failed tax rolled back");
        _cancel(a);
        router.matchBook(markets[1], 8);
        assertEq(manager.balanceOf(address(hook.feeVault()), 0), nativeFees, "untaxed calls do not replay stale tax");
        vm.prank(b.owner);
        token1.approve(address(router), type(uint256).max);
        vm.txGasPrice(1 gwei);
        _submit(b);
        assertEq(manager.balanceOf(address(hook.feeVault()), 0), nativeFees);
        assertEq(address(router).balance, 7 ether);
        _assertAccounting();
    }

    function test_ownerRotationAndSweepCannotSpendSharedEscrow() public {
        AsyncOrder memory a = _submit(_order(0, actors[0], true, 1 ether, 2500e6));
        AsyncOrder memory b = _submit(_order(1, actors[1], false, 1e8, 100e6));
        _cancel(a);
        uint256 escrow = manager.balanceOf(address(hook), uint160(address(token1)));
        FeeVault vault = hook.feeVault();
        uint256 fees = manager.balanceOf(address(vault), uint160(address(token1)));
        assertGt(fees, 0);
        bytes32 untouched = _book(b);
        hook.transferOwnership(actors[2]);
        vm.prank(actors[2]);
        hook.acceptOwnership();
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vault.collect(currency1, actors[0]);
        uint256 before = token1.balanceOf(actors[0]);
        vm.prank(actors[2]);
        vault.collect(currency1, actors[0]);
        assertEq(token1.balanceOf(actors[0]), before + fees);
        token1.mint(address(hook), 5e6);
        vm.prank(actors[2]);
        hook.sweep(currency1, actors[0]);
        assertEq(token1.balanceOf(actors[0]), before + fees + 5e6);
        assertEq(manager.balanceOf(address(hook), uint160(address(token1))), escrow);
        assertEq(_book(b), untouched);
        _assertAccounting();
    }

    function test_partialFillTopUpMinimumRejectsAtomicallyThenAcceptsBoundary() public {
        AsyncOrder memory o = _submit(_order(0, actors[0], true, 2 ether, 2000e6));
        _submit(_order(0, actors[1], false, 1 ether, 2000e6));
        assertEq(_live(o), 1 ether, "maker partially filled");
        assertEq(hook.asyncOrderPriorityFee(o.key.toId(), _id(o)), 50_000, "bid consumed proportionally");
        bytes32 before = _book(o);
        uint256 wallet = token1.balanceOf(o.owner);
        uint256 custody = token1.balanceOf(address(manager));
        vm.prank(o.owner);
        vm.expectRevert(AsyncFiller.PriorityFeeTooSmall.selector);
        router.topUpPriorityFee(o, 49_999);
        assertEq(_book(o), before, "rejected top-up cannot requeue the maker");
        assertEq(token1.balanceOf(o.owner), wallet, "failed payment refunded");
        assertEq(token1.balanceOf(address(manager)), custody, "failed payment leaves no shared backing");
        _assertAccounting();
        vm.prank(o.owner);
        router.topUpPriorityFee(o, 50_000);
        assertEq(hook.asyncOrderPriorityFee(o.key.toId(), _id(o)), 100_000);
        assertEq(token1.balanceOf(o.owner), wallet - 50_000);
        _assertAccounting();
    }

    bool private traceCampaign;
    event StateCheckpoint(uint256 indexed step, bytes32 digest);
    event CampaignActionCount(uint256 indexed action, uint256 successes);

    function test_deterministicCampaignExercisesEveryAction() public {
        traceCampaign = true;
        uint256[8] memory counts = _campaign(0xa55e72026);
        for (uint256 i; i < counts.length; ++i) {
            emit CampaignActionCount(i, counts[i]);
            assertGt(counts[i], 0, "every action must execute successfully");
        }
    }

    /// @notice Accounting is independently summed across three pools after every action, including taxed calls.
    function testFuzz_threePoolAccountingAfterEveryAction(uint256 seed) public {
        _campaign(seed);
    }

    /// @dev Compare observable state by role so different deployment addresses do not hide parity errors.
    function _checkpoint() internal view returns (bytes32 digest) {
        for (uint256 i; i < tracked.length; ++i) {
            AsyncOrder memory o = tracked[i];
            (bool ok, bytes memory state) =
                address(hook).staticcall(abi.encodeCall(AsyncSwap.orderBookOrder, (o.key.toId(), _id(o))));
            assertTrue(ok, "order observation succeeds");
            digest = keccak256(abi.encode(digest, _id(o), _book(o), state));
        }
        for (uint256 p; p < markets.length; ++p) {
            for (uint256 side; side < 2; ++side) {
                (bool found, uint128 price, bytes32 id, address maker) = hook.bestOrder(markets[p].toId(), side == 1);
                (bytes32 head, bytes32 tail, uint32 count) = hook.orderBookLevel(markets[p].toId(), side == 1, price);
                digest = keccak256(abi.encode(digest, found, price, id, maker, head, tail, count));
            }
        }
        Currency[4] memory cs = [currency0, currency1, Currency.wrap(address(alt)), Currency.wrap(address(0))];
        address[10] memory wallets = _wallets();
        for (uint256 c; c < cs.length; ++c) {
            uint256 id = uint160(Currency.unwrap(cs[c]));
            for (uint256 w; w <= wallets.length; ++w) {
                address who = w == wallets.length ? address(manager) : wallets[w];
                uint256 balance = id == 0 ? who.balance : MockERC20(address(uint160(id))).balanceOf(who);
                digest = keccak256(
                    abi.encode(digest, balance, manager.balanceOf(who, id), manager.allowance(who, address(router), id))
                );
            }
        }
    }

    function _singleCurrency(Currency c) internal pure returns (Currency[] memory cs) {
        cs = new Currency[](1);
        cs[0] = c;
    }

    function _singleAmount(uint256 amount) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function _campaign(uint256 seed) internal returns (uint256[8] memory successes) {
        for (uint256 step; step < 64; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            vm.roll(1000 + step / 4);
            vm.warp(100_000 + step / 4);
            vm.fee(1 gwei);
            vm.txGasPrice(1 gwei + (seed >> 32) % 3 * 1 gwei);
            uint256 action = seed % 8;
            uint256 index;
            bool hasLive;
            if (tracked.length != 0) {
                for (uint256 n; n < tracked.length; ++n) {
                    index = ((seed >> 16) + n) % tracked.length;
                    if (_live(tracked[index]) != 0) {
                        hasLive = true;
                        break;
                    }
                }
            }
            if (!hasLive || step < 6) action = 0;
            if (action == 0) {
                uint256 p = (seed >> 8) % 3;
                uint256 unit = p == 1 ? 1e8 : 1 ether;
                uint256 price = (p == 1 ? 50 + (seed >> 64) % 101 : 1000 + (seed >> 64) % 2001) * 1e6;
                AsyncOrder memory fresh =
                    _order(p, actors[(seed >> 24) % 3], seed & 0x80000000 != 0, unit / 10 + (seed >> 96) % unit, price);
                if (seed & 0x100000000000 == 0) fresh.priorityFee = 0;
                _submit(fresh);
            } else {
                AsyncOrder memory o = tracked[index];
                if (action == 1) {
                    _cancel(o);
                } else if (action == 2) {
                    (, uint256 minimum) = hook.asyncOrderInfo(o.key.toId(), _id(o));
                    vm.prank(o.owner);
                    hook.updatePrice(o, minimum / 2 + 1);
                } else if (action == 3) {
                    vm.prank(o.owner);
                    // Partial fills can reduce a bid below the admission minimum. Add at least its cap.
                    router.topUpPriorityFee(o, 100_000 + (seed >> 64) % 100_000);
                } else if (action == 4) {
                    router.matchBook(o.key, 8);
                } else if (action == 5) {
                    _fill(o, actors[(seed >> 24) % 3]);
                } else if (action == 6) {
                    hook.feeVault()
                        .collect(seed & 0x10000000000 == 0 ? currency1 : Currency.wrap(address(0)), actors[2]);
                } else {
                    // Withdraw actual claims; never mint balances to make an action succeed.
                    address recipient = actors[(seed >> 24) % 3];
                    Currency[4] memory cs =
                        [currency0, currency1, Currency.wrap(address(alt)), Currency.wrap(address(0))];
                    bool withdrew;
                    for (uint256 n; n < cs.length; ++n) {
                        Currency c = cs[((seed >> 48) + n) % cs.length];
                        uint256 id = uint160(Currency.unwrap(c));
                        uint256 balance = manager.balanceOf(recipient, id);
                        if (balance == 0) continue;
                        uint256 amount = balance / 2 + balance % 2;
                        vm.prank(recipient);
                        manager.approve(address(router), id, amount);
                        vm.prank(recipient);
                        router.withdrawClaims(_singleCurrency(c), _singleAmount(amount));
                        withdrew = true;
                        break;
                    }
                    if (!withdrew) {
                        hook.feeVault().collect(currency1, actors[2]);
                        action = 6;
                    }
                }
            }
            ++successes[action];
            _assertAccounting();
            if (traceCampaign) emit StateCheckpoint(step, _checkpoint());
        }
        assertGt(successes[0], 0, "campaign must create actual orders");
    }
}
