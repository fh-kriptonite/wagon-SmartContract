// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

// @title: Wagon Network Token Exchanger
// @author: wagon.network
// @website: https://wagon.network
// @telegram: https://t.me/wagon_network

// ██╗    ██╗ █████╗  ██████╗  ██████╗ ███╗   ██╗
// ██║    ██║██╔══██╗██╔════╝ ██╔═══██╗████╗  ██║
// ██║ █╗ ██║███████║██║  ███╗██║   ██║██╔██╗ ██║
// ██║███╗██║██╔══██║██║   ██║██║   ██║██║╚██╗██║
// ╚███╔███╔╝██║  ██║╚██████╔╝╚██████╔╝██║ ╚████║
//  ╚══╝╚══╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract WagonExchanger is Pausable, AccessControl, ReentrancyGuard {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MOVER_ROLE = keccak256("MOVER_ROLE");
    bytes32 public constant PRICE_ROLE = keccak256("PRICE_ROLE");
    
    using Counters for Counters.Counter;
    Counters.Counter private _usdIdCounter;
    
    IERC20Metadata wagon;
    
    mapping(uint256 => IERC20Metadata) public usd;

    uint256 public presaleWagon = 0;
    uint256 public soldWagon = 0;

    // 1 WAG = 0.064 USD
    uint256 public usdPerWagon = 64;
    uint256 public usdPerWagonDecimal = 3;

    uint256 startTime;
    uint256 endTime;

    address public emergencyAccount;

    event AddUsd(address newUsd);
    event InjectWagon(uint256 amountOfWagon);
    event RemoveWagon(uint256 amountOfWagon);
    event SwapWagon(address buyer, uint256 amountOfWagon);
    event MoverERC20(address erc20, address to, uint256 amount);
    event UpdatePrice(uint256 newPrice);
    event UpdateStartTime(uint256 timestamp);
    event UpdateEndTime(uint256 timestamp);

    // when Start.
    // Modifier check if time for exchange is already started or ended.
    modifier whenStart() {
        require (startTime > 0, "Start time not yet set.");
        require (block.timestamp >= startTime, "Not yet start.");
        require (endTime == 0 || block.timestamp <= endTime, "Exchanger ended.");
        _;
    }

    // Constructor.
    // Setting all the roles needed and set wagon token and usdt address.
    // @param _wagonAddress Wagon address
    // @param _usdt USDT address
    constructor(address _wagonAddress, address _usdt) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MOVER_ROLE, msg.sender);
        _grantRole(PRICE_ROLE, msg.sender);

        wagon = IERC20Metadata(_wagonAddress);

        usd[0] = IERC20Metadata(_usdt);
        _usdIdCounter.increment();
        emergencyAccount = msg.sender;
    }

    // Add Usd.
    // Add another ERC20 stable coin based on USD.
    // @param _address ERC20 Address
    function addUsd(address _address) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 usdId = _usdIdCounter.current();
        usd[usdId] = IERC20Metadata(_address);
        _usdIdCounter.increment();
        emit AddUsd(_address);
    }

    // Inject Wagon.
    // Add Wagon to be exchange.
    // @param amount Amount of WAG token
    function injectWagon(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        wagon.transferFrom(msg.sender, address(this), amount);
        presaleWagon += amount;
        emit InjectWagon(amount);
    }

    // Remove Wagon.
    // remove Wagon from the exchange.
    // @param amount Amount of WAG token
    function removeWagon(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(availableWagon() >= amount, "Not enough WAG");
        wagon.transfer(emergencyAccount, amount);
        presaleWagon -= amount;
        emit RemoveWagon(amount);
    }

    // Available Wagon.
    // Get how many Wagon remaining to be exchange.
    // @param amount Amount of WAG token
    function availableWagon() public view returns (uint256) {
        return presaleWagon - soldWagon;
    }

    // Pause.
    // Openzeppelin pausable swapping / exchange USD to WAG.
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    // Unpause.
    // Openzeppelin unpause swapping / exchange USD to WAG.
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // Set Price.
    // Set the price of WAG token in USD.
    // @param newPrice new price of WAG Token
    function setPrice(uint256 newPrice) external onlyRole(PRICE_ROLE) {
        usdPerWagon = newPrice;
        emit UpdatePrice(newPrice);
    }

    // Set Start Time.
    // Set the start time, so users can swap USD to WAG after this timestamp.
    // @param timestamp timestamp
    function setStartTime(uint256 timestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        startTime = timestamp;
        emit UpdateStartTime(timestamp);
    }

    // Set End Time.
    // Set the end time, so users cannot swap USD to WAG after this timestamp.
    // @param timestamp timestamp
    function setEndTime(uint256 timestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        endTime = timestamp;
        emit UpdateEndTime(timestamp);
    }

    // Swap USD for WAG.
    // Function to swap USD for WAG.
    // @param usdId ERC20 id for the saved ERC20 Stable coin
    // @param usdAmount Amount of usd about to be swap
    function swapUsdForWag(uint256 usdId, uint256 usdAmount) external whenNotPaused whenStart nonReentrant {
        require(availableWagon() > 0, "No Wagon to distribute.");

        IERC20Metadata usdErc20 = usd[usdId];
        require(usdErc20.balanceOf(msg.sender) >= usdAmount, "Balance not enough.");

        transferWag(usdErc20, usdAmount);
    }

    // transfer WAG.
    // Internal function to calculate amount of WAG user 
    // get and transfer it to the user.
    // @param usdErc20 ERC20 metadata for the stable coin
    // @param usdAmount Amount of usd about to be swap
    function transferWag(IERC20Metadata usdErc20, uint256 usdAmount) internal {
        uint256 wagAmount = 0;
        uint256 unusedUsd = 0;

        (wagAmount, unusedUsd) = calculateSwapWagon(usdErc20, usdAmount);

        usdErc20.transferFrom(msg.sender, address(this), usdAmount - unusedUsd);
        wagon.transfer(msg.sender, wagAmount);
        soldWagon += wagAmount;

        emit SwapWagon(msg.sender, wagAmount);
    }

    // calculate Swap Wagon.
    // Calculate how much users get WAG token for amount of USD. 
    // If the available WAG is not enough, users will get unused USD back.
    // @param usdErc20 ERC20 metadata for the stable coin
    // @param usdAmount Amount of usd about to be swap
    function calculateSwapWagon(IERC20Metadata usdErc20, uint256 usdAmount) public view returns(uint256, uint256) {
        uint256 unusedUsd = 0;
        uint256 unusedWag = 0;

        uint256 usdPerWagonWithDecimal = usdPerWagon * (10 ** (usdErc20.decimals() - usdPerWagonDecimal));
        uint256 wagAmount = (usdAmount * 10 ** wagon.decimals() / usdPerWagonWithDecimal);
        
        uint256 wagBalance = availableWagon();

        if(wagAmount > wagBalance) {
            unusedWag = wagAmount - wagBalance;
            wagAmount = wagBalance;
            unusedUsd = (unusedWag * usdPerWagonWithDecimal) / 10 ** wagon.decimals();
        }

        return (wagAmount, unusedUsd);
    }

    // move Erc20.
    // Emergency function to transfer erc20 if there is other erc20 transfered to this address. 
    // If the available WAG is not enough, users will get unused USD back.
    // @param usdErc20 ERC20 metadata for the stable coin
    // @param usdAmount Amount of usd about to be swap
    function moveErc20(address _addressErc20, address _to, uint256 _amount) external onlyRole(MOVER_ROLE){
        IERC20 erc20 = IERC20(_addressErc20);
        erc20.transfer(_to, _amount);
        emit MoverERC20(_addressErc20, _to, _amount);
    }

}