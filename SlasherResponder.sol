// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SlasherResponder {
    address public owner;
    event SlashingRisk(address indexed operator, uint256 oldStake, uint256 newStake, string reason);

    constructor() { owner = msg.sender; }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    function respondWithSlashingAlert(address operator, uint256 oldStake, uint256 newStake, string calldata reason) external onlyOwner {
        emit SlashingRisk(operator, oldStake, newStake, reason);
    }

    // optional: owner can transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
