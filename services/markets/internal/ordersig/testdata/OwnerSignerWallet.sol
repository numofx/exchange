// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Minimal ERC-1271 contract wallet: valid iff the signature is a plain ECDSA signature
/// over `hash` from `owner`. Mirrors a 1-of-1 Safe / Privy smart account closely enough
/// to exercise the verifier's contract-signer branch end to end.
contract OwnerSignerWallet {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) {
            return 0xffffffff;
        }
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) {
            v += 27;
        }
        address recovered = ecrecover(hash, v, r, s);
        if (recovered != address(0) && recovered == owner) {
            return 0x1626ba7e;
        }
        return 0xffffffff;
    }
}
