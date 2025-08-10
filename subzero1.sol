// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Subzero {
    struct Position {
        bytes32 assetSymbol;     
        uint256 amountInvestedWei; 
        uint256 entryPriceUSD;   
        uint256 entryTimestamp;
        bool isActive;
    }
    
    mapping(address => Position[]) public userPositions;
    mapping(bytes32 => AggregatorV3Interface) public priceFeeds;

    bytes32[] public supportedAssets;
    mapping(bytes32 => bool) public isAssetSupported;
    
    event PositionOpened(address user, bytes32 asset, uint256 amount, uint256 price);
    event PositionClosed(address user, bytes32 asset, uint256 exitPrice, int256 pnl);
    event ProfitWithdrawn(address user, uint256 amount);
    event PriceFeedSet(bytes32 asset, address priceFeed);
    
    address public owner;
    uint256 public tradingFeePercent = 100; // 1% fee (100 basis points)
    bool public emergencyMode = false;
    
    constructor() {
        owner = msg.sender;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }
    
    modifier notInEmergency() {
        require(!emergencyMode, "Contract is in emergency mode");
        _;
    }

    modifier validAmount(uint256 amount) {
        require(amount >= 0.01 ether, "Minimum 0.01 AVAX");
        require(amount <= 10 ether, "Maximum 10 AVAX");
        _;
    }

    modifier priceIsValid(uint256 price) {
          require(price > 0 && price < 1e15, "Invalid price range");
        _;
    }

    // ✅ NEW SIMPLIFIED HOLDINGS SUMMARY FUNCTIONS

    /**
     * @notice Get assets that user has active positions in
     */
    function getUserAssets(address user) external view returns (bytes32[] memory) {
        bytes32[] memory tempAssets = new bytes32[](supportedAssets.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            bytes32 asset = supportedAssets[i];
            
            for (uint256 j = 0; j < userPositions[user].length; j++) {
                if (userPositions[user][j].assetSymbol == asset && userPositions[user][j].isActive) {
                    tempAssets[count] = asset;
                    count++;
                    break;
                }
            }
        }
        
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tempAssets[i];
        }
        return result;
    }

    /**
     * @notice Get total invested amount for a specific asset
     */
function getUserAssetInvestment(address user, bytes32 asset) external view returns (uint256) {
    uint256 total = 0;
    
    for (uint256 i = 0; i < userPositions[user].length; i++) {
        if (userPositions[user][i].assetSymbol == asset && userPositions[user][i].isActive) {
            total += userPositions[user][i].amountInvestedWei;
        }
    }
    
    return total; // ✅ Return in wei, convert on frontend
}


    /**
     * @notice Get total P&L for a specific asset
     */
    function getUserAssetPnL(address user, bytes32 asset) external view returns (int256) {
        int256 totalPnL = 0;
        
        for (uint256 i = 0; i < userPositions[user].length; i++) {
            if (userPositions[user][i].assetSymbol == asset && userPositions[user][i].isActive) {
                (int256 pnl, ) = calculatePositionPnL(user, i);
                totalPnL += pnl;
            }
        }
        
        return totalPnL / 1e18; // Return in AVAX decimal format
    }

    /**
     * @notice Get position count for a specific asset
     */
    function getUserAssetPositionCount(address user, bytes32 asset) external view returns (uint256) {
        uint256 count = 0;
        
        for (uint256 i = 0; i < userPositions[user].length; i++) {
            if (userPositions[user][i].assetSymbol == asset && userPositions[user][i].isActive) {
                count++;
            }
        }
        
        return count;
    }

    /**
     * @notice Get total portfolio value (simple version)
     */
    function getUserTotalValue(address user) external view returns (
        uint256 totalInvested,
        int256 totalPnL
    ) {
        totalInvested = 0;
        totalPnL = 0;
        
        for (uint256 i = 0; i < userPositions[user].length; i++) {
            if (userPositions[user][i].isActive) {
                totalInvested += userPositions[user][i].amountInvestedWei;
                (int256 pnl, ) = calculatePositionPnL(user, i);
                totalPnL += pnl;
            }
        }
        
        totalInvested = totalInvested / 1e18;
        totalPnL = totalPnL / 1e18;
    }

    // ✅ PARTIAL SELLING FUNCTIONS

    /**
     * @notice Sell a partial amount from positions of a specific asset (External interface)
     */

    /**
     * @notice Internal implementation of partial selling with recursion support
     */
    /**
 * @notice Sell a partial amount from positions of a specific asset
 */
