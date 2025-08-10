// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISubzero {
    function investInAsset(bytes32 asset) external payable;
    function sellPartial(bytes32 asset, uint256 sellAmountWei) external;
    function getUserAssetInvestment(address user, bytes32 asset) external view returns (uint256);
    function getCurrentAssetPrice(bytes32 asset) external view returns (uint256);
}

contract CopyTradingVault {
    // State variables
    mapping(address => uint256) public depositedFunds;
    mapping(address => mapping(address => bool)) public isFollowing;
    mapping(address => mapping(address => uint256)) public copyPercentage; // 0-100%
    mapping(address => mapping(bytes32 => uint256)) public vaultPositions; // User's positions held by vault
    mapping(address => bool) public isAuthorizedExecutor;
    
    address public owner;
    address public subzeroContract;
    
    // Events
    event FundsDeposited(address indexed user, uint256 amount);
    event TradeCopied(address indexed follower, address indexed trader, bytes32 asset, uint256 amount);
    event TraderFollowed(address indexed follower, address indexed trader, uint256 percentage);
    event TraderUnfollowed(address indexed follower, address indexed trader);
    event FundsWithdrawn(address indexed user, uint256 amount);
    
    constructor(address _subzeroContract) {
        owner = msg.sender;
        subzeroContract = _subzeroContract;
        isAuthorizedExecutor[msg.sender] = true;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    
    modifier onlyAuthorized() {
        require(isAuthorizedExecutor[msg.sender], "Not authorized");
        _;
    }
    
    // ✅ 1. Deposit AVAX for copy trading
    function depositForCopyTrading() external payable {
        require(msg.value > 0, "Must deposit AVAX");
        depositedFunds[msg.sender] += msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }
    
    // ✅ 2. Follow a trader with percentage allocation
    function followTrader(address trader, uint256 percentage) external {
        require(percentage > 0 && percentage <= 100, "Invalid percentage");
        require(trader != msg.sender, "Cannot follow yourself");
        require(depositedFunds[msg.sender] > 0, "Must deposit first");
        
        isFollowing[msg.sender][trader] = true;
        copyPercentage[msg.sender][trader] = percentage;
        
        emit TraderFollowed(msg.sender, trader, percentage);
    }
    
    // ✅ 3. Unfollow a trader
    function unfollowTrader(address trader) external {
        isFollowing[msg.sender][trader] = false;
        copyPercentage[msg.sender][trader] = 0;
        
        emit TraderUnfollowed(msg.sender, trader);
    }
    
    // ✅ 4. Execute copy trade (called by automated system)
    function executeCopyTrade(
        address follower,
        address trader, 
        bytes32 asset,
        uint256 traderAmount
    ) external onlyAuthorized {
        require(isFollowing[follower][trader], "Not following trader");
        require(depositedFunds[follower] > 0, "No deposited funds");
        
        // Calculate copy amount based on percentage
        uint256 copyAmount = (traderAmount * copyPercentage[follower][trader]) / 100;
        
        // Ensure user has enough deposited funds
        require(depositedFunds[follower] >= copyAmount, "Insufficient vault balance");
        
        // Deduct from deposited funds
        depositedFunds[follower] -= copyAmount;
        
        // Track position in vault
        vaultPositions[follower][asset] += copyAmount;
        
        // Execute trade in main Subzero contract
        ISubzero(subzeroContract).investInAsset{value: copyAmount}(asset);
        
        emit TradeCopied(follower, trader, asset, copyAmount);
    }
    
    // ✅ 5. Execute copy sell (when leader sells)
    function executeCopySell(
        address follower,
        address trader,
        bytes32 asset,
        uint256 sellPercentage // 0-100% of position to sell
    ) external onlyAuthorized {
        require(isFollowing[follower][trader], "Not following trader");
        require(vaultPositions[follower][asset] > 0, "No position to sell");
        
        uint256 sellAmount = (vaultPositions[follower][asset] * sellPercentage) / 100;
        
        // Update vault position
        vaultPositions[follower][asset] -= sellAmount;
        
        // Execute partial sell in main contract
        ISubzero(subzeroContract).sellPartial(asset, sellAmount);
        
        // Note: Profits/losses from sale will be handled by main contract
        emit TradeCopied(follower, trader, asset, sellAmount);
    }
    
    // ✅ 6. Withdraw available funds
    function withdrawFunds(uint256 amount) external {
        require(amount <= depositedFunds[msg.sender], "Insufficient balance");
        
        depositedFunds[msg.sender] -= amount;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");
        
        emit FundsWithdrawn(msg.sender, amount);
    }
    
    // ✅ 7. Get user's copy trading info
    function getUserCopyInfo(address user) external view returns (
        uint256 depositedBalance,
        uint256 totalFollowing
    ) {
        depositedBalance = depositedFunds[user];
        // Count following traders would need a separate array, simplified for now
        totalFollowing = 0; // Implement counter if needed
    }
    
    // ✅ 8. Admin functions
    function addAuthorizedExecutor(address executor) external onlyOwner {
        isAuthorizedExecutor[executor] = true;
    }
    
    function removeAuthorizedExecutor(address executor) external onlyOwner {
        isAuthorizedExecutor[executor] = false;
    }
    
    // Emergency functions
    function emergencyWithdraw(address user) external onlyOwner {
        uint256 balance = depositedFunds[user];
        require(balance > 0, "No balance");
        
        depositedFunds[user] = 0;
        (bool success, ) = payable(user).call{value: balance}("");
        require(success, "Emergency withdrawal failed");
    }
    
    receive() external payable {
        // Allow contract to receive AVAX from sales
    }
}
