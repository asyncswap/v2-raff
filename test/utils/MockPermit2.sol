// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {ISignatureTransfer} from "../reference/ISignatureTransfer.sol";

/// @notice A reduced Permit2: `permitWitnessTransferFrom` with Permit2's exact `PermitHash.hashWithWitness`
///         digest (so the Router's witness type string is verified for real), unordered nonces as a map, and
///         EOA signatures only.
contract MockPermit2 is ISignatureTransfer {
    bytes32 private constant _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string private constant _PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    error SignatureExpired();
    error InvalidNonce();
    error InvalidAmount();
    error InvalidSigner();

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, keccak256("Permit2"), block.chainid, address(this)));
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external {
        if (block.timestamp > permit.deadline) revert SignatureExpired();
        if (transferDetails.requestedAmount > permit.permitted.amount) revert InvalidAmount();
        if (nonceUsed[owner][permit.nonce]) revert InvalidNonce();
        nonceUsed[owner][permit.nonce] = true;

        bytes32 typeHash = keccak256(abi.encodePacked(_PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB, witnessTypeString));
        bytes32 tokenPermissionsHash = keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 structHash =
            keccak256(abi.encode(typeHash, tokenPermissionsHash, msg.sender, permit.nonce, permit.deadline, witness));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (ECDSA.recover(digest, signature) != owner) revert InvalidSigner();

        IERC20Minimal(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}