/**
 * @notice Sell a partial amount from positions of a specific asset
 * @param asset The asset symbol to sell from
 * @param sellAmountWei Amount in wei (use parseEther on frontend)
 */
function sellPartial(bytes32 asset, uint256 sellAmountWei) external notInEmergency {
    require(isAssetSupported[asset], "Asset not supported");
    require(sellAmountWei > 0, "Sell amount must be greater than 0");
    require(sellAmountWei >= 1e15, "Minimum sell amount is 0.001 AVAX");

    uint256 remaining = sellAmountWei;
    uint256 currentPrice = getCurrentAssetPrice(asset); // ✅ Get current price
    int256 totalPnL = 0; // ✅ Track total PnL for event
    
    // Process positions until sell amount is fulfilled
    for (uint256 i = 0; i < userPositions[msg.sender].length && remaining > 0; i++) {
        Position storage pos = userPositions[msg.sender][i];
        
        if (pos.assetSymbol != asset || !pos.isActive) {
            continue;
        }
        
        uint256 posAmount = pos.amountInvestedWei;
        uint256 toSell = posAmount > remaining ? remaining : posAmount;
        
        // Calculate P&L for this sell amount
        (int256 positionPnL, ) = calculatePositionPnL(msg.sender, i);
        int256 proportionalPnL = positionPnL * int256(toSell) / int256(posAmount);
        totalPnL += proportionalPnL; // ✅ Add to total PnL
        
        // Calculate payout
        uint256 payout = toSell;
        if (proportionalPnL >= 0) {
            uint256 profit = uint256(proportionalPnL);
            uint256 fee = profit * tradingFeePercent / 10000;
            payout = toSell + profit - fee;
        } else {
            uint256 loss = uint256(-proportionalPnL);
            payout = loss >= toSell ? 0 : toSell - loss;
        }
        
        require(address(this).balance >= payout, "Insufficient contract balance");
        
        // Update position
        pos.amountInvestedWei -= toSell;
        if (pos.amountInvestedWei == 0) {
            pos.isActive = false;
        }
        
        // Send payout
        if (payout > 0) {
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            require(success, "Transfer failed");
            emit ProfitWithdrawn(msg.sender, payout);
        }
        
        remaining = remaining > toSell ? remaining - toSell : 0;
    }
    
    require(remaining == 0, "Could not fulfill complete sell order");
    
    // ✅ EMIT THE POSITION CLOSED EVENT - This is what was missing!
    emit PositionClosed(msg.sender, asset, currentPrice, totalPnL);
}




    // EXISTING FUNCTIONS (unchanged)

    function getSupportedAssets() external view returns (bytes32[] memory) {
        return supportedAssets;
    }

    function closePositionInternal(uint256 positionIndex) internal {
        require(positionIndex < userPositions[msg.sender].length, "Position does not exist");
        
        Position storage position = userPositions[msg.sender][positionIndex];
        require(position.isActive, "Position already closed");
        
        (int256 pnlWei, uint256 currentPrice) = calculatePositionPnL(msg.sender, positionIndex);
        
        position.isActive = false;
        
        uint256 totalPayout;
        uint256 fee = 0;
        
        if (pnlWei >= 0) {
            uint256 profitAmount = uint256(pnlWei);
            fee = (profitAmount * tradingFeePercent) / 10000;
            totalPayout = position.amountInvestedWei + profitAmount - fee;
        } else {
            uint256 lossAmount = uint256(-pnlWei);
            if (lossAmount >= position.amountInvestedWei) {
                totalPayout = 0;
            } else {
                totalPayout = position.amountInvestedWei - lossAmount;
            }
        }
        
        require(address(this).balance >= totalPayout, "Contract has insufficient funds");
        
        if (totalPayout > 0) {
            (bool success, ) = payable(msg.sender).call{value: totalPayout}("");
            require(success, "Transfer failed");
            emit ProfitWithdrawn(msg.sender, totalPayout);
        }
        
        // emit PositionClosed(msg.sender, position.assetSymbol, currentPrice, pnlWei);
    }

    function closePositionByAsset(bytes32 asset) external notInEmergency {
        int256 bestPnL = type(int256).min;
        uint256 bestIndex = type(uint256).max;
        bool foundPosition = false;
        
        for (uint256 i = 0; i < userPositions[msg.sender].length; i++) {
            Position memory pos = userPositions[msg.sender][i];
            if (pos.assetSymbol == asset && pos.isActive) {
                (int256 pnl, ) = calculatePositionPnL(msg.sender, i);
                if (pnl > bestPnL) {
                    bestPnL = pnl;
                    bestIndex = i;
                    foundPosition = true;
                }
            }
        }
        
        require(foundPosition, "No active position found for asset");
        closePositionInternal(bestIndex);
    }

    function getSupportedAssetsWithPrices() external view returns (
        bytes32[] memory assets,
        uint256[] memory prices,
        address[] memory priceFeedAddresses
    ) {
        assets = supportedAssets;
        prices = new uint256[](supportedAssets.length);
        priceFeedAddresses = new address[](supportedAssets.length);
        
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            bytes32 asset = supportedAssets[i];
            prices[i] = getCurrentAssetPrice(asset);
            priceFeedAddresses[i] = address(priceFeeds[asset]);
        }
    }

    function removePriceFeed(bytes32 asset) external onlyOwner {
        require(isAssetSupported[asset], "Asset not supported");
        
        delete priceFeeds[asset];
        isAssetSupported[asset] = false;
        
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (supportedAssets[i] == asset) {
                supportedAssets[i] = supportedAssets[supportedAssets.length - 1];
                supportedAssets.pop();
                break;
            }
        }
        
        emit PriceFeedSet(asset, address(0));
    }

    function isAssetSupportedByContract(bytes32 asset) external view returns (bool) {
        return isAssetSupported[asset];
    }

    function getSupportedAssetCount() external view returns (uint256) {
        return supportedAssets.length;
    }
        
    function investInAsset(bytes32 asset) external payable notInEmergency validAmount(msg.value) {
        require(msg.value > 0, "Investment amount must be > 0");
        require(address(priceFeeds[asset]) != address(0), "Asset not supported");
        
        uint256 currentPrice = getCurrentAssetPrice(asset);
        
        userPositions[msg.sender].push(Position({
            assetSymbol: asset,
            amountInvestedWei: msg.value,
            entryPriceUSD: currentPrice,
            entryTimestamp: block.timestamp,
            isActive: true
        }));
        
        emit PositionOpened(msg.sender, asset, msg.value, currentPrice);
    }
    
    function setTradingFee(uint256 feePercent) external onlyOwner {
        require(feePercent <= 1000, "Fee cannot exceed 10%");
        tradingFeePercent = feePercent;
    }
    
    function calculatePositionPnL(address user, uint256 positionIndex) 
        public view returns (int256 pnlWei, uint256 currentPrice) {
        require(positionIndex < userPositions[user].length, "Position does not exist");
        
        Position memory position = userPositions[user][positionIndex];
        require(position.isActive, "Position is closed");
        
        currentPrice = getCurrentAssetPrice(position.assetSymbol);
        
        int256 priceChangePercent = ((int256(currentPrice) - int256(position.entryPriceUSD)) * 1e18) / int256(position.entryPriceUSD);
        pnlWei = (int256(position.amountInvestedWei) * priceChangePercent) / 1e18;
        
        return (pnlWei, currentPrice);
    }
    
    function closePosition(uint256 positionIndex) external notInEmergency {
        require(positionIndex < userPositions[msg.sender].length, "Position does not exist");
        
        Position storage position = userPositions[msg.sender][positionIndex];
        require(position.isActive, "Position already closed");
        
        (int256 pnlWei, uint256 currentPrice) = calculatePositionPnL(msg.sender, positionIndex);
        
        position.isActive = false;
        
        uint256 totalPayout;
        uint256 fee = 0;
        
        if (pnlWei >= 0) {
            uint256 profitAmount = uint256(pnlWei);
            fee = (profitAmount * tradingFeePercent) / 10000;
            totalPayout = position.amountInvestedWei + profitAmount - fee;
        } else {
            uint256 lossAmount = uint256(-pnlWei);
            if (lossAmount >= position.amountInvestedWei) {
                totalPayout = 0;
            } else {
                totalPayout = position.amountInvestedWei - lossAmount;
            }
        }
        
        require(address(this).balance >= totalPayout, "Contract has insufficient funds");
        
        if (totalPayout > 0) {
            (bool success, ) = payable(msg.sender).call{value: totalPayout}("");
            require(success, "Transfer failed");
            emit ProfitWithdrawn(msg.sender, totalPayout);
        }
        
        emit PositionClosed(msg.sender, position.assetSymbol, currentPrice, pnlWei);
    }
    
    function withdrawProfitOnly(uint256 positionIndex) external notInEmergency {
        require(positionIndex < userPositions[msg.sender].length, "Position does not exist");
        
        Position storage position = userPositions[msg.sender][positionIndex];
        require(position.isActive, "Position is closed");
        
        (int256 pnlWei, ) = calculatePositionPnL(msg.sender, positionIndex);
        require(pnlWei > 0, "No profit to withdraw");
        
        uint256 profitAmount = uint256(pnlWei);
        uint256 fee = (profitAmount * tradingFeePercent) / 10000;
        uint256 netProfit = profitAmount - fee;
        
        require(address(this).balance >= netProfit, "Contract has insufficient funds");
        
        uint256 currentPrice = getCurrentAssetPrice(position.assetSymbol);
        position.entryPriceUSD = currentPrice;
        
        (bool success, ) = payable(msg.sender).call{value: netProfit}("");
        require(success, "Transfer failed");
        
        emit ProfitWithdrawn(msg.sender, netProfit);
    }
    
    function getUserPositionsWithPnL(address user) 
        external view returns (
            Position[] memory positions, 
            int256[] memory pnlValues,
            uint256[] memory currentPrices
        ) {
        positions = userPositions[user];
        pnlValues = new int256[](positions.length);
        currentPrices = new uint256[](positions.length);
        
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive) {
                (pnlValues[i], currentPrices[i]) = calculatePositionPnL(user, i);
            }
        }
    }
    
    function getCurrentAssetPrice(bytes32 asset) public view priceIsValid(getCurrentAssetPriceInternal(asset)) returns (uint256) {
        return getCurrentAssetPriceInternal(asset);
    }
    
    function getCurrentAssetPriceInternal(bytes32 asset) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[asset];
        require(address(priceFeed) != address(0), "Price feed not set for asset");
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }
    
    function getUserPositions(address user) external view returns (Position[] memory) {
        return userPositions[user];
    }
    
    function setPriceFeed(bytes32 asset, address priceFeedAddress) external onlyOwner {
        require(priceFeedAddress != address(0), "Invalid price feed address");
        
        AggregatorV3Interface testFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 testPrice,,,) = testFeed.latestRoundData();
        require(testPrice > 0 && uint256(testPrice) < 1e15, "Price feed returns invalid price");

        if (!isAssetSupported[asset]) {
        supportedAssets.push(asset);
        isAssetSupported[asset] = true;
        }
        
        priceFeeds[asset] = testFeed;
        emit PriceFeedSet(asset, priceFeedAddress);
    }
    
    function enableEmergencyMode() external onlyOwner {
        emergencyMode = true;
    }
    
    function disableEmergencyMode() external onlyOwner {
        emergencyMode = false;
    }
    
    function withdrawExcessFunds(uint256 amount) external onlyOwner validAmount(amount) {
        require(amount <= address(this).balance, "Amount exceeds balance");
        (bool success, ) = payable(owner).call{value: amount}("");
        require(success, "Withdrawal failed");
    }
    
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    receive() external payable {}
}
