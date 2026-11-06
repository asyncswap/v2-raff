// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {TokenClaims} from "../../reference/contracts/src/TokenClaims.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract ClaimsPortToken {
    mapping(address => uint256) public balanceOf;
    address public blocked;
    address public observer;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function configure(address b, address o) external {
        blocked = b;
        observer = o;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != blocked, "blocked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to == observer) ClaimsPortRecipient(payable(to)).onPayment();
        return true;
    }
}

contract ClaimsPortDepositor {
    IPoolManager immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }
    receive() external payable {}

    function seed(address owner, Currency currency, uint256 amount) external {
        manager.unlock(abi.encode(owner, currency, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address owner, Currency c, uint256 amount) = abi.decode(data, (address, Currency, uint256));
        if (Currency.unwrap(c) == address(0)) {
            manager.settle{value: amount}();
        } else {
            manager.sync(c);
            ClaimsPortToken(Currency.unwrap(c)).transfer(address(manager), amount);
            manager.settle();
        }
        manager.mint(owner, c.toId(), amount);
        return "";
    }
}

contract ClaimsPortRecipient {
    TokenClaims public claims;
    Currency public currency;
    bytes public error;

    function configure(TokenClaims c, Currency token) external {
        claims = c;
        currency = token;
    }

    function onPayment() public {
        try claims.redeem(currency, address(this), 1) {
            revert("reentry succeeded");
        } catch (bytes memory e) {
            error = e;
        }
    }

    receive() external payable {
        onPayment();
    }
}

