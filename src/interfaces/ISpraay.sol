// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Minimal interface for Spraay's batch distribution contract (SprayContract)
/// @dev Verified source (exact match on Sourcify):
///   - BNB Chain: 0x3093a2951FB77b3beDfB8BA20De645F7413432C1
///   - Base:      0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c
/// The protocol fee (`feeBps`, 30 bps at time of writing) is charged on top of the distributed amount:
/// the caller must provide `totalAmount + totalAmount * feeBps / 10_000`.
interface ISpraay {
    struct Recipient {
        address payable recipient;
        uint256 amount;
    }

    /// @notice Batch send native currency with per-recipient amounts. Excess msg.value is refunded to the caller.
    function sprayETH(Recipient[] calldata recipients) external payable;

    /// @notice Batch send an ERC-20 with per-recipient amounts. Pulls `totalAmount + fee` from the caller.
    function sprayToken(address token, Recipient[] calldata recipients) external;

    /// @notice Batch send the same amount to every recipient. `token == address(0)` means native currency.
    function sprayEqual(address token, address payable[] calldata recipients, uint256 amountPerRecipient)
        external
        payable;

    function calculateTotalCost(uint256 totalAmount) external view returns (uint256);

    function feeBps() external view returns (uint256);

    function MAX_RECIPIENTS() external view returns (uint256);
}
