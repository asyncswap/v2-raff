// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

interface IHuffRatioProbe {
    function le(uint256, uint256, uint256, uint256) external view returns (bool);
}

/// @dev ABI bridge only. The four tree-layout tests are reference-only; their APIs deliberately revert.
library HuffEligiblePrice {
    struct Ratio {
        uint256 numerator;
        uint256 denominator;
    }
    address internal constant PROBE = address(0x48554646524154494f);

    function le(Ratio memory a, Ratio memory b) internal view returns (bool) {
        return IHuffRatioProbe(PROBE).le(a.numerator, a.denominator, b.numerator, b.denominator);
    }

    function refresh(RadixPriceTree.Tree storage, mapping(uint32 => Ratio) storage, uint128, Ratio memory, bool)
        internal
        pure
    {
        revert("reference-only tree layout");
    }

    function remove(RadixPriceTree.Tree storage, mapping(uint32 => Ratio) storage, uint128, bool) internal pure {
        revert("reference-only tree layout");
    }

    function best(RadixPriceTree.Tree storage, mapping(uint32 => Ratio) storage, Ratio memory, bool)
        internal
        pure
        returns (bool, uint128)
    {
        revert("reference-only tree layout");
    }
}
