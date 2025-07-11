// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Identifier} from "./IIdentifier.sol";

/// @title IMessageRelayer
interface IMessageRelayer {
    /// @notice Relays a message that was sent by the other CrossDomainMessenger contract. Can only
    ///         be executed via cross-chain call from the other messenger OR if the message was
    ///         already received once and is currently being replayed.
    /// @param _id          Identifier of the SentMessage event to be relayed
    /// @param _sentMessage Message payload of the `SentMessage` event
    /// @return returnData_ Return data from the target contract call.
    function relayMessage(Identifier calldata _id, bytes calldata _sentMessage)
        external
        payable
        returns (bytes memory returnData_);
}
