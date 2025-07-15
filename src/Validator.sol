// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IValidator} from "./interfaces/IValidator.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";

/// @title Validator
/// @notice Validates message hashes against the L2ToL2CrossDomainMessenger
/// @dev Checks if messages were successfully relayed on the destination chain
contract Validator is IValidator {
    /// @notice The L2ToL2CrossDomainMessenger contract
    IL2ToL2CrossDomainMessenger public constant MESSENGER =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice Validates that all provided message hashes were successfully relayed
    /// @param validationData Encoded array of message hashes (bytes32[])
    /// @return canResolve True if all messages were successfully relayed, false otherwise
    function canResolve(bytes calldata validationData) external view override returns (bool) {
        // Decode the validation data as an array of message hashes
        bytes32[] memory messageHashes = abi.decode(validationData, (bytes32[]));

        // Check if all message hashes were successful
        for (uint256 i = 0; i < messageHashes.length; i++) {
            if (!MESSENGER.successfulMessages(messageHashes[i])) {
                return false;
            }
        }

        return true;
    }
}