/// @notice Same calls against the pinned Solidity source and hand-written Huff, using a real PoolManager.
contract TokenClaimsParityTest is Test {
    IPoolManager manager;
    TokenClaims solidityClaims;
    TokenClaims huffClaims;
    ClaimsPortToken token;
    ClaimsPortDepositor depositor;
    Currency currency;
    address alice = makeAddr("claims owner");
    address recipient = makeAddr("claims recipient");

    function setUp() public {
        manager = new PoolManager(address(this));
        solidityClaims = new TokenClaims(manager);
        bytes memory code =
            HuffNeoDeployer.config().with_args(abi.encode(manager)).creation_code_with_args("src/TokenClaims.huff");
        address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0));
        huffClaims = TokenClaims(deployed);
        assertEq(address(huffClaims.poolManager()), address(manager));
        token = new ClaimsPortToken();
        currency = Currency.wrap(address(token));
        depositor = new ClaimsPortDepositor(manager);
    }

    function _seed(Currency c, uint256 amount) internal {
        if (Currency.unwrap(c) == address(0)) vm.deal(address(depositor), amount);
        else token.mint(address(depositor), amount);
        depositor.seed(alice, c, amount);
        vm.startPrank(alice);
        manager.approve(address(solidityClaims), c.toId(), amount);
        manager.approve(address(huffClaims), c.toId(), amount);
        vm.stopPrank();
    }

    function _redeem(TokenClaims claims, Currency c, address to, uint256 amount) internal returns (bytes32 result) {
        vm.recordLogs();
        vm.prank(alice);
        (bool ok, bytes memory data) = address(claims).call(abi.encodeCall(claims.redeem, (c, to, amount)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Only the implementation addresses differ between runs; preserve every topic and data byte.
        bytes32 logHash;
        for (uint256 i; i < logs.length; ++i) {
            address emitter = logs[i].emitter == address(claims) ? address(1) : logs[i].emitter;
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0] == keccak256("Transfer(address,address,address,uint256,uint256)")
            ) {
                (address operator, uint256 quantity) = abi.decode(logs[i].data, (address, uint256));
                assertEq(operator, address(claims));
                logs[i].data = abi.encode(address(1), quantity);
            }
            logHash = keccak256(abi.encode(logHash, emitter, logs[i].topics, logs[i].data));
        }
        bytes32 stateHash = keccak256(
            abi.encode(
                manager.balanceOf(alice, c.toId()),
                manager.allowance(alice, address(claims), c.toId()),
                to.balance,
                token.balanceOf(to)
            )
        );
        result = keccak256(abi.encode(ok, data, logHash, stateHash));
    }

    function _parity(Currency c, address to, uint256 amount) internal {
        uint256 snapshot = vm.snapshotState();
        bytes32 expected = _redeem(solidityClaims, c, to, amount);
        vm.revertToState(snapshot);
        assertEq(_redeem(huffClaims, c, to, amount), expected, "return, event, balance and allowance parity");
    }

    function testFuzz_partialAndFullRedemption(uint128 total, uint128 used) public {
        // PoolManager currency deltas are int128, including the deposit used to seed claims.
        total = uint128(bound(total, 1, uint128(type(int128).max)));
        used = uint128(bound(used, 1, total));
        _seed(currency, total);
        _parity(currency, recipient, used);
        assertEq(token.balanceOf(recipient), used);
        assertEq(manager.balanceOf(alice, currency.toId()), total - used);
    }

    function test_nativeCurrency() public {
        Currency native = Currency.wrap(address(0));
        _seed(native, 5 ether);
        _parity(native, recipient, 2 ether);
        assertEq(recipient.balance, 2 ether);
    }

    function test_rejectedTransferRollsBackAllowanceAndClaims() public {
        _seed(currency, 50);
        token.configure(recipient, address(0));
        _parity(currency, recipient, 20);
        assertEq(manager.balanceOf(alice, currency.toId()), 50);
        assertEq(manager.allowance(alice, address(huffClaims), currency.toId()), 50);
        token.configure(address(0), address(0));
        vm.prank(alice);
        huffClaims.redeem(currency, recipient, 50);
        assertEq(token.balanceOf(recipient), 50);
        vm.prank(alice);
        vm.expectRevert();
        huffClaims.redeem(currency, recipient, 1);
    }

    function test_invalidAndUnapprovedRedemptions() public {
        _seed(currency, 10);
        _parity(currency, address(0), 1);
        _parity(currency, recipient, 0);
        vm.startPrank(alice);
        manager.approve(address(huffClaims), currency.toId(), 0);
        manager.approve(address(solidityClaims), currency.toId(), 0);
        vm.stopPrank();
        _parity(currency, recipient, 1);
        assertEq(manager.balanceOf(alice, currency.toId()), 10);
    }

    function test_reentryBlockedAndLockCleared() public {
        _seed(currency, 10);
        ClaimsPortRecipient r = new ClaimsPortRecipient();
        token.configure(address(0), address(r));
        r.configure(huffClaims, currency);
        vm.prank(alice);
        huffClaims.redeem(currency, address(r), 4);
        assertEq(r.error(), abi.encodeWithSelector(TokenClaims.ReentrantRedemption.selector));
        vm.prank(alice);
        huffClaims.redeem(currency, recipient, 6);
        assertEq(token.balanceOf(recipient), 6);
    }

    function _rawParity(bytes memory callData, address caller) internal {
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        (bool a, bytes memory x) = address(solidityClaims).call(callData);
        vm.revertToState(snapshot);
        vm.prank(caller);
        (bool b, bytes memory y) = address(huffClaims).call(callData);
        assertEq(b, a, "raw success parity");
        assertEq(y, x, "raw return/revert parity");
    }

    function testFuzz_callbackEncoding(bytes memory data, bool fromManager) public {
        _rawParity(abi.encodeCall(solidityClaims.unlockCallback, (data)), fromManager ? address(manager) : alice);
    }

    function testFuzz_malformedStaticHead(bytes32 c, bytes32 to, uint256 amount, uint8 length) public {
        bytes memory data = abi.encodePacked(TokenClaims.redeem.selector, c, to, amount);
        if (length < 100) {
            assembly ("memory-safe") { mstore(data, length) }
        }
        _rawParity(data, alice);
    }

    function test_callbackNoncanonicalOffsetsAndBounds() public {
        for (uint256 offset; offset < 160; offset += 16) {
            _rawParity(
                abi.encodePacked(
                    TokenClaims.unlockCallback.selector, bytes32(offset), bytes32(uint256(128)), new bytes(160)
                ),
                alice
            );
        }
        _rawParity(abi.encodePacked(TokenClaims.unlockCallback.selector, bytes32(type(uint256).max)), alice);
        _rawParity(
            abi.encodePacked(TokenClaims.unlockCallback.selector, bytes32(uint256(32)), bytes32(type(uint256).max)),
            alice
        );
    }
}
