"""User-approved boundary: preserve Solidity architecture assertions verbatim without claiming Huff execution."""

STRUCTURE = "Asserts Solidity storage layout, write footprint, or cached immutable bytecode; retained unchanged as reference-only."
REFERENCE_ONLY_FILES = {
    "test/formal/SpecBook.t.sol": "Asserts Solidity tree/level slots and write footprints; retained as a layout reference.",
    "test/IndexLibraryDeployment.t.sol": "Deploys Solidity linked libraries, which are inlined in Huff.",
    "test/IncomingLibraryDeployment.t.sol": "Deploys a Solidity linked library, which is inlined in Huff.",
    "test/formal/Eip712ConstantsLog.t.sol": "Diagnostic constant logger with no behavioral assertions.",
}
REFERENCE_ONLY_TESTS = {
    "test/EligiblePrice.t.sol": dict.fromkeys(
        [
            "testFuzz_mutationsAndEligibility",
            "test_full128BranchPathAndIdReuse",
            "test_recycledSummaryMustPropagateToNewAncestors",
            "test_recycledBuySummaryMustPropagateToNewAncestors",
        ],
        STRUCTURE,
    ),
    "test/formal/AsyncSwapAddOrder.t.sol": dict.fromkeys(
        [
            "test_addOrder_tickDirectionZeroBoundary",
            "test_addOrder_tickExtremeRatioClamps",
            "testFuzz_addOrder_run",
            "testFuzz_addOrder_ok",
            "testFuzz_addState_order",
            "testFuzz_addState_book",
            "testFuzz_addState_other_order",
            "testFuzz_addState_other_pool",
            "testFuzz_addState_frame",
            "testFuzz_matching_addOrder_eq",
            "testFuzz_matching_addOrder_run",
            "testFuzz_matching_addOrder_ok",
        ],
        STRUCTURE,
    ),
    "test/formal/SpecCore.t.sol": dict.fromkeys(
        [
            "test_note_beforeSwap_frame_hcreate_false",
            "testFuzz_CreateOrderSpec_run",
            "testFuzz_createBody_frame",
            "testFuzz_beforeSwap_frame_of_spec",
            "testFuzz_CreateOrderSpec_run_repeat",
            "testFuzz_CreateOrderSpec_run_addOrderGuards",
        ],
        STRUCTURE,
    ),
    "test/formal/AsyncSwapBeforeInitialize.t.sol": dict.fromkeys(
        [
            "testFuzz_beforeInitialize_run_ok",
            "testFuzz_beforeInitialize_ok",
            "testFuzz_beforeInitialize_ok_inv",
            "testFuzz_beforeInitialize_frame",
            "test_beforeInitialize_run_ok_viaPoolManager",
        ],
        STRUCTURE,
    ),
    "test/formal/AsyncSwapAsyncOrder.t.sol": {"testFuzz_asyncOrder_ok_iff": STRUCTURE},
    "test/formal/AsyncSwapConstructor.t.sol": dict.fromkeys(
        [
            "testFuzz_ctor_ok_iff",
            "testFuzz_ctor_fresh_state",
        ],
        STRUCTURE,
    ),
    "test/formal/RouterConstructor.t.sol": dict.fromkeys(
        [
            "testFuzz_CtorSpec",
            "testFuzz_CtorSpec_name_word",
            "testFuzz_CtorSpec_version_word",
            "testFuzz_ctor_deployed",
        ],
        STRUCTURE,
    ),
    "test/formal/SpecEip712.t.sol": dict.fromkeys(
        [
            "testFuzz_toString_name",
            "testFuzz_toString_version",
            "testFuzz_name_ne_sentinel",
            "testFuzz_version_ne_sentinel",
            "testFuzz_CtorSpec",
            "testFuzz_CtorSpec_name_word",
            "testFuzz_CtorSpec_version_word",
        ],
        STRUCTURE,
    ),
}
