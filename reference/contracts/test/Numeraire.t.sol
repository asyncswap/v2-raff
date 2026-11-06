// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {BaseHook} from "src/BaseHook.sol";
import {Router} from "src/Router.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {ISignatureTransfer} from "src/interfaces/ISignatureTransfer.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {Permit2Bytecode} from "./utils/Permit2Bytecode.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

/// @dev Only bypasses permission-address mining for constructor rejection tests.
contract NumeraireConstructorHarness is AsyncSwap {
    constructor(IPoolManager manager, Currency quote, address owner_, address router_, uint256 minOrderUsd)
        AsyncSwap(manager, quote, owner_, router_, minOrderUsd, type(uint8).max)
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract NumeraireTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 usdc;
    MockERC20 asset;
    address maker = makeAddr("maker");
    address filler = makeAddr("filler");

    function setUp() public {
        manager = new PoolManager(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        asset = new MockERC20("Asset", "ASSET", 18);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        router = new Router(manager, AsyncSwap(payable(address(flags))), ISignatureTransfer(Permit2Bytecode.PERMIT2), 0);
        deployCodeTo(
            "AsyncSwap.sol",
            abi.encode(
                manager, Currency.wrap(address(usdc)), address(this), address(router), uint256(0), type(uint8).max
            ),
            address(flags)
        );
        hook = AsyncSwap(payable(address(flags)));
    }

    function _key(address a, address b) internal view returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
    }

    function _expectMissingNumeraire() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(AsyncSwap.NumeraireRequired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_numeraireIsConfiguredToken() public view {
        assertEq(Currency.unwrap(hook.numeraire()), address(usdc));
    }

    function test_rejectZeroNumeraire() public {
        vm.expectRevert(AsyncSwap.InvalidNumeraire.selector);
        new NumeraireConstructorHarness(manager, Currency.wrap(address(0)), address(this), address(0xCAFE), 0);
    }

    function test_rejectNonContractNumeraire() public {
        vm.expectRevert(AsyncSwap.InvalidNumeraire.selector);
        new NumeraireConstructorHarness(
            manager, Currency.wrap(makeAddr("not a token")), address(this), address(0xCAFE), 0
        );
    }

    /// @dev CREATE2 deployments run the constructor from the deterministic deployer, so the owner
    ///      must come from the argument, never from `msg.sender`.
    function test_ownerIsExplicitArgumentNotDeployer() public {
        address protocolOwner = makeAddr("protocol owner");
        AsyncSwap h =
            new NumeraireConstructorHarness(manager, Currency.wrap(address(usdc)), protocolOwner, address(0xCAFE), 0);
        assertEq(h.owner(), protocolOwner);
        assertTrue(h.owner() != address(this));
    }

    function test_rejectZeroOwner() public {
        vm.expectRevert(AsyncSwap.ZeroAddress.selector);
        new NumeraireConstructorHarness(manager, Currency.wrap(address(usdc)), address(0), address(0xCAFE), 0);
    }

    /// The constructor scales the dollar minimum and the $0.10 bid cap by the numeraire's own decimals.
    function test_minimumAndCapFollowNumeraireDecimals() public {
        AsyncSwap six =
            new NumeraireConstructorHarness(manager, Currency.wrap(address(usdc)), address(this), address(0xCAFE), 10);
        assertEq(six.minOrder(), 10e6, "$10 of 6-decimal USDC");
        assertEq(six.priorityFeeCap(), 0.1e6, "$0.10 of 6-decimal USDC");

        MockERC20 usdm = new MockERC20("USDM", "USDM", 18);
        AsyncSwap eighteen =
            new NumeraireConstructorHarness(manager, Currency.wrap(address(usdm)), address(this), address(0xCAFE), 10);
        assertEq(eighteen.minOrder(), 10 ether, "$10 of an 18-decimal stablecoin");
        assertEq(eighteen.priorityFeeCap(), 0.1 ether, "$0.10 of an 18-decimal stablecoin");
    }

    function test_rejectNumeraireDecimalsOutOfRange() public {
        MockERC20 none = new MockERC20("Zero", "ZERO", 0);
        vm.expectRevert(AsyncSwap.UnsupportedNumeraireDecimals.selector);
        new NumeraireConstructorHarness(manager, Currency.wrap(address(none)), address(this), address(0xCAFE), 0);

        MockERC20 many = new MockERC20("Many", "MANY", 21);
        vm.expectRevert(AsyncSwap.UnsupportedNumeraireDecimals.selector);
        new NumeraireConstructorHarness(manager, Currency.wrap(address(many)), address(this), address(0xCAFE), 0);
    }

    /// The minimum order and bid cap are immutables: no owner call can change them for any pool.
    function test_poolParametersFixedAtDeployment() public view {
        assertEq(hook.minOrder(), 0);
        assertEq(hook.priorityFeeCap(), 0.1e6);
    }

    function test_acceptNumeraireOnEitherSortedSide() public {
        // Deployed assets at the extremes of the address range: the hook rejects an asset with no code.
        address lowAsset = address(0x1000);
        address highAsset = address(type(uint160).max - 0xff);
        deployCodeTo("test/utils/MockERC20.sol:MockERC20", abi.encode("Low", "LOW", uint8(18)), lowAsset);
        deployCodeTo("test/utils/MockERC20.sol:MockERC20", abi.encode("High", "HI", uint8(18)), highAsset);
        PoolKey memory low = _key(lowAsset, address(usdc));
        PoolKey memory high = _key(address(usdc), highAsset);
        assertEq(Currency.unwrap(low.currency1), address(usdc));
        assertEq(Currency.unwrap(high.currency0), address(usdc));
        manager.initialize(low, 2 ** 96);
        manager.initialize(high, 2 ** 96);
    }

    function test_acceptNativeUsdcPool() public {
        manager.initialize(_key(address(0), address(usdc)), 2 ** 96);
    }

    function test_rejectNativeNonUsdcPool() public {
        PoolKey memory invalid = _key(address(0), address(asset));
        _expectMissingNumeraire();
        manager.initialize(invalid, 2 ** 96);
    }

    function test_rejectTokenWithUsdcSymbolButWrongAddress() public {
        MockERC20 impostor = new MockERC20("USD Coin", "USDC", 6);
        PoolKey memory invalid = _key(address(asset), address(impostor));
        _expectMissingNumeraire();
        manager.initialize(invalid, 2 ** 96);
    }

    function testFuzz_rejectPairsWithoutNumeraire(address a, address b) public {
        vm.assume(a != b && a != address(usdc) && b != address(usdc));
        PoolKey memory invalid = _key(a, b);
        _expectMissingNumeraire();
        manager.initialize(invalid, 2 ** 96);
    }

    function test_sellAssetForSixDecimalUsdc() public {
        _trade(false);
    }

    function test_buyAssetWithSixDecimalUsdc() public {
        _trade(true);
    }

    function _trade(bool buyAsset) internal {
        PoolKey memory key = _key(address(asset), address(usdc));
        manager.initialize(key, 2 ** 96);
        MockERC20 input = buyAsset ? usdc : asset;
        MockERC20 output = buyAsset ? asset : usdc;
        uint256 amountIn = buyAsset ? 100e6 : 1 ether;
        uint256 netOutput = buyAsset ? 1 ether : 99_700_000;
        // No filler surcharge: the filler pays exactly the minimum; each side pays the 0.02% trade fee.
        uint256 grossOutput = netOutput;
        uint256 outFee = Math.mulDiv(netOutput, 2, 10_000, Math.Rounding.Ceil);
        uint256 inFee = Math.mulDiv(amountIn, 2, 10_000, Math.Rounding.Ceil);
        bool direction = Currency.unwrap(key.currency0) == address(input);
        AsyncOrder memory order = AsyncOrder(key, maker, direction, amountIn, netOutput, 100_000, 2 ** 96, bytes32(0));
        input.mint(maker, amountIn);
        usdc.mint(maker, 100_000);
        output.mint(filler, grossOutput);
        vm.startPrank(maker);
        hook.setExecutor(key.toId(), address(router), true);
        input.approve(address(router), amountIn + 100_000);
        usdc.approve(address(router), amountIn + 100_000);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), netOutput, 100_000)));
        vm.stopPrank();
        order.salt =
            keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, netOutput, 100_000));
        vm.startPrank(filler);
        output.approve(address(router), grossOutput);
        router.fillOrder(order, grossOutput, "");
        vm.stopPrank();
        assertEq(output.balanceOf(maker), netOutput - outFee);
        assertEq(input.balanceOf(filler), amountIn - inFee);
        assertEq(output.balanceOf(filler), 0);
        assertEq(
            manager.balanceOf(address(hook.feeVault()), uint160(address(output))), outFee + (buyAsset ? 0 : 100_000)
        );
        assertEq(manager.balanceOf(address(hook.feeVault()), uint160(address(input))), inFee + (buyAsset ? 100_000 : 0));
        assertEq(
            hook.asyncOrder(key.toId(), keccak256(abi.encode(block.chainid, key.toId(), maker, direction, order.salt))),
            0
        );
    }
}
