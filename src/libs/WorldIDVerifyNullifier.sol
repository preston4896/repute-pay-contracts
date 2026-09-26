//SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

contract WorldIdVerifyNullifier {
    using ECDSA for bytes32;

    uint256 public immutable WORLD_APP_ACTION;
    uint64 public immutable WORLD_APP_RP_ID;

    /// @dev World ID Verifier contract address takes precedence over
    /// the trusted service verifier address
    IWorldIDVerifier public worldIdVerifier;
    address public trustedServiceVerifier;

    mapping(uint256 worldIdNullifier => bool known) _nullifierUsed;

    error ZeroAddressVerifier();
    error ServiceVerifierDeprecated();
    error InvalidWorldProofSignal();
    error InvalidServiceSignature();
    error NullifierAlreadyUsed();

    event WorldIdVerifierSet(IWorldIDVerifier indexed verifier);
    event WorldServiceVerifierSet(address indexed verifier);

    constructor(address _worldIdVerifier, address _trustedServiceVerifier, uint256 _action, uint64 _rpId) {
        WORLD_APP_ACTION = _action;
        WORLD_APP_RP_ID = _rpId;
        if (_worldIdVerifier != address(0)) {
            _setWorldIdVerifier(_worldIdVerifier);
        } else {
            _setServiceVerifier(_trustedServiceVerifier);
        }

        bool verifierSet = address(worldIdVerifier) != address(0) || trustedServiceVerifier != address(0);
        require(verifierSet, ZeroAddressVerifier());
    }

    function _verifyWorldIdNullifier(bytes calldata data) internal returns (uint256 nullifier) {
        if (address(worldIdVerifier) != address(0)) {
            nullifier = uint256(bytes32(data[0:32]));
            /// @dev we might need to make use of this to do caller address check
            uint256 nonce = uint256(bytes32(data[32:64]));
            uint256 signalHash = uint256(bytes32(data[64:96]));
            uint64 expiresAtMin = uint64(bytes8(data[96:104]));
            uint64 issuerSchemaId = uint64(bytes8(data[104:112]));
            uint256 credentialGenesisIssuedAtMin = uint256(bytes32(data[112:144]));
            uint256[5] memory proof;
            for (uint256 i = 0; i < 5; i++) {
                proof[i] = uint256(bytes32(data[144 + (32 * i):176 + (32 * i)]));
            }
            _verifyWorldId(nullifier, nonce, signalHash, expiresAtMin, issuerSchemaId, credentialGenesisIssuedAtMin, proof);
        } else {
            nullifier = uint256(bytes32(data[0:32]));
            address boundedEoa = address(bytes20(data[32:52]));

            /// @dev ideally, the caller itself is the same wallet to bind with the nullifier
            require(msg.sender == boundedEoa, InvalidWorldProofSignal());

            bytes memory signature = data[52:117];
            _verifyServiceSignature(nullifier, boundedEoa, signature);
        }
    }

    /// @dev once IWorldIDVerifier is set to non-zero address
    /// @dev this effectively and permanently revokes offchain service verifier
    function _setWorldIdVerifier(address _verifier) internal {
        require(address(_verifier) != address(0), ZeroAddressVerifier());
        worldIdVerifier = IWorldIDVerifier(_verifier);

        emit WorldIdVerifierSet(worldIdVerifier);
    }

    function _setServiceVerifier(address _verifier) internal {
        require(address(worldIdVerifier) == address(0), ServiceVerifierDeprecated());
        require(_verifier != address(0), ZeroAddressVerifier());
        trustedServiceVerifier = _verifier;

        emit WorldServiceVerifierSet(_verifier);
    }

    function _unsetNullifier(uint256 worldIdNullifier) internal {
        delete _nullifierUsed[worldIdNullifier];
    }

    // @dev: this is mostly wrong. 
    // the goal of this hackathon for now is to get backend service to work correctly.
    function _verifyWorldId(
        uint256 nullifier,
        uint256 nonce,
        uint256 signalHash,
        uint64 expiresAtMin,
        uint64 issuerSchemaId,
        uint256 credentialGenesisIssuedAtMin,
        uint256[5] memory proof
    ) internal {
        if (_nullifierUsed[nullifier]) revert NullifierAlreadyUsed();

        worldIdVerifier.verify(
            nullifier,
            WORLD_APP_ACTION,
            WORLD_APP_RP_ID,
            nonce,
            signalHash,
            expiresAtMin,
            issuerSchemaId,
            credentialGenesisIssuedAtMin,
            proof
        );

        _nullifierUsed[nullifier] = true;
    }

    function _verifyServiceSignature(uint256 _nullifier, address _boundedEoa, bytes memory signature) private {
        if (_nullifierUsed[_nullifier]) revert NullifierAlreadyUsed();

        bytes32 messageHash =
            keccak256(abi.encodePacked(_nullifier, _boundedEoa, WORLD_APP_ACTION, WORLD_APP_RP_ID));

        address signer = messageHash.recover(signature);
        if (signer != trustedServiceVerifier) revert InvalidServiceSignature();

        _nullifierUsed[_nullifier] = true;
    }
}
