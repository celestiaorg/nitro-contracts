// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2021, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.7;

import "../libraries/IGasRefunder.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice DEPRECATED - only for classic version, see new repo (https://github.com/OffchainLabs/nitro/tree/master/contracts)
 * for new updates
 */
contract GasRefunderOpt is IGasRefunder, Ownable {
    address public immutable allowedContract;
    address public immutable allowedRefundee;

    uint256 public immutable maxRefundeeBalance;
    uint256 public immutable extraGasMargin;
    uint256 public immutable calldataCost;
    uint256 public immutable maxGasTip;
    uint256 public immutable maxGasCost;
    uint256 public immutable maxSingleGasUsage;

    enum RefundDenyReason {
        CONTRACT_NOT_ALLOWED,
        REFUNDEE_NOT_ALLOWED,
        REFUNDEE_ABOVE_MAX_BALANCE,
        OUT_OF_FUNDS
    }

    event SuccessfulRefundedGasCosts(
        uint256 gas,
        uint256 gasPrice,
        uint256 amountPaid
    );

    event FailedRefundedGasCosts(
        uint256 gas,
        uint256 gasPrice,
        uint256 amountPaid
    );

    event RefundGasCostsDenied(
        address indexed refundee,
        address indexed contractAddress,
        RefundDenyReason indexed reason,
        uint256 gas
    );
    event Deposited(address sender, uint256 amount);
    event Withdrawn(address initiator, address destination, uint256 amount);

    constructor(
        address _allowedContract, 
        address _allowedRefundee, 
        uint128 _maxRefundeeBalance,
        uint32 _extraGasMargin,
        uint8 _calldataCost,
        uint64 _maxGasTip,
        uint64 _maxGasCost,
        uint32 _maxSingleGasUsage
    ) Ownable() {
        allowedContract = _allowedContract;
        allowedRefundee = _allowedRefundee;

        // The following are cast to uint256 types for gas efficiency.
        // The deployment argument types are kept as the original types as a hint to the deployer.
        // Deployer is responsible for setting reasonable values.
        maxRefundeeBalance = _maxRefundeeBalance;
        extraGasMargin = _extraGasMargin;
        calldataCost = _calldataCost;
        maxGasTip = _maxGasTip;
        maxGasCost = _maxGasCost;
        maxSingleGasUsage = _maxSingleGasUsage;
    }

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(address payable destination, uint256 amount) external onlyOwner {
        // It's expected that destination is an EOA
        (bool success, ) = destination.call{value: amount}("");
        require(success, "WITHDRAW_FAILED");
        emit Withdrawn(msg.sender, destination, amount);
    }

    function onGasSpent(
        address payable refundee,
        uint256 gasUsed,
        uint256 calldataSize
    ) external override returns (bool success) {
        uint256 startGasLeft = gasleft();

        uint256 ownBalance = address(this).balance;

        if (ownBalance == 0) {
            emit RefundGasCostsDenied(refundee, msg.sender, RefundDenyReason.OUT_OF_FUNDS, gasUsed);
            return false;
        }

        if (allowedContract != msg.sender) {
            emit RefundGasCostsDenied(
                refundee,
                msg.sender,
                RefundDenyReason.CONTRACT_NOT_ALLOWED,
                gasUsed
            );
            return false;
        }
        if (allowedRefundee != refundee) {
            emit RefundGasCostsDenied(
                refundee,
                msg.sender,
                RefundDenyReason.REFUNDEE_NOT_ALLOWED,
                gasUsed
            );
            return false;
        }

        uint256 estGasPrice = block.basefee + maxGasTip;
        if (tx.gasprice < estGasPrice) {
            estGasPrice = tx.gasprice;
        }
        if (maxGasCost != 0 && estGasPrice > maxGasCost) {
            estGasPrice = maxGasCost;
        }

        uint256 refundeeBalance = refundee.balance;

        // Add in a bit of a buffer for the tx costs not measured with gasleft
        gasUsed +=
            startGasLeft +
            extraGasMargin +
            (calldataSize * calldataCost);
            
        gasUsed -= gasleft();

        if (maxSingleGasUsage != 0 && gasUsed > maxSingleGasUsage) {
            gasUsed = maxSingleGasUsage;
        }

        uint256 refundAmount = estGasPrice * gasUsed;
        if (maxRefundeeBalance != 0 && refundeeBalance + refundAmount > maxRefundeeBalance) {
            if (refundeeBalance > maxRefundeeBalance) {
                // The refundee is already above their max balance
                // emit RefundGasCostsDenied(
                //     refundee,
                //     msg.sender,
                //     RefundDenyReason.REFUNDEE_ABOVE_MAX_BALANCE,
                //     gasUsed
                // );
                return false;
            } else {
                refundAmount = maxRefundeeBalance - refundeeBalance;
            }
        }

        if (refundAmount > ownBalance) {
            refundAmount = ownBalance;
        }

        // It's expected that refundee is an EOA
        (success, ) = refundee.call{value: refundAmount}("");

        if (success){
            emit SuccessfulRefundedGasCosts(gasUsed, estGasPrice, refundAmount);
        } else {
            emit FailedRefundedGasCosts(gasUsed, estGasPrice, refundAmount);
        }
    }
}
