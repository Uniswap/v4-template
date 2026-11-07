// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev Test copy of Spraay's SprayContract, verified source (Sourcify exact match) at
 *   BNB 0x3093a2951FB77b3beDfB8BA20De645F7413432C1 and Base 0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c.
 *   Only the import paths and contract name differ.
 * @title SprayContract
 * @notice Enables batch token transfers to multiple recipients in a single transaction
 * @dev Supports both native ETH and ERC20 tokens with a 0.3% protocol fee
 * @custom:website https://spraay.app
 * @custom:author @lostpoet
 */
contract MockSpraay is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============ Events ============

    event SprayETHExecuted(
        address indexed sender, uint256 totalAmount, uint256 recipientCount, uint256 feeAmount, uint256 timestamp
    );

    event SprayTokenExecuted(
        address indexed sender,
        address indexed token,
        uint256 totalAmount,
        uint256 recipientCount,
        uint256 feeAmount,
        uint256 timestamp
    );

    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // ============ State Variables ============

    uint256 public feeBps; // Fee in basis points (30 = 0.3%)
    address public feeRecipient; // Address that receives protocol fees

    uint256 public constant MAX_FEE_BPS = 500; // 5% max fee cap
    uint256 public constant MAX_RECIPIENTS = 200; // Safety limit per transaction

    // ============ Structs ============

    struct Recipient {
        address payable recipient;
        uint256 amount;
    }

    // ============ Constructor ============

    constructor(address _feeRecipient, uint256 _feeBps) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");

        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
    }

    // ============ Core Functions ============

    /**
     * @notice Spray native ETH to multiple recipients with variable amounts
     * @param recipients Array of Recipient structs (address + amount)
     * @dev msg.value must cover totalAmount + fee. Excess is refunded.
     */
    function sprayETH(Recipient[] calldata recipients) external payable nonReentrant whenNotPaused {
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_RECIPIENTS, "Too many recipients");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i].recipient != address(0), "Invalid recipient");
            require(recipients[i].amount > 0, "Invalid amount");
            totalAmount += recipients[i].amount;
        }

        uint256 feeAmount = (totalAmount * feeBps) / 10000;
        uint256 requiredAmount = totalAmount + feeAmount;
        require(msg.value >= requiredAmount, "Insufficient ETH");

        // Distribute to recipients
        for (uint256 i = 0; i < recipients.length; i++) {
            (bool success,) = recipients[i].recipient.call{value: recipients[i].amount}("");
            require(success, "ETH transfer failed");
        }

        // Transfer fee
        if (feeAmount > 0) {
            (bool feeSuccess,) = payable(feeRecipient).call{value: feeAmount}("");
            require(feeSuccess, "Fee transfer failed");
        }

        // Refund excess
        uint256 excess = msg.value - requiredAmount;
        if (excess > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: excess}("");
            require(refundSuccess, "Refund failed");
        }

        emit SprayETHExecuted(msg.sender, totalAmount, recipients.length, feeAmount, block.timestamp);
    }

    /**
     * @notice Spray ERC-20 tokens to multiple recipients with variable amounts
     * @param token Address of the ERC-20 token
     * @param recipients Array of Recipient structs (address + amount)
     * @dev Caller must approve this contract for totalAmount + fee beforehand
     */
    function sprayToken(address token, Recipient[] calldata recipients) external nonReentrant whenNotPaused {
        require(token != address(0), "Invalid token");
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_RECIPIENTS, "Too many recipients");

        IERC20 tokenContract = IERC20(token);

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i].recipient != address(0), "Invalid recipient");
            require(recipients[i].amount > 0, "Invalid amount");
            totalAmount += recipients[i].amount;
        }

        uint256 feeAmount = (totalAmount * feeBps) / 10000;
        uint256 requiredAmount = totalAmount + feeAmount;

        // Pull total from sender
        tokenContract.safeTransferFrom(msg.sender, address(this), requiredAmount);

        // Distribute to recipients
        for (uint256 i = 0; i < recipients.length; i++) {
            tokenContract.safeTransfer(recipients[i].recipient, recipients[i].amount);
        }

        // Transfer fee
        if (feeAmount > 0) {
            tokenContract.safeTransfer(feeRecipient, feeAmount);
        }

        emit SprayTokenExecuted(msg.sender, token, totalAmount, recipients.length, feeAmount, block.timestamp);
    }

    /**
     * @notice Gas-efficient spray when all recipients get the same amount
     * @param token Address of token (address(0) for ETH)
     * @param recipients Array of recipient addresses
     * @param amountPerRecipient Amount to send to each recipient
     */
    function sprayEqual(address token, address payable[] calldata recipients, uint256 amountPerRecipient)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_RECIPIENTS, "Too many recipients");
        require(amountPerRecipient > 0, "Invalid amount");

        uint256 totalAmount = amountPerRecipient * recipients.length;
        uint256 feeAmount = (totalAmount * feeBps) / 10000;
        uint256 requiredAmount = totalAmount + feeAmount;

        if (token == address(0)) {
            // ETH equal spray
            require(msg.value >= requiredAmount, "Insufficient ETH");

            for (uint256 i = 0; i < recipients.length; i++) {
                require(recipients[i] != address(0), "Invalid recipient");
                (bool success,) = recipients[i].call{value: amountPerRecipient}("");
                require(success, "ETH transfer failed");
            }

            if (feeAmount > 0) {
                (bool feeSuccess,) = payable(feeRecipient).call{value: feeAmount}("");
                require(feeSuccess, "Fee transfer failed");
            }

            uint256 excess = msg.value - requiredAmount;
            if (excess > 0) {
                (bool refundSuccess,) = payable(msg.sender).call{value: excess}("");
                require(refundSuccess, "Refund failed");
            }

            emit SprayETHExecuted(msg.sender, totalAmount, recipients.length, feeAmount, block.timestamp);
        } else {
            // ERC20 equal spray
            IERC20 tokenContract = IERC20(token);
            tokenContract.safeTransferFrom(msg.sender, address(this), requiredAmount);

            for (uint256 i = 0; i < recipients.length; i++) {
                require(recipients[i] != address(0), "Invalid recipient");
                tokenContract.safeTransfer(recipients[i], amountPerRecipient);
            }

            if (feeAmount > 0) {
                tokenContract.safeTransfer(feeRecipient, feeAmount);
            }

            emit SprayTokenExecuted(msg.sender, token, totalAmount, recipients.length, feeAmount, block.timestamp);
        }
    }

    // ============ Admin Functions ============

    function updateFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "Fee too high");
        uint256 oldFee = feeBps;
        feeBps = newFeeBps;
        emit FeeUpdated(oldFee, newFeeBps);
    }

    function updateFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != address(0), "Invalid address");
        address oldRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(oldRecipient, newFeeRecipient);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool success,) = payable(owner()).call{value: amount}("");
            require(success, "ETH withdrawal failed");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit EmergencyWithdraw(token, amount);
    }

    // ============ View Functions ============

    function calculateTotalCost(uint256 totalAmount) external view returns (uint256) {
        uint256 feeAmount = (totalAmount * feeBps) / 10000;
        return totalAmount + feeAmount;
    }

    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * feeBps) / 10000;
    }

    // Accept ETH
    receive() external payable {}
}
