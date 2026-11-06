// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";
import {MockERC20} from "./utils/MockERC20.sol";

import {AsyncSwap} from "src/AsyncSwap.sol";
import {Router} from "src/Router.sol";
import {FeeVault} from "src/FeeVault.sol";
import {NativeClaims} from "src/NativeClaims.sol";
import {TokenClaims} from "src/TokenClaims.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {ISignatureTransfer} from "src/interfaces/ISignatureTransfer.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

/// @notice Deploys the hook at an address whose low 14 bits are its permission flags, without the
///         `deployCodeTo` cheatcode (unsupported by Medusa/Echidna). The Router needs the hook address
///         and the hook needs the Router address, so the Router's CREATE address is predicted first:
///         this factory's nonce is 1, the CREATE2 hook deploy uses it, and the Router lands on nonce 2.
contract AsyncSwapDeployer {
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant MASK = uint160((1 << 14) - 1);

    AsyncSwap public hook;
    Router public router;

    constructor(IPoolManager manager, Currency numeraire, address owner) {
        address predictedRouter = _createAddress(address(this), 2);
        bytes memory initCode = abi.encodePacked(
            type(AsyncSwap).creationCode,
            abi.encode(manager, numeraire, owner, predictedRouter, uint256(0), type(uint8).max)
        );
        bytes32 initCodeHash = keccak256(initCode);
        uint256 salt;
        while (uint160(_create2Address(salt, initCodeHash)) & MASK != FLAGS) {
            ++salt;
        }
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed != address(0), "hook deploy failed");
        hook = AsyncSwap(payable(deployed));
        router = new Router(manager, hook, ISignatureTransfer(address(0)), 0);
        require(address(router) == predictedRouter, "router address mismatch");
    }

    function _create2Address(uint256 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @dev RLP address for nonces 1..127.
    function _createAddress(address deployer, uint8 nonce) private pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(nonce))))));
    }
}

/// @notice Base contract with state variables and setup functions
abstract contract Base is StringUtils, Clamp, Deployer, Math {
    using DecimalPrinter for uint256;
    using PoolIdLibrary for PoolKey;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1_000 ether;
    uint256 internal constant INITIAL_TOKEN_BALANCE = 10_000_000e6; // USDC per actor

    /// @dev sqrt(2000e6 / 1e18) * 2^96: 2,000 USDC per ETH, ETH = currency0, 6-decimal USDC = currency1.
    uint160 internal constant SQRT_PRICE_2000 = 3543191142285914327220224;
    int24 internal constant TICK_2000 = -200311;
    /// @dev Order prices the handlers draw from (USDC per ETH), straddling the pool price.
    uint256 internal constant MIN_PRICE = 1_000e6;
    uint256 internal constant MAX_PRICE = 4_000e6;
    uint256 internal constant MIN_BID = 100_000; // $0.10, AsyncFiller.MIN_PRIORITY_FEE

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    struct Ghosts {
        uint256 _placeholder;
    }

    Ghosts internal ghosts;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;

    modifier asActor() virtual {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier asAdmin() virtual {
        vm.startPrank(admin);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    PoolManager internal manager;
    MockERC20 internal usdc;
    AsyncSwap internal hook;
    Router internal router;
    FeeVault internal feeVault;
    NativeClaims internal nativeClaims;
    TokenClaims internal tokenClaims;
    PoolModifyLiquidityTest internal lpRouter;

    PoolKey internal key;
    PoolId internal poolId;

    /// @dev Every order the handlers placed, with the salt the hook assigned. Ids are recomputed
    ///      on demand; closed orders read back `amountIn == 0`.
    AsyncOrder[] internal orders;

    uint256 internal seededEth;
    uint256 internal seededUsdc;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    /// @dev The LP router refunds unused ETH to the tester.
    receive() external payable {}

    function setup() internal {
        admin = address(this);
        manager = new PoolManager(admin);
        usdc = new MockERC20(admin, 0, "USD Coin", "USDC", 6);

        AsyncSwapDeployer deployer = new AsyncSwapDeployer(manager, Currency.wrap(address(usdc)), admin);
        hook = deployer.hook();
        router = deployer.router();
        feeVault = hook.feeVault();

        nativeClaims = new NativeClaims(manager);
        tokenClaims = new TokenClaims(manager);

        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_2000);

        _seedLiquidity();
        setupActors();
    }

    /// @dev ~1% band around spot, the same depth the project's LP invariant suite uses.
    function _seedLiquidity() internal {
        lpRouter = new PoolModifyLiquidityTest(manager);
        usdc.deal(admin, 50_000_000e6);
        usdc.approve(address(lpRouter), type(uint256).max);
        uint256 ethBefore = address(manager).balance;
        uint256 usdcBefore = usdc.balanceOf(address(manager));
        lpRouter.modifyLiquidity{value: 20_000 ether}(
            key, ModifyLiquidityParams(TICK_2000 - 100, TICK_2000 + 100, 1e20, 0), ""
        );
        seededEth = address(manager).balance - ethBefore;
        seededUsdc = usdc.balanceOf(address(manager)) - usdcBefore;
    }

    function setupActors() internal {
        vm.label(admin, "Admin");

        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            vm.label(_actor, ACTOR_LABELS[i]);

            usdc.deal(_actor, INITIAL_TOKEN_BALANCE);
            vm.startPrank(_actor);
            usdc.approve(address(router), type(uint256).max);
            hook.setExecutor(poolId, address(router), true);
            manager.setOperator(address(nativeClaims), true);
            manager.setOperator(address(tokenClaims), true);
            vm.stopPrank();
        }
        actor = actors[0];
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    function orderId(AsyncOrder memory order) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, order.key.toId(), order.owner, order.zeroForOne, order.salt));
    }

    function liveAmountIn(AsyncOrder memory order) internal view returns (uint256) {
        return hook.asyncOrder(poolId, orderId(order));
    }

    /// @dev Pick a recorded order by entropy; `found` is false when none is live.
    function pickLiveOrder(uint256 entropy) internal view returns (bool found, AsyncOrder memory order) {
        uint256 n = orders.length;
        if (n == 0) return (false, order);
        for (uint256 i; i < n; ++i) {
            order = orders[(entropy + i) % n];
            if (liveAmountIn(order) != 0) return (true, order);
        }
        return (false, order);
    }

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }
}
