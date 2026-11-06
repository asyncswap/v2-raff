// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalOzE, CustomRevertHarness} from "./FormalOzE.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean` (v4-core
///         `CustomRevert.bubbleUpAndRevertWith`, through `CustomRevertHarness`, which first makes the call
///         whose return data is wrapped). The model's `.error ⟨"revert"⟩` is an assembly revert with no
///         payload; the bytecode's payload is `WrappedError(c, sel, returndata, ctx)`, checked as well.
contract AsyncSwapBubbleUpAndRevertWithFormalTest is FormalOzE {
    CustomRevertHarness h;

    function setUp() public override {
        super.setUp();
        h = new CustomRevertHarness();
    }

    function _bubble(bool fail, bytes memory reason, address c, bytes4 sel, bytes4 ctx)
        internal
        returns (bool ok, bytes memory ret)
    {
        _configure(fail, reason);
        (ok, ret) =
            address(h).call(abi.encodeCall(CustomRevertHarness.bubble, (address(responder), hex"01", c, sel, ctx)));
    }

    function _wrapped(address c, bytes4 sel, bytes memory reason, bytes4 ctx) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CustomRevert.WrappedError.selector, c, sel, reason, abi.encodePacked(ctx));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean:22 — reverts unconditionally, whatever
    ///         the arguments and state.
    function testFuzz_bubbleUpAndRevertWith_reverts(bool fail, bytes memory reason, address c, bytes4 sel, bytes4 ctx)
        public
    {
        (bool ok, bytes memory ret) = _bubble(fail, reason, c, sel, ctx);
        assertFalse(ok);
        assertEq(ret, _wrapped(c, sel, reason, ctx), "WrappedError payload");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean:27 — the same statement for the fully
    ///         qualified generated def: it always reverts.
    function testFuzz_bubbleUpAndRevertWith_reverts_(bool fail, bytes memory reason, address c, bytes4 sel, bytes4 ctx)
        public
    {
        (bool ok, bytes memory ret) = _bubble(fail, reason, c, sel, ctx);
        assertFalse(ok);
        assertEq(ret, _wrapped(c, sel, reason, ctx), "WrappedError payload");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean:32 — no successful run exists.
    function testFuzz_bubbleUpAndRevertWith_never_ok(bool fail, bytes memory reason, address c, bytes4 sel, bytes4 ctx)
        public
    {
        (bool ok,) = _bubble(fail, reason, c, sel, ctx);
        assertFalse(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean:38 — the outcome does not depend on the
    ///         arguments or state: both runs revert. (The model's "revert" carries no payload; the bytecode's
    ///         payloads differ with the arguments, as the WrappedError checks above show.)
    function testFuzz_bubbleUpAndRevertWith_indep(
        bool fail,
        bytes memory reason,
        address c,
        bytes4 sel,
        bytes4 ctx,
        bool fail2,
        bytes memory reason2,
        address c2,
        bytes4 sel2,
        bytes4 ctx2
    ) public {
        (bool ok1,) = _bubble(fail, reason, c, sel, ctx);
        (bool ok2,) = _bubble(fail2, reason2, c2, sel2, ctx2);
        assertFalse(ok1);
        assertEq(ok1, ok2, "same outcome");
    }
}
