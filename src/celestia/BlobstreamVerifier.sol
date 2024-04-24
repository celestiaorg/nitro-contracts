// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {IBlobstreamX} from "./IBlobstreamX.sol";

import "./DAVerifier.sol";
import "lib/blobstream-contracts/src/Constants.sol";
import "lib/blobstream-contracts/src/DataRootTuple.sol";
import "lib/blobstream-contracts/src/lib/tree/binary/BinaryMerkleProof.sol";
import "lib/blobstream-contracts/src/lib/tree/binary/BinaryMerkleTree.sol";
import "lib/blobstream-contracts/src/lib/tree/namespace/NamespaceMerkleTree.sol";
import "lib/blobstream-contracts/src/lib/tree/Types.sol";

/**
 * @dev Go struct representation of batch data for a Celestia DA orbit chain
 *
 * @param BlockHeight The height of the block containing the blob.
 * @param Start The starting index of the blob within the block.
 * @param SharesLength The length of the shares in the blob.
 * @param DataRoot A 32-byte hash representing the root of the data.
 * @param TxCommitment A 32-byte hash representing the commitment to transactions.
 */
// struct BlobPointer {
//     uint64 BlockHeight;
//     uint64 Start;
//     uint64 SharesLength;
//     bytes32 DataRoot;
//     bytes32 TxCommitment;
// }

