//SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface IWorldIDVerifier {
    function verify(
        uint256 nullifier,
        uint256 action,
        uint64 rpId,
        uint256 nonce,
        uint256 signalHash,
        uint64 expiresAtMin,
        uint64 issuerSchemaId,
        uint256 credentialGenesisIssuedAtMin,
        uint256[5] calldata zeroKnowledgeProof
    ) external view;
}

abstract contract WorldIdVerifier {
    IWorldIDVerifier public immutable WORLD_ID_VERIFIER;
    uint256 public immutable WORLD_APP_ACTION;
    uint64 public immutable WORLD_APP_RP_ID;

    uint256 _nonces;

    /// TODO: unused for now; will be used to prevent banned clients from re-registering with a different wallet.
    mapping(uint256 worldIdNullifier => bool known) _nullifierUsed;
    error NullifierAlreadyUsed();

    constructor(IWorldIDVerifier _verifier) {
        WORLD_ID_VERIFIER = _verifier;
    }

    function worldIdNonce() external view returns (uint256) {
        return _nonces;
    }

    function _verifyWorldId(
        uint256 nullifier,
        uint256 signalHash,
        uint64 expiresAtMin,
        uint64 issuerSchemaId,
        uint256 credentialGenesisIssuedAtMin,
        uint256[5] calldata proof
    ) internal {
        if (_nullifierUsed[nullifier]) revert NullifierAlreadyUsed();

        WORLD_ID_VERIFIER.verify(
            nullifier,
            WORLD_APP_ACTION,
            WORLD_APP_RP_ID,
            _nonces++,
            signalHash,
            expiresAtMin,
            issuerSchemaId,
            credentialGenesisIssuedAtMin,
            proof
        );

        _nullifierUsed[nullifier] = true;
    }
}