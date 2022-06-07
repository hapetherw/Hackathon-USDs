// Current version: 9
// This contract's version: 10
// Changes: 1. temporarily modified rebase() to directly rebase out USDs token
//			   held by VaultCore. (normally it first swaps reward & interest
//			   earned in strategies to USDs, then rebases out these USDs)
// Arbitrum-one proxy address: 0xF783DD830A4650D2A8594423F123250652340E3f

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../interfaces/ISperaxToken.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IVaultCore.sol";
import "../interfaces/IUSDs.sol";
import "../interfaces/IBuyback.sol";
import "./VaultCoreTools.sol";
import "../interfaces/ICurveGauge.sol";

/**
 * @title Vault of USDs protocol
 * @dev Control Mint, Redeem, Allocate and Rebase of USDs
 * @dev Live on Arbitrum Layer 2
 * @author Sperax Foundation
 */
contract VaultCore is Initializable, OwnableUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IVaultCore {
	using SafeERC20Upgradeable for IERC20Upgradeable;
	using SafeMathUpgradeable for uint;
	using StableMath for uint;

	bytes32 public constant REBASER_ROLE = keccak256("REBASER_ROLE");

	bool public override mintRedeemAllowed;
	bool public override allocationAllowed;
	bool public override rebaseAllowed;
	bool public override swapfeeInAllowed;
	bool public override swapfeeOutAllowed;
	address public SPAaddr;
	address public USDsAddr;
	address public override oracleAddr;
	address public SPAvault;
	address public feeVault;
	address public vaultCoreToolsAddr;
	uint public override startBlockHeight;
	uint public SPAminted;
	uint public SPAburnt;
	uint32 public override chi_alpha; // not longer used by VaultCoreTools
	uint64 public override constant chi_alpha_prec = 10**12;
	uint64 public override constant chi_prec = chi_alpha_prec;
	uint public override chiInit; // not longer used by VaultCoreTools
	uint32 public override chi_beta;
	uint16 public override constant chi_beta_prec = 10**4;
	uint32 public override chi_gamma;
	uint16 public override constant chi_gamma_prec = 10**4;
	uint64 public override constant swapFee_prec = 10**12;
	uint32 public override swapFee_p;
	uint16 public override constant swapFee_p_prec = 10**4;
	uint32 public override swapFee_theta;
	uint16 public override constant swapFee_theta_prec = 10**4;
	uint32 public override swapFee_a;
	uint16 public override constant swapFee_a_prec = 10**4;
	uint32 public override swapFee_A;
	uint16 public override constant swapFee_A_prec = 10**4;
	uint8 public override constant allocatePercentage_prec = 10**2;
	address public constant crvGaugeAddress = 0xbF7E49483881C76487b0989CD7d9A8239B20CA41;
	address public constant crvToken = 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978;
	// @dev MINT_REDEEM_WHITELIST role can always mint&redeem, with 0 fee
	// MINT_REDEEM_WHITELIST  = brownie.convert.datatypes.HexString \
	//     ("0x3cca3248c4652d646912c05545cd52fc37af1ca898ad2649b7789af45433509f", "bytes32")

	event ParametersUpdated(uint _chiInit, uint32 _chi_beta, uint32 _chi_gamma, uint32 _swapFee_p, uint32 _swapFee_theta, uint32 _swapFee_a, uint32 _swapFee_A);
	event USDsMinted(address indexed wallet, uint indexed USDsAmt, address indexed collateralAddr, uint collateralAmt, uint SPAsAmt, uint feeAmt);
	event USDsRedeemed(address indexed wallet, uint indexed USDsAmt, address indexed collateralAddr, uint collateralAmt, uint SPAsAmt, uint feeAmt);
	event Rebase(uint indexed oldSupply, uint indexed newSupply);
	event CollateralAdded(address indexed collateralAddr, bool addded, address defaultStrategyAddr, bool allocationAllowed, uint8 allocatePercentage, address buyBackAddr, bool rebaseAllowed);
	event CollateralChanged(address indexed collateralAddr, bool addded, address defaultStrategyAddr, bool allocationAllowed, uint8 allocatePercentage, address buyBackAddr, bool rebaseAllowed);
	event CollateralDeleted(address indexed collateralAddr);
	event StrategyAdded(address strategyAddr, bool added);
	event StrategyRwdBuyBackUpdateded(address strategyAddr, address buybackAddr);
	event MintRedeemPermssionChanged(bool permission);
	event AllocationPermssionChanged(bool permission);
	event RebasePermssionChanged(bool permission);
	event SwapFeeInOutPermissionChanged(bool indexed swapfeeInAllowed, bool indexed swapfeeOutAllowed);
	event CollateralAllocated(address indexed collateralAddr, address indexed depositStrategyAddr, uint allocateAmount);
	event USDsAddressUpdated(address oldAddr, address newAddr);
    event OracleAddressUpdated(address oldAddr, address newAddr);
	event TotalValueLocked(
		uint totalValueLocked,
		uint totalValueInVault,
		uint totalValueInStrategies
	);
	event SPAprice(uint SPAprice);
    event USDsPrice(uint USDsPrice);
    event CollateralPrice(uint CollateralPrice);
	event RebasedUSDs(uint RebasedUSDsAmt);

	/**
	 * @dev check if USDs mint & redeem are both allowed
	 */
	modifier whenMintRedeemAllowed {
		require(hasRole(keccak256("MINT_REDEEM_WHITELIST"), msg.sender) || mintRedeemAllowed, "Mint & redeem paused");
		_;
	}
	/**
	 * @dev check if re-investment of collaterals into strategies is allowed
	 */
	modifier whenAllocationAllowed {
		require(allocationAllowed, "Allocate paused");
		_;
	}
	/**
	 * @dev check if rebase is allowed
	 */
	modifier whenRebaseAllowed {
		require(rebaseAllowed, "Rebase paused");
		_;
	}

	struct collateralStruct {
		address collateralAddr;
		bool added;
		address defaultStrategyAddr;
		bool allocationAllowed;
		uint8 allocatePercentage;
		address buyBackAddr;
		bool rebaseAllowed;
	}
	struct strategyStruct {
		address strategyAddr;
		address rewardTokenBuybackAddr;
		bool added;
	}
	mapping(address => collateralStruct) public collateralsInfo;
	mapping(address => strategyStruct) public strategiesInfo;
	collateralStruct[] allCollaterals;	// not longer in use
	strategyStruct[] allStrategies;	// not longer in use
	address[] public allCollateralAddr;	// the list of all added collaterals
	address[] public allStrategyAddr;	// the list of all strategy addresses

	/**
	 * @dev contract initializer
	 * @param _SPAaddr SperaxTokenL2 address
	 * @param _vaultCoreToolsAddr VaultCoreTools address
	 * @param _feeVault address of wallet storing swap fees
	 */
	function initialize(address _SPAaddr, address _vaultCoreToolsAddr, address _feeVault) public initializer {
		OwnableUpgradeable.__Ownable_init();
		AccessControlUpgradeable.__AccessControl_init();
		ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
		mintRedeemAllowed = true;
		swapfeeInAllowed = false;
		swapfeeOutAllowed = false;
		allocationAllowed = false;
		SPAaddr = _SPAaddr;
		vaultCoreToolsAddr = _vaultCoreToolsAddr;
		SPAvault = address(this);
		startBlockHeight = block.number;
		chi_alpha = uint32(chi_alpha_prec * 513 / 10**10);
		chiInit = uint(chi_prec * 95 / 100);
		chi_beta = uint32(chi_beta_prec) * 9;
		chi_gamma = uint32(chi_gamma_prec);
		swapFee_p = uint32(swapFee_p_prec) * 99 / 100;
		swapFee_theta = uint32(swapFee_theta_prec)* 50;
		swapFee_a = uint32(swapFee_a_prec) * 12 / 10;
		swapFee_A = uint32(swapFee_A_prec) * 20;
		feeVault = _feeVault;
		_setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
	}

	/**
	 * @dev align up allCollateralAddr and allCollaterals
	 * @dev can only be called once
	 */
	function alignUpArray() external onlyOwner {
		require (allCollateralAddr.length == 0, 'array not empty');
		for (uint y = 0; y < allCollaterals.length; y++) {
			allCollateralAddr.push(allCollaterals[y].collateralAddr);
		}
	}

	/**
	 * @dev change registered USDs address on this contract
	 * @param _USDsAddr updated USDs address
	 */
	function updateUSDsAddress(address _USDsAddr) external onlyOwner {
		emit USDsAddressUpdated(USDsAddr, _USDsAddr);
		USDsAddr = _USDsAddr;
	}

	/**
	 * @dev change registered Oracle address on this contract
	 * @param _oracleAddr updated oracle address
	 */
	function updateOracleAddress(address _oracleAddr) external onlyOwner {
		emit USDsAddressUpdated(oracleAddr, _oracleAddr);
		oracleAddr =  _oracleAddr;
	}

	/**
	 * @dev change economics parameters related to chi ratio and swap fee
	 */
	function updateParameters(uint _chiInit, uint32 _chi_beta, uint32 _chi_gamma, uint32 _swapFee_p, uint32 _swapFee_theta, uint32 _swapFee_a, uint32 _swapFee_A) external onlyOwner {
		chiInit = _chiInit;
		chi_beta = _chi_beta;
		chi_gamma = _chi_gamma;
		swapFee_p = _swapFee_p;
		swapFee_theta = _swapFee_theta;
		swapFee_a = _swapFee_a;
		swapFee_A = _swapFee_A;
		emit ParametersUpdated(chiInit, chi_beta, chi_gamma, swapFee_p, swapFee_theta, swapFee_a, swapFee_A);
	}

	/**
	 * @dev enable/disable USDs mint & redeem
	 */
	function updateMintBurnPermission(bool _mintRedeemAllowed) external onlyOwner {
		mintRedeemAllowed = _mintRedeemAllowed;
		emit MintRedeemPermssionChanged(mintRedeemAllowed);
	}

	/**
	 * @dev enable/disable collateral re-investment
	 */
	function updateAllocationPermission(bool _allocationAllowed) external onlyOwner {
		allocationAllowed = _allocationAllowed;
		emit AllocationPermssionChanged(allocationAllowed);
	}

	/**
	 * @dev enable/disable rebasing
	 */
	function updateRebasePermission(bool _rebaseAllowed) external onlyOwner {
		rebaseAllowed = _rebaseAllowed;
		emit RebasePermssionChanged(rebaseAllowed);
	}

	/**
	 * @dev enable/disable swapInFee, i.e. mint becomes free
	 */
	function updateSwapInOutFeePermission(bool _swapfeeInAllowed, bool _swapfeeOutAllowed) external onlyOwner {
		swapfeeInAllowed = _swapfeeInAllowed;
		swapfeeOutAllowed = _swapfeeOutAllowed;
		emit SwapFeeInOutPermissionChanged(swapfeeInAllowed, swapfeeOutAllowed);
	}

	/**
	 * @dev authorize an ERC20 token as one of the collaterals supported by USDs mint/redeem
	 * @param _collateralAddr ERC20 address to be authorized
	 * @param _defaultStrategyAddr strategy address of which the collateral is allocated into on allocate()
	 * @param _allocationAllowed if allocate() is allowed on this collateral
	 * @param _allocatePercentage ideally after allocate(), _allocatePercentage% of the collateral is in strategy, (100 - _allocatePercentage)% in VaultCore
	 * @param _buyBackAddr contract address providing swap function to swap interestEarned to USDsSupply
	 * @param _rebaseAllowed if rebase is allowed on this collateral
	 */
	function addCollateral(address _collateralAddr, address _defaultStrategyAddr, bool _allocationAllowed, uint8 _allocatePercentage, address _buyBackAddr, bool _rebaseAllowed) external onlyOwner {
		require(!collateralsInfo[_collateralAddr].added, "Collateral added");
		require(ERC20Upgradeable(_collateralAddr).decimals() <= 18, "Collaterals decimals need to be less than 18");
		collateralStruct storage addingCollateral = collateralsInfo[_collateralAddr];
		addingCollateral.collateralAddr = _collateralAddr;
		addingCollateral.added = true;
		addingCollateral.defaultStrategyAddr = _defaultStrategyAddr;
		addingCollateral.allocationAllowed = _allocationAllowed;
		addingCollateral.allocatePercentage = _allocatePercentage;
		addingCollateral.buyBackAddr = _buyBackAddr;
		addingCollateral.rebaseAllowed = _rebaseAllowed;
		allCollateralAddr.push(addingCollateral.collateralAddr);
		emit CollateralAdded(_collateralAddr, addingCollateral.added, _defaultStrategyAddr, _allocationAllowed, _allocatePercentage, _buyBackAddr, _rebaseAllowed);
	}

	/**
	 * @dev update setting of an authorized collateral. refer to addCollateral() for parameters description
	 */
	function updateCollateralInfo(address _collateralAddr, address _defaultStrategyAddr, bool _allocationAllowed, uint8 _allocatePercentage, address _buyBackAddr, bool _rebaseAllowed) external onlyOwner {
		require(collateralsInfo[_collateralAddr].added, "Collateral not added");
		collateralStruct storage updatedCollateral = collateralsInfo[_collateralAddr];
		updatedCollateral.collateralAddr = _collateralAddr;
		updatedCollateral.defaultStrategyAddr = _defaultStrategyAddr;
		updatedCollateral.allocationAllowed = _allocationAllowed;
		updatedCollateral.allocatePercentage = _allocatePercentage;
		updatedCollateral.buyBackAddr = _buyBackAddr;
		updatedCollateral.rebaseAllowed = _rebaseAllowed;
		emit CollateralChanged(_collateralAddr, updatedCollateral.added, _defaultStrategyAddr, _allocationAllowed, _allocatePercentage, _buyBackAddr, _rebaseAllowed);
	}

	/**
	 * @dev remove a collateral
	 * @param collaterAddr the address of the collateral to remove
	 */
	function disableCollateral(address collaterAddr) external onlyOwner {
		require(collateralsInfo[collaterAddr].added, "Collateral not added");
		uint index = 0;
		bool found = false;
		for (uint i = 0; i < allCollateralAddr.length; i++) {
			if (allCollateralAddr[i] == collaterAddr) {
				index = i;
				found = true;
				break;
			}
		}
		require(found, "Collateral not in array");
	    allCollateralAddr[index] = allCollateralAddr[allCollateralAddr.length - 1];
	    allCollateralAddr.pop();
		delete(collateralsInfo[collaterAddr]);
		emit CollateralDeleted(collaterAddr);
	}

	/**
	 * @dev authorize an strategy
	 * @param _strategyAddr strategy contract address
	 */
	function addStrategy(address _strategyAddr) external onlyOwner {
		require(!strategiesInfo[_strategyAddr].added, "Strategy added");
		strategyStruct storage addingStrategy = strategiesInfo[_strategyAddr];
		addingStrategy.strategyAddr = _strategyAddr;
		addingStrategy.added = true;
		allStrategyAddr.push(addingStrategy.strategyAddr);
		emit StrategyAdded(_strategyAddr, true);
	}

	/**
	 * @dev authorize an strategy
	 * @param _strategyAddr strategy contract address
	 */
	function updateStrategyRwdBuybackAddr(
		address _strategyAddr,
		address _buyBackAddr
	) external onlyOwner {
		require(strategiesInfo[_strategyAddr].added, "Strategy not added");
		strategyStruct storage addingStrategy = strategiesInfo[_strategyAddr];
		addingStrategy.strategyAddr = _strategyAddr;
		addingStrategy.rewardTokenBuybackAddr = _buyBackAddr;
		emit StrategyRwdBuyBackUpdateded(_strategyAddr, _buyBackAddr);
	}

	/**
	 * @dev mint USDs (burn SPA, lock collateral) by entering collateral amount
	 * @param collateralAddr the address of user's chosen collateral
	 * @param collateralAmtToLock the amount of collateral locked
	 * @param minUSDsMinted minimum amount of USDs minted
	 * @param maxSPAburnt maximum amount of SPA burnt
	 * @param deadline transaction deadline
	 */
	function mintBySpecifyingCollateralAmt(address collateralAddr, uint collateralAmtToLock, uint minUSDsMinted, uint maxSPAburnt, uint deadline)
		public
		whenMintRedeemAllowed
		nonReentrant
	{
		require(collateralsInfo[collateralAddr].added, "Collateral not added");
		require(collateralAmtToLock > 0, "Amount needs to be greater than 0");
		_mint(collateralAddr, collateralAmtToLock, minUSDsMinted, collateralAmtToLock, maxSPAburnt, deadline);
	}

	/**
	 * @dev the generic, internal mint function
	 * @param collateralAddr the address of the collateral
	 * @param valueAmt the amount of tokens (the specific meaning depends on valueType)
	 *		valueType = 0: mintBySpecifyingUSDsAmt
	 *		valueType = 1: mintBySpecifyingSPAamt
	 *		valueType = 2: mintBySpecifyingCollateralAmt
	 */
	function _mint(
		address collateralAddr,
		uint valueAmt,
		uint slippageUSDs,
		uint slippageCollat,
		uint slippageSPA,
		uint deadline
	) internal whenMintRedeemAllowed {
		// calculate all necessary related quantities based on user inputs
		// @todo Refactor the mintView to remove the valueType parameter
		(uint SPABurnAmt, uint collateralDepAmt, uint USDsAmt, uint swapFeeAmount) = VaultCoreTools(vaultCoreToolsAddr).mintView(collateralAddr, valueAmt, 2, address(this));
		// slippageUSDs is the minimum value of the minted USDs
		// slippageCollat is the maximum value of the required collateral
		// slippageSPA is the maximum value of the required spa
		require(USDsAmt >= slippageUSDs, "USDs amount < Max Slippage");
		require(SPABurnAmt <= slippageSPA, "SPA amount > Max Slippage");
		require(now <= deadline, "Deadline expired");
		// burn SPA tokens
		SPAburnt = SPAburnt.add(SPABurnAmt);
		ISperaxToken(SPAaddr).burnFrom(msg.sender, SPABurnAmt);
		// if it it not mintWithETH, stake collaterals
		IERC20Upgradeable(collateralAddr).safeTransferFrom(msg.sender, address(this), collateralDepAmt);
		// mint USDs and collect swapIn fees
		// USDs = USDsAmt + swapFeeAmt
		IUSDs(USDsAddr).mint(msg.sender, USDsAmt);
		if (hasRole(keccak256("MINT_REDEEM_WHITELIST"), msg.sender)){
			IUSDs(USDsAddr).mint(msg.sender, swapFeeAmount);
		} else {
			IUSDs(USDsAddr).mint(feeVault, swapFeeAmount);
		}

		uint priceColla = IOracle(oracleAddr).getCollateralPrice(collateralAddr);
		uint priceSPA = IOracle(oracleAddr).getSPAprice();
		uint priceUSDs = IOracle(oracleAddr).getUSDsPrice();

		emit USDsMinted(msg.sender, USDsAmt, collateralAddr, collateralDepAmt, SPABurnAmt, swapFeeAmount);
		emit TotalValueLocked(totalValueLocked(), totalValueInVault(), totalValueInStrategies());
		emit CollateralPrice(priceColla);
		emit SPAprice(priceSPA);
		emit USDsPrice(priceUSDs);
	}

	/**
	 * @dev redeem USDs to collateral and SPA by entering USDs amount
	 * @param collateralAddr the address of user's chosen collateral
	 * @param USDsAmt the amount of USDs to be redeemed
	 * @param slippageCollat minimum amount of collateral to be unlocked
	 * @param slippageSPA minimum amount of SPA to be minted
	 * @param deadline transaction deadline
	 */
	function redeem(address collateralAddr, uint USDsAmt, uint slippageCollat, uint slippageSPA, uint deadline)
		public
		whenMintRedeemAllowed
		nonReentrant
	{
		require(collateralsInfo[collateralAddr].added, "Collateral not added");
		require(USDsAmt > 0, "Amount needs to be greater than 0");
		_redeem(collateralAddr, USDsAmt, slippageCollat, slippageSPA, deadline);
	}

	/**
	 * @dev the generic, internal redeem function
	 * @param collateralAddr the address of user's chosen collateral
	 * @param USDsAmt the amount of USDs to be redeemed
	 * @param slippageCollat minimum amount of collateral to be unlocked
	 * @param slippageSPA minimum amount of SPA to be minted
	 * @param deadline transaction deadline
	 */
	function _redeem(
		address collateralAddr,
		uint USDsAmt,
		uint slippageCollat,
		uint slippageSPA,
		uint deadline
	) internal whenMintRedeemAllowed {
		(uint SPAMintAmt, uint collateralUnlockedAmt, uint USDsBurntAmt, uint swapFeeAmount) = VaultCoreTools(vaultCoreToolsAddr).redeemView(collateralAddr, USDsAmt, address(this), oracleAddr);
		// slippageCollat is the minimum value of the unlocked collateral
		// slippageSPA is the minimum value of the minted spa
		require(collateralUnlockedAmt >= slippageCollat, "Collateral amount < Max Slippage");
		require(SPAMintAmt >= slippageSPA, "SPA amount < Max Slippage");
		require(now <= deadline, "Deadline expired");
		collateralStruct memory collateral = collateralsInfo[collateralAddr];

		ISperaxToken(SPAaddr).mintForUSDs(msg.sender, SPAMintAmt);
		SPAminted = SPAminted.add(SPAMintAmt);

		if (IERC20Upgradeable(collateralAddr).balanceOf(address(this)) >= collateralUnlockedAmt) {
			IERC20Upgradeable(collateralAddr).safeTransfer(msg.sender, collateralUnlockedAmt);
		}
		else {
			revert("Not enough collateral in Vault");
		}
		IUSDs(USDsAddr).burn(msg.sender, USDsBurntAmt);
		if (!hasRole(keccak256("MINT_REDEEM_WHITELIST"), msg.sender)){
			IERC20Upgradeable(USDsAddr).safeTransferFrom(msg.sender, feeVault, swapFeeAmount);
		}

		uint priceColla = IOracle(oracleAddr).getCollateralPrice(collateralAddr);
		uint priceSPA = IOracle(oracleAddr).getSPAprice();
		uint priceUSDs = IOracle(oracleAddr).getUSDsPrice();

		emit USDsRedeemed(msg.sender, USDsBurntAmt, collateralAddr, collateralUnlockedAmt, SPAMintAmt, swapFeeAmount);
		emit TotalValueLocked(totalValueLocked(), totalValueInVault(), totalValueInStrategies());
		emit CollateralPrice(priceColla);
		emit SPAprice(priceSPA);
		emit USDsPrice(priceUSDs);
	}

	/**
	 * @dev trigger rebase: harvest interest and reward token earned in strategies. Exchange them into USDs.
	 * @dev distribute USDs earned in this step to all users by change the totalsupply of USDs
	 */
	function rebase() external whenRebaseAllowed nonReentrant {
		require(hasRole(REBASER_ROLE, msg.sender), "Caller is not a rebaser");
		uint USDsIncrement = _harvest();
		uint USDsOldSupply = IERC20Upgradeable(USDsAddr).totalSupply();
		if (USDsIncrement > 0) {
			IUSDs(USDsAddr).burnExclFromOutFlow(address(this), USDsIncrement);
			IUSDs(USDsAddr).changeSupply(USDsOldSupply);
		}
		emit RebasedUSDs(USDsIncrement);
		uint priceSPA = IOracle(oracleAddr).getSPAprice();
		uint priceUSDs = IOracle(oracleAddr).getUSDsPrice();

		emit SPAprice(priceSPA);
		emit USDsPrice(priceUSDs);
		emit TotalValueLocked(totalValueLocked(), totalValueInVault(), totalValueInStrategies());
	}

	/**
	 * @notice harvest USDs held by VaultCore
	 * @dev VaultCore does not organically hold/generate USDs, transfer USDs to 
	 *		VaultCore manually
	 */
	function _harvest() internal returns (uint USDsIncrement) {
		USDsIncrement = IERC20Upgradeable(USDsAddr).balanceOf(address(this));
	}

	/**
	 * @notice harvest reward token earned in strategies
	 * @dev rewardLiquidationThreshold is the maximum amount of CRV used to
	 * 		rebase; the rest is sent to rwdReserve.
	 */
	function _harvestReward(IStrategy strategy) internal returns (uint USDsIncrement_viaReward) {
		address rwdTokenAddr = strategy.rewardTokenAddress();
		// Skip if rewardTokenAddress not set on strategy
		if (rwdTokenAddr != address(0)) {
			// Check claimable reward (CRV)
			if (ICurveGauge(crvGaugeAddress).claimable_reward(address(strategy), crvToken) > 0) {
				strategy.collectRewardToken();
				// Check actual reward received
				uint rwdAmt = IERC20Upgradeable(rwdTokenAddr).balanceOf(address(this));
				require(rwdAmt > 0, '0 reward received');
				address buybackAddr =
					strategiesInfo[address(strategy)].rewardTokenBuybackAddr;
				uint maxRebasingRwd = strategy.rewardLiquidationThreshold(); // Maximum reward to swap for rebase
				uint rebasingRwd = rwdAmt > maxRebasingRwd ? maxRebasingRwd : rwdAmt;
				// Swap part of the reward for rebasing
				IERC20Upgradeable(rwdTokenAddr).safeTransfer(buybackAddr, rebasingRwd);
				USDsIncrement_viaReward = IBuyback(buybackAddr).swap(rwdTokenAddr, rebasingRwd);
				// Send the rest of the reward to rwdReserve
				if (rwdAmt > maxRebasingRwd) {
					address rwdReserve = 0xA61a0719e9714c95345e89a2f1C83Fae6f5745ef;
					IERC20Upgradeable(rwdTokenAddr).safeTransfer(rwdReserve, rwdAmt.sub(maxRebasingRwd));
				}
			}
		}
	}

	/**
	 * @notice harvest interest earned in strategies
	 * @dev interestLiquidationThreshold is the maximum interest allowed;
	 *		if interest earned is higher than that, txn will be reverted. Lower
	 *		rewardLiquidationThreshold and increase interestLiquidationThreshold
	 */
	function _harvestInterest(IStrategy strategy, address collateralAddr) internal returns (uint USDsIncrement_viaInterest) {
		collateralStruct memory collateral = collateralsInfo[collateralAddr];
		uint interestEarned = strategy.checkInterestEarned(collateralAddr);
		// Check if interestEarned is too high (therefore impacting APY)
		require(interestEarned <= strategy.interestLiquidationThreshold(), 'Interest too high');
		if (interestEarned > 0) {
			(address interestToken, uint256 interestAmt) = strategy.collectInterest(address(this), collateral.collateralAddr);
			IERC20Upgradeable(interestToken).safeTransfer(collateral.buyBackAddr, interestAmt);
			USDsIncrement_viaInterest = IBuyback(collateral.buyBackAddr).swap(interestToken, interestAmt);
		}
	}

	/**
	 * @dev allocate collateral on this contract into strategies.
	 */
	function allocate() external whenAllocationAllowed onlyOwner nonReentrant {
		IStrategy strategy;
		collateralStruct memory collateral;
		for (uint y = 0; y < allCollateralAddr.length; y++) {
			collateral = collateralsInfo[allCollateralAddr[y]];
			if (collateral.defaultStrategyAddr != address(0)) {
				strategy = IStrategy(collateral.defaultStrategyAddr);
				if (collateral.allocationAllowed && strategy.supportsCollateral(collateral.collateralAddr)) {
					uint amtInStrategy = strategy.checkBalance(collateral.collateralAddr);
					uint amtInVault = IERC20Upgradeable(collateral.collateralAddr).balanceOf(address(this));
					uint amtInStrategy_optimal = amtInStrategy.add(amtInVault).mul(uint(collateral.allocatePercentage)).div(uint(allocatePercentage_prec));
					if (amtInStrategy_optimal > amtInStrategy) {
						uint amtToAllocate = amtInStrategy_optimal.sub(amtInStrategy);
						IERC20Upgradeable(collateral.collateralAddr).safeTransfer(collateral.defaultStrategyAddr, amtToAllocate);
						strategy.deposit(collateral.collateralAddr, amtToAllocate);
						emit CollateralAllocated(collateral.collateralAddr, collateral.defaultStrategyAddr, amtToAllocate);
					}
				}
			}

		}
	}

	/**
	 * @dev the value of collaterals in this contract and strategies divide by USDs total supply
	 * @dev precision: same as chi_prec
	 */
	function collateralRatio() public view override returns (uint ratio) {
		uint totalValueLocked = totalValueLocked();
		uint USDsSupply = IERC20Upgradeable(USDsAddr).totalSupply();
		uint priceUSDs = uint(IOracle(oracleAddr).getUSDsPrice());
		uint precisionUSDs = IOracle(oracleAddr).getUSDsPrice_prec();
		uint USDsValue = USDsSupply.mul(priceUSDs).div(precisionUSDs);
		ratio = totalValueLocked.mul(chi_prec).div(USDsValue);
	}

	/**
	 * @dev the value of collaterals in this contract and strategies
	 */
	function totalValueLocked() public view returns (uint value) {
		value = totalValueInVault().add(totalValueInStrategies());
	}

	/**
	 * @dev the value of collaterals in this contract
	 */
	function totalValueInVault() public view returns (uint value) {
		for (uint y = 0; y < allCollateralAddr.length; y++) {
			collateralStruct memory collateral = collateralsInfo[allCollateralAddr[y]];
			value = value.add(_valueInVault(collateral.collateralAddr));
		}
	}

	/**
	 * @dev the value of collateral of _collateralAddr in this contract
	 */
	function _valueInVault(address _collateralAddr) internal view returns (uint value) {
		collateralStruct memory collateral = collateralsInfo[_collateralAddr];
		uint priceColla = IOracle(oracleAddr).getCollateralPrice(collateral.collateralAddr);
		uint precisionColla = IOracle(oracleAddr).getCollateralPrice_prec(collateral.collateralAddr);
		uint collateralAddrDecimal = uint(ERC20Upgradeable(collateral.collateralAddr).decimals());
		uint collateralTotalValueInVault = IERC20Upgradeable(collateral.collateralAddr).balanceOf(address(this)).mul(priceColla).div(precisionColla);
		uint collateralTotalValueInVault_18 = collateralTotalValueInVault.mul(10**(uint(18).sub(collateralAddrDecimal)));
		value = collateralTotalValueInVault_18;
	}

	/**
	 * @dev the value of collaterals in the strategies
	 */
	function totalValueInStrategies() public view returns (uint value) {
		for (uint y = 0; y < allCollateralAddr.length; y++) {
			collateralStruct memory collateral = collateralsInfo[allCollateralAddr[y]];
			value = value.add(_valueInStrategy(collateral.collateralAddr));
		}
	}

	/**
	 * @dev the value of collateral of _collateralAddr in its strategy
	 */
	function _valueInStrategy(address _collateralAddr) internal view returns (uint) {
		collateralStruct memory collateral = collateralsInfo[_collateralAddr];
		if (collateral.defaultStrategyAddr == address(0)) {
			return 0;
		}
		IStrategy strategy = IStrategy(collateral.defaultStrategyAddr);
		if (!strategy.supportsCollateral(collateral.collateralAddr)) {
			return 0;
		}
		uint priceColla = IOracle(oracleAddr).getCollateralPrice(collateral.collateralAddr);
		uint precisionColla = IOracle(oracleAddr).getCollateralPrice_prec(collateral.collateralAddr);
		uint collateralAddrDecimal = uint(ERC20Upgradeable(collateral.collateralAddr).decimals());
		uint collateralTotalValueInStrategy = strategy.checkBalance(collateral.collateralAddr).mul(priceColla).div(precisionColla);
		uint collateralTotalValueInStrategy_18 = collateralTotalValueInStrategy.mul(10**(uint(18).sub(collateralAddrDecimal)));
		return collateralTotalValueInStrategy_18;
	}
}