/// @title CelestiaBatchVerifier: Utility library to verify Nitro batches against Blobstream
/// @dev The CelestiaBatchVerifier verifies batch data against Blobstream and returns either:
/// - IN_BLOBSTREAM, meaning that the batch was found in Blobstream.
/// - COUNTERFACTUAL_COMMITMENT, meaning that the commitment's Celestia block height has been
/// proven in Blobstream not to contain the commitment
/// - UNDECIDED meaning that the block height has not been proven yet in Blobstream
/// If the proof data is invalid, it reverts
library CelestiaBatchVerifier {
    /// @dev The heights in the batch data and proof do not match
    error MismatchedHeights();

    /// @dev The attestation and or row root proof was invalid
    error InvalidProof();

    /// @title Result
    /// @notice Enumerates the possible outcomes for data verification processes.
    /// @dev Provides a standardized way to represent the verification status of data.
    enum Result {
        /// @dev Indicates the data has been verified to exist within Blobstream.
        IN_BLOBSTREAM,
        /// @dev Represents a situation where the batch data has been proven to be incorrect. Or BlobstreamX was frozen
        COUNTERFACTUAL_COMMITMENT,
        /// @dev The height for the batch data has not been committed to by Blobstream yet.
        UNDECIDED
    }

    /**
     * @notice Given some batch data with the structre of `BlobPointer`, verifyBatch validates:
     * 1. The Celestia Height for the batch data is in blobsream.
     * 2. The user supplied proof's data root exists in Blobstream.
     * 2. The the data root from the batch data and the valid user supplied proof match, and the
     *    span of shares for the batch data is available (i.e the start + length of a blob does not
     *    go outside the bounds of the origianal celestia data square for the given height)
     *
     * Rationale:
     * Validators possess the preimages for the data root and row roots, making it necessary only to verify
     * the existence and the length (span) of the index and blob length.
     * This ensures the data published by the batch poster is available.
     */
    function verifyBatch(address _blobstream, bytes calldata _data) internal view returns (Result) {
        IBlobstreamX blobstreamX = IBlobstreamX(_blobstream);

        uint256 offset = 0;
        uint256 height;
        uint256 start;
        uint256 length;
        bytes32 dataRoot;

        assembly {
            height := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)

            start := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)

            length := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)

            dataRoot := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)
        }

        // If the height is to far into the future (10000 blocks), return COUNTERFACTUAL_COMMITMENT
        // because the batch poster is trying to stall
        if (height > (blobstreamX.latestBlock() + 10000)) return Result.COUNTERFACTUAL_COMMITMENT;

        if (height > blobstreamX.latestBlock()) return Result.UNDECIDED;

        bytes1 minVersion;
        bytes28 minId;
        bytes1 maxVersion;
        bytes28 maxId;
        bytes32 digest;

        assembly {
            minVersion := calldataload(add(_data.offset, offset))
            offset := add(offset, 1)

            minId := calldataload(add(_data.offset, offset))
            offset := add(offset, 28)

            maxVersion := calldataload(add(_data.offset, offset))
            offset := add(offset, 1)

            maxId := calldataload(add(_data.offset, offset))
            offset := add(offset, 28)

            digest := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)
        }

        NamespaceNode memory _rowRoot = NamespaceNode(
            Namespace({version: minVersion, id: minId}),
            Namespace({version: maxVersion, id: maxId}),
            digest
        );

        uint256 merkleProofSideNodesLength;
        assembly {
            merkleProofSideNodesLength := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)
        }

        // Parse Binary Merkle Proof
        bytes32[] memory merkleProofSideNodes = new bytes32[](merkleProofSideNodesLength);
        for (uint256 i = 0; i < merkleProofSideNodesLength; ++i) {
            assembly {
                mstore(
                    add(merkleProofSideNodes, add(0x20, mul(i, 0x20))),
                    calldataload(add(add(_data.offset, offset), mul(i, 0x20)))
                )
            }
        }

        uint256 merkleProofkey;
        uint256 merkleProofNumLeaves;
        assembly {
            merkleProofkey := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)

            merkleProofNumLeaves := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)
        }

        BinaryMerkleProof memory _rowProof = BinaryMerkleProof(
            merkleProofSideNodes,
            merkleProofkey,
            merkleProofNumLeaves
        );

        uint256 tupleRootNonce;
        uint256 tupleHeight;
        bytes32 tupleDataRoot;

        assembly {
            tupleRootNonce := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)

            tupleHeight := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)

            tupleDataRoot := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)
        }

        uint256 attestationProofSideNodesLength;
        assembly {
            attestationProofSideNodesLength := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)
        }

        // Parse Binary Merkle Proof
        bytes32[] memory attestationProofSideNodes = new bytes32[](attestationProofSideNodesLength);
        for (uint256 i = 0; i < attestationProofSideNodesLength; ++i) {
            assembly {
                mstore(
                    add(attestationProofSideNodes, add(0x20, mul(i, 0x20))),
                    calldataload(add(add(_data.offset, offset), mul(i, 0x20)))
                )
            }
        }

        uint256 attestaionProofkey;
        uint256 attestaionProofNumLeaves;
        assembly {
            attestaionProofkey := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)

            attestaionProofNumLeaves := calldataload(add(_data.offset, offset))
            offset := add(offset, 32)
        }

        AttestationProof memory _attestationProof = AttestationProof(
            tupleRootNonce,
            DataRootTuple(tupleHeight, tupleDataRoot),
            BinaryMerkleProof(
                attestationProofSideNodes,
                attestaionProofkey,
                attestaionProofNumLeaves
            )
        );

        // check height against the one in the batch data, if they do not match,
        // revert, because the user supplied proof does not verify against
        // the batch's celestia height.
        if (height != _attestationProof.tuple.height) revert MismatchedHeights();

        // Verify the row root proof and data root attestation
        // change to verifyRowRootToDataRootTupleRootProof
        // use only one namespace Node and BinaryMerkleProof
        (bool valid, ) = DAVerifier.verifyRowRootToDataRootTupleRoot(
            IDAOracle(_blobstream),
            _rowRoot,
            _rowProof,
            _attestationProof,
            _attestationProof.tuple.dataRoot
        );
        if (!valid) revert InvalidProof();

        // check the data root in the proof against the one in the batch data.
        // if they do not match, its a counterfactual commitment, because
        // 1. the user supplied proof proves the height was relayed to Blobstream
        //    (we know the height is valid because it's less than or equal to the latest block)
        // 2. the data root from the batch data does not exist at the height the batch poster claimed
        //    to have posted to.
        if (dataRoot != _attestationProof.tuple.dataRoot) return Result.COUNTERFACTUAL_COMMITMENT;

        // Calculate size of the Original Data Square (ODS)
        (uint256 squareSize, ) = DAVerifier.computeSquareSizeFromRowProof(_rowProof);

        // Check that the start + length posted by the batch poster is not out of bounds
        // otherwise return counterfactual commitment
        if (start + length > squareSize) return Result.COUNTERFACTUAL_COMMITMENT;

        // At this point, there has been:
        // 1. A succesfull proof that shows the height and data root the batch poster included
        //    in the batch data exist in Blobstream.
        // 2. A proof that the sequence the batch poster included in the batch data is inside
        //    of the data square (remember, any valid row root proof can show this is true)
        // 3. No deadlocks or incorrect counter factual commitments have been made, since:
        //    - If the height in the batch is less than the latest height in blobstrea,
        //      a valid attestation + row proof must exist for it
        //    - we have shown that the batch poster did not lie about the data root and height,
        //      nor about the span being in the bounds of the square. Thus, validators have
        //      access to the data through the preimage oracle
        return Result.IN_BLOBSTREAM;
    }
}
