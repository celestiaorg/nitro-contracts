// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../state/Value.sol";
import "../state/Machine.sol";
import "../state/Deserialize.sol";
import "../state/ModuleMemory.sol";
import "../osp/IOneStepProver.sol";
import "../bridge/Messages.sol";
import "../bridge/IBridge.sol";
import {IBlobstreamX} from "../celestia/IBlobstreamX.sol";

import "../celestia/BlobstreamVerifier.sol";

contract OneStepProverHostIoCelestiaMock is IOneStepProver {
    using GlobalStateLib for GlobalState;
    using MerkleProofLib for MerkleProof;
    using ModuleMemoryLib for ModuleMemory;
    using ValueLib for Value;
    using ValueStackLib for ValueStack;
    using CelestiaBatchVerifier for address;

    uint256 private constant LEAF_SIZE = 32;
    uint256 private constant INBOX_NUM = 2;
    uint64 private constant INBOX_HEADER_LEN = 40;
    uint64 private constant DELAYED_HEADER_LEN = 112 + 1;

    // Header Bytes
    bytes1 public constant CELESTIA_MESSAGE_HEADER_FLAG = 0x63;

    // Blobstream contract
    address public constant BLOBSTREAM = 0x8F0FEbB820C4858e3C815f87391bdE38E62b4A8a;

    function setLeafByte(bytes32 oldLeaf, uint256 idx, uint8 val) internal pure returns (bytes32) {
        require(idx < LEAF_SIZE, "BAD_SET_LEAF_BYTE_IDX");
        // Take into account that we are casting the leaf to a big-endian integer
        uint256 leafShift = (LEAF_SIZE - 1 - idx) * 8;
        uint256 newLeaf = uint256(oldLeaf);
        newLeaf &= ~(0xFF << leafShift);
        newLeaf |= uint256(val) << leafShift;
        return bytes32(newLeaf);
    }

    function executeGetOrSetBytes32(
        Machine memory mach,
        Module memory mod,
        GlobalState memory state,
        Instruction calldata inst,
        bytes calldata proof
    ) internal pure {
        uint256 ptr = mach.valueStack.pop().assumeI32();
        uint32 idx = mach.valueStack.pop().assumeI32();

        if (idx >= GlobalStateLib.BYTES32_VALS_NUM) {
            mach.status = MachineStatus.ERRORED;
            return;
        }
        if (ptr + 32 > mod.moduleMemory.size || ptr % LEAF_SIZE != 0) {
            mach.status = MachineStatus.ERRORED;
            return;
        }

        uint256 leafIdx = ptr / LEAF_SIZE;
        uint256 proofOffset = 0;
        bytes32 startLeafContents;
        MerkleProof memory merkleProof;
        (startLeafContents, proofOffset, merkleProof) = mod.moduleMemory.proveLeaf(
            leafIdx,
            proof,
            proofOffset
        );

        if (inst.opcode == Instructions.GET_GLOBAL_STATE_BYTES32) {
            mod.moduleMemory.merkleRoot = merkleProof.computeRootFromMemory(
                leafIdx,
                state.bytes32Vals[idx]
            );
        } else if (inst.opcode == Instructions.SET_GLOBAL_STATE_BYTES32) {
            state.bytes32Vals[idx] = startLeafContents;
        } else {
            revert("BAD_GLOBAL_STATE_OPCODE");
        }
    }

    function executeGetU64(Machine memory mach, GlobalState memory state) internal pure {
        uint32 idx = mach.valueStack.pop().assumeI32();

        if (idx >= GlobalStateLib.U64_VALS_NUM) {
            mach.status = MachineStatus.ERRORED;
            return;
        }

        mach.valueStack.push(ValueLib.newI64(state.u64Vals[idx]));
    }

    function executeSetU64(Machine memory mach, GlobalState memory state) internal pure {
        uint64 val = mach.valueStack.pop().assumeI64();
        uint32 idx = mach.valueStack.pop().assumeI32();

        if (idx >= GlobalStateLib.U64_VALS_NUM) {
            mach.status = MachineStatus.ERRORED;
            return;
        }
        state.u64Vals[idx] = val;
    }

    uint256 internal constant BLS_MODULUS =
        52435875175126190479447740508185965837690552500527637822603658699938581184513;
    uint256 internal constant PRIMITIVE_ROOT_OF_UNITY =
        10238227357739495823651030575849232062558860180284477541189508159991286009131;

    // Computes b**e % m
    // Really pure but the Solidity compiler sees the staticcall and requires view
    function modExp256(uint256 b, uint256 e, uint256 m) internal view returns (uint256) {
        bytes memory modExpInput = abi.encode(32, 32, 32, b, e, m);
        (bool modexpSuccess, bytes memory modExpOutput) = address(0x05).staticcall(modExpInput);
        require(modexpSuccess, "MODEXP_FAILED");
        require(modExpOutput.length == 32, "MODEXP_WRONG_LENGTH");
        return uint256(bytes32(modExpOutput));
    }

    function executeReadPreImage(
        ExecutionContext calldata,
        Machine memory mach,
        Module memory mod,
        Instruction calldata inst,
        bytes calldata proof
    ) internal view {
        uint256 preimageOffset = mach.valueStack.pop().assumeI32();
        uint256 ptr = mach.valueStack.pop().assumeI32();
        if (preimageOffset % 32 != 0 || ptr + 32 > mod.moduleMemory.size || ptr % LEAF_SIZE != 0) {
            mach.status = MachineStatus.ERRORED;
            return;
        }

        uint256 leafIdx = ptr / LEAF_SIZE;
        uint256 proofOffset = 0;
        bytes32 leafContents;
        MerkleProof memory merkleProof;
        (leafContents, proofOffset, merkleProof) = mod.moduleMemory.proveLeaf(
            leafIdx,
            proof,
            proofOffset
        );

        bytes memory extracted;
        uint8 proofType = uint8(proof[proofOffset]);
        proofOffset++;
        // These values must be kept in sync with `arbitrator/arbutil/src/types.rs`
        // and `arbutil/preimage_type.go` (both in the nitro repo).
        if (inst.argumentData == 0) {
            // The machine is asking for a keccak256 preimage

            if (proofType == 0) {
                bytes calldata preimage = proof[proofOffset:];
                require(keccak256(preimage) == leafContents, "BAD_PREIMAGE");

                uint256 preimageEnd = preimageOffset + 32;
                if (preimageEnd > preimage.length) {
                    preimageEnd = preimage.length;
                }
                extracted = preimage[preimageOffset:preimageEnd];
            } else {
                // TODO: support proving via an authenticated contract
                revert("UNKNOWN_PREIMAGE_PROOF");
            }
        } else if (inst.argumentData == 1) {
            // The machine is asking for a sha2-256 preimage

            require(proofType == 0, "UNKNOWN_PREIMAGE_PROOF");
            bytes calldata preimage = proof[proofOffset:];
            require(sha256(preimage) == leafContents, "BAD_PREIMAGE");

            uint256 preimageEnd = preimageOffset + 32;
            if (preimageEnd > preimage.length) {
                preimageEnd = preimage.length;
            }
            extracted = preimage[preimageOffset:preimageEnd];
        } else if (inst.argumentData == 2) {
            // The machine is asking for an Ethereum versioned hash preimage

            require(proofType == 0, "UNKNOWN_PREIMAGE_PROOF");

            // kzgProof should be a valid input to the EIP-4844 point evaluation precompile at address 0x0A.
            // It should prove the preimageOffset/32'th word of the machine's requested KZG commitment.
            bytes calldata kzgProof = proof[proofOffset:];

            require(bytes32(kzgProof[:32]) == leafContents, "KZG_PROOF_WRONG_HASH");

            uint256 fieldElementsPerBlob;
            uint256 blsModulus;
            {
                (bool success, bytes memory kzgParams) = address(0x0A).staticcall(kzgProof);
                require(success, "INVALID_KZG_PROOF");
                require(kzgParams.length > 0, "KZG_PRECOMPILE_MISSING");
                (fieldElementsPerBlob, blsModulus) = abi.decode(kzgParams, (uint256, uint256));
            }

            // With a hardcoded PRIMITIVE_ROOT_OF_UNITY, we can only support this BLS modulus.
            // It may be worth in the future supporting arbitrary BLS moduli, but we would likely need to
            // validate a user-supplied root of unity.
            require(blsModulus == BLS_MODULUS, "UNKNOWN_BLS_MODULUS");

            // If preimageOffset is greater than or equal to the blob size, leave extracted empty and call it here.
            if (preimageOffset < fieldElementsPerBlob * 32) {
                // We need to compute what point the polynomial should be evaluated at to get the right part of the preimage.
                // KZG commitments use a bit reversal permutation to order the roots of unity.
                // To account for that, we reverse the bit order of the index.
                uint256 bitReversedIndex = 0;
                // preimageOffset was required to be 32 byte aligned above
                uint256 tmp = preimageOffset / 32;
                for (uint256 i = 1; i < fieldElementsPerBlob; i <<= 1) {
                    bitReversedIndex <<= 1;
                    if (tmp & 1 == 1) {
                        bitReversedIndex |= 1;
                    }
                    tmp >>= 1;
                }

                // First, we get the root of unity of order 2**fieldElementsPerBlob.
                // We start with a root of unity of order 2**32 and then raise it to
                // the power of (2**32)/fieldElementsPerBlob to get root of unity we need.
                uint256 rootOfUnityPower = (1 << 32) / fieldElementsPerBlob;
                // Then, we raise the root of unity to the power of bitReversedIndex,
                // to retrieve this word of the KZG commitment.
                rootOfUnityPower *= bitReversedIndex;
                // z is the point the polynomial is evaluated at to retrieve this word of data
                uint256 z = modExp256(PRIMITIVE_ROOT_OF_UNITY, rootOfUnityPower, blsModulus);
                require(bytes32(kzgProof[32:64]) == bytes32(z), "KZG_PROOF_WRONG_Z");

                extracted = kzgProof[64:96];
            }
        } else {
            revert("UNKNOWN_PREIMAGE_TYPE");
        }

        for (uint256 i = 0; i < extracted.length; i++) {
            leafContents = setLeafByte(leafContents, i, uint8(extracted[i]));
        }

        mod.moduleMemory.merkleRoot = merkleProof.computeRootFromMemory(leafIdx, leafContents);

        mach.valueStack.push(ValueLib.newI32(uint32(extracted.length)));
    }

    function validateSequencerInbox(
        ExecutionContext calldata execCtx,
        uint64 msgIndex,
        bytes calldata message
    ) internal view returns (bool) {
        // need to check where exactly does proof offset usually land, see how we can get get rid of the length delimiter
        // also review delayed message inbox issue Ottersect reported.
        require(message.length >= INBOX_HEADER_LEN, "BAD_SEQINBOX_PROOF");

        uint64 afterDelayedMsg;
        (afterDelayedMsg, ) = Deserialize.u64(message, 32);
        bytes32 messageHash = keccak256(message);
        bytes32 beforeAcc;
        bytes32 delayedAcc;

        if (msgIndex > 0) {
            beforeAcc = execCtx.bridge.sequencerInboxAccs(msgIndex - 1);
        }
        if (afterDelayedMsg > 0) {
            delayedAcc = execCtx.bridge.delayedInboxAccs(afterDelayedMsg - 1);
        }
        bytes32 acc = keccak256(abi.encodePacked(beforeAcc, messageHash, delayedAcc));
        require(acc == execCtx.bridge.sequencerInboxAccs(msgIndex), "BAD_SEQINBOX_MESSAGE");
        return true;
    }

    function validateDelayedInbox(
        ExecutionContext calldata execCtx,
        uint64 msgIndex,
        bytes calldata message
    ) internal view returns (bool) {
        require(message.length >= DELAYED_HEADER_LEN, "BAD_DELAYED_PROOF");

        bytes32 beforeAcc;

        if (msgIndex > 0) {
            beforeAcc = execCtx.bridge.delayedInboxAccs(msgIndex - 1);
        }

        bytes32 messageDataHash = keccak256(message[DELAYED_HEADER_LEN:]);
        bytes1 kind = message[0];
        uint256 sender;
        (sender, ) = Deserialize.u256(message, 1);

        bytes32 messageHash = keccak256(
            abi.encodePacked(kind, uint160(sender), message[33:DELAYED_HEADER_LEN], messageDataHash)
        );
        bytes32 acc = Messages.accumulateInboxMessage(beforeAcc, messageHash);

        require(acc == execCtx.bridge.delayedInboxAccs(msgIndex), "BAD_DELAYED_MESSAGE");
        return true;
    }

    function validateDaProof(bytes calldata proof, uint256 offset) internal view returns (uint256) {
        // NOTE: the offset points to 40 bytes after the proof offset, which should point to a
        // batch header flag for a sequencer inbox message
        uint256 proofEnd;

        if (proof[0] & CELESTIA_MESSAGE_HEADER_FLAG != 0) {
            CelestiaBatchVerifier.Result result = CelestiaBatchVerifier.verifyBatch(
                BLOBSTREAM,
                proof[1:]
            );

            if (result == CelestiaBatchVerifier.Result.UNDECIDED) revert("BLOBSTREAM_UNDECIDED");

            // if its a counterfactual commitment, we replace the batch data with an empty batch
            if (result == CelestiaBatchVerifier.Result.COUNTERFACTUAL_COMMITMENT) {
                // this would slice the array into an empty batch
                proofEnd = offset;
            }

            if (result == CelestiaBatchVerifier.Result.IN_BLOBSTREAM) {
                // remove Celestia DA proof from proof
                // add 88 for the 88 bytes in a celestia batch
                // (the offset at this point already includes the batch header)
                proofEnd = offset + 89;
            }
        }

        return proofEnd;
    }

    function executeReadInboxMessage(
        ExecutionContext calldata execCtx,
        Machine memory mach,
        Module memory mod,
        Instruction calldata inst,
        bytes calldata proof
    ) internal view {
        uint256 messageOffset = mach.valueStack.pop().assumeI32();
        uint256 ptr = mach.valueStack.pop().assumeI32();
        uint256 msgIndex = mach.valueStack.pop().assumeI64();
        if (
            inst.argumentData == Instructions.INBOX_INDEX_SEQUENCER &&
            msgIndex >= execCtx.maxInboxMessagesRead
        ) {
            mach.status = MachineStatus.TOO_FAR;
            return;
        }

        if (ptr + 32 > mod.moduleMemory.size || ptr % LEAF_SIZE != 0) {
            mach.status = MachineStatus.ERRORED;
            return;
        }

        uint256 leafIdx = ptr / LEAF_SIZE;
        uint256 proofOffset = 0;
        bytes32 leafContents;
        MerkleProof memory merkleProof;
        (leafContents, proofOffset, merkleProof) = mod.moduleMemory.proveLeaf(
            leafIdx,
            proof,
            proofOffset
        );
        {
            // TODO: support proving via an authenticated contract
            require(proof[proofOffset] == 0, "UNKNOWN_INBOX_PROOF");
            proofOffset++;

            uint256 proofEnd = proof.length;

            function(ExecutionContext calldata, uint64, bytes calldata)
                internal
                view
                returns (bool) inboxValidate;

            bool success;
            if (inst.argumentData == Instructions.INBOX_INDEX_SEQUENCER) {
                inboxValidate = validateSequencerInbox;
                if (proof[proofOffset + 40] & CELESTIA_MESSAGE_HEADER_FLAG != 0) {
                    proofEnd = validateDaProof(proof[proofOffset + 40:], proofOffset + 40);
                }
            } else if (inst.argumentData == Instructions.INBOX_INDEX_DELAYED) {
                inboxValidate = validateDelayedInbox;
            } else {
                mach.status = MachineStatus.ERRORED;
                return;
            }
            success = inboxValidate(execCtx, uint64(msgIndex), proof[proofOffset:proofEnd]);
            if (!success) {
                mach.status = MachineStatus.ERRORED;
                return;
            }
        }

        require(proof.length >= proofOffset, "BAD_MESSAGE_PROOF");
        uint256 messageLength = proof.length - proofOffset;

        uint32 i = 0;
        for (; i < 32 && messageOffset + i < messageLength; i++) {
            leafContents = setLeafByte(
                leafContents,
                i,
                uint8(proof[proofOffset + messageOffset + i])
            );
        }

        mod.moduleMemory.merkleRoot = merkleProof.computeRootFromMemory(leafIdx, leafContents);
        mach.valueStack.push(ValueLib.newI32(i));
    }

    function executeHaltAndSetFinished(
        ExecutionContext calldata,
        Machine memory mach,
        Module memory,
        Instruction calldata,
        bytes calldata
    ) internal pure {
        mach.status = MachineStatus.FINISHED;
    }

    function executeGlobalStateAccess(
        ExecutionContext calldata,
        Machine memory mach,
        Module memory mod,
        Instruction calldata inst,
        bytes calldata proof
    ) internal pure {
        uint16 opcode = inst.opcode;

        GlobalState memory state;
        uint256 proofOffset = 0;
        (state, proofOffset) = Deserialize.globalState(proof, proofOffset);
        require(state.hash() == mach.globalStateHash, "BAD_GLOBAL_STATE");

        if (
            opcode == Instructions.GET_GLOBAL_STATE_BYTES32 ||
            opcode == Instructions.SET_GLOBAL_STATE_BYTES32
        ) {
            executeGetOrSetBytes32(mach, mod, state, inst, proof[proofOffset:]);
        } else if (opcode == Instructions.GET_GLOBAL_STATE_U64) {
            executeGetU64(mach, state);
        } else if (opcode == Instructions.SET_GLOBAL_STATE_U64) {
            executeSetU64(mach, state);
        } else {
            revert("INVALID_GLOBALSTATE_OPCODE");
        }

        mach.globalStateHash = state.hash();
    }

    function executeOneStep(
        ExecutionContext calldata execCtx,
        Machine calldata startMach,
        Module calldata startMod,
        Instruction calldata inst,
        bytes calldata proof
    ) external view override returns (Machine memory mach, Module memory mod) {
        mach = startMach;
        mod = startMod;

        uint16 opcode = inst.opcode;

        function(
            ExecutionContext calldata,
            Machine memory,
            Module memory,
            Instruction calldata,
            bytes calldata
        ) internal view impl;

        if (
            opcode >= Instructions.GET_GLOBAL_STATE_BYTES32 &&
            opcode <= Instructions.SET_GLOBAL_STATE_U64
        ) {
            impl = executeGlobalStateAccess;
        } else if (opcode == Instructions.READ_PRE_IMAGE) {
            impl = executeReadPreImage;
        } else if (opcode == Instructions.READ_INBOX_MESSAGE) {
            impl = executeReadInboxMessage;
        } else if (opcode == Instructions.HALT_AND_SET_FINISHED) {
            impl = executeHaltAndSetFinished;
        } else {
            revert("INVALID_MEMORY_OPCODE");
        }

        impl(execCtx, mach, mod, inst, proof);
    }
}
