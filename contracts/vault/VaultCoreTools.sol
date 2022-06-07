// Current deployed version: 5
// This contract's version: 6
// Changes: 1. implemented new chi and swap fee model
//	 		2. cleaned up swap fee calculation in mintView and redeemView
//			3. mintView now only support mintBySpecifyingCollateralAmt
// Arbitrum-one proxy address: 0x0390C6c7c320e41fCe0e6F0b982D20A88660F473

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../utils/BancorFormula.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IVaultCore.sol";
import "../libraries/StableMath.sol";
import "../utils/BancorFormula.sol";


/**
 * @title supporting VaultCore of USDs protocol
 * @dev calculation of chi, swap fees associated with USDs's mint and redeem
 * @dev view functions of USDs's mint and redeem
 * @author Sperax Foundation
 */
contract VaultCoreTools is Initializable {
	using SafeERC20Upgradeable for ERC20Upgradeable;
	using SafeMathUpgradeable for uint;
	using StableMath for uint;

	BancorFormula public BancorInstance;

	function initialize(address _BancorFormulaAddr) public initializer {
		BancorInstance = BancorFormula(_BancorFormulaAddr);
	}

	/**
	 * @dev chiTarget delays 1% per year, starting from 100%
	 * @return chiTarget
	 */
	function _chiTarget(address _VaultCoreContract) internal view returns (uint) {
		IVaultCore _vaultContract = IVaultCore(_VaultCoreContract);
		//@todo: modify startTime to mint/redeem unpause time
		uint startTime = 1653350400;
		uint secPassed = block.timestamp.sub(startTime);
		// 317 * (1 year) = 1% * chi_prec
		// where chi_prec is 10^12
		uint chiAdjustment = secPassed.mul(317);
		uint chiInit = uint(_vaultContract.chi_prec()); //100%
		//@note: here it reverts after chiTarget has decayed to 0
		return chiInit.sub(chiAdjustment);
	}

	function multAndDiv(uint original, uint price, uint precision) public pure returns (uint) {
		return original.mul(price).div(precision);
	}

	/**
	 * @dev calculate chiMint
	 * @return chiMint, i.e. chiTarget, since they share the same value
	 */
	function chiMint(address _VaultCoreContract) public view returns (uint)	{
		return _chiTarget(_VaultCoreContract);
	}


	/**
	 * @dev calculate chiRedeem based on the formula at the end of section 2.2
	 * @return chiRedeem, i.e. chiTarget, since they share the same value
	 */
	function chiRedeem(address _VaultCoreContract) public view returns (uint) {
		return _chiTarget(_VaultCoreContract);
	}


	/**
	 * @dev calculate the OutSwap fee, i.e. fees for redeeming USDs
	 * @dev hardcoded to 0.5%
	 * @return the OutSwap fee
	 */
	function calculateSwapFeeOut(address _VaultCoreContract) public view returns (uint) {
		// if the OutSwap fee is diabled, return 0
		IVaultCore _vaultContract = IVaultCore(_VaultCoreContract);
		if (!_vaultContract.swapfeeOutAllowed()) {
			return 0;
		}
		return uint(_vaultContract.swapFee_prec()).div(200); //0.5%
	}

	function redeemView(
		address _collaAddr,
		uint USDsAmt,
		address _VaultCoreContract,
		address _oracleAddr
	) public view returns (uint SPAMintAmt, uint collaUnlockAmt, uint USDsBurntAmt, uint swapFeeAmount) {
		IVaultCore _vaultContract = IVaultCore(_VaultCoreContract);
		uint swapFeePercent = calculateSwapFeeOut(_VaultCoreContract);

		//Burn USDs
		swapFeeAmount = multAndDiv(USDsAmt, swapFeePercent, uint(_vaultContract.swapFee_prec()));
		USDsBurntAmt = USDsAmt.sub(swapFeeAmount);
		// SPAMintAmt = USDsBurntAmt * (100 - chiRedeem)/ 100
		SPAMintAmt = multAndDiv(USDsBurntAmt, (uint(_vaultContract.chi_prec()) - chiRedeem(_VaultCoreContract)), uint(_vaultContract.chi_prec()));
		//SPAMintAmt = SPAMintAmt * SPAPrice_prec / SPAPrice
		SPAMintAmt = multAndDiv(SPAMintAmt, IOracle(_oracleAddr).getSPAprice_prec(), IOracle(_oracleAddr).getSPAprice());

		// Unlock collateral
		// collaUnlockAmt = USDsBurntAmt * chiRedeem / 100
		collaUnlockAmt = multAndDiv(USDsBurntAmt, chiRedeem(_VaultCoreContract), uint(_vaultContract.chi_prec()));
		// collaUnlockAmt = collaUnlockAmt * collaPrice_prec / collaPrice
		collaUnlockAmt = multAndDiv(collaUnlockAmt, IOracle(_oracleAddr).getCollateralPrice_prec(_collaAddr), IOracle(_oracleAddr).getCollateralPrice(_collaAddr));
		// collaUnlockAmt = collaUnlockAmt / 10^(18 - 6)
		collaUnlockAmt = collaUnlockAmt.div(10**(uint(18).sub(uint(ERC20Upgradeable(_collaAddr).decimals()))));
	}

	/**
	 * @dev calculate the InSwap fee, i.e. fees for minting USDs
	 * @return the InSwap fee
	 */
	function calculateSwapFeeIn(address _VaultCoreContract) public view returns (uint) {
		// if InSwap fee is disabled, return 0
		IVaultCore _vaultContract = IVaultCore(_VaultCoreContract);
		if (!_vaultContract.swapfeeInAllowed()) {
			return 0;
		}
		return uint(_vaultContract.swapFee_prec()).div(1000); //0.1%
	}

	/**
	 * @dev the general mintView function that display all related quantities
	 * @param collaAddr the address of user's chosen collateral
	 * @param valueAmt the amount of user input whose specific meaning depends on valueType
	 * @param valueType the type of user input whose interpretation is listed above in @dev
	 * @return SPABurnAmt the amount of SPA to burn
	 *			collaAmt the amount of collateral to stake
	 *			USDsAmt the amount of USDs to mint
	 *			swapFeeAmount the amount of Inswapfee to pay
	 */
	function mintView(
		address collaAddr,
		uint valueAmt,
		uint8 valueType, // @todo remove the valueType parameter. Requires frontend change
		address _VaultCoreContract
		// @todo Remove collaAmt. Requires frontend change.
	) public view returns (uint SPABurnAmt, uint collaAmt, uint USDsAmt, uint swapFeeAmount) {
		// obtain the price and pecision of the collateral
		IVaultCore _vaultContract = IVaultCore(_VaultCoreContract);

		// obtain other necessary data
		uint swapFeePercent = calculateSwapFeeIn(_VaultCoreContract);
		// calculate collaAmt
		collaAmt = valueAmt; // @todo remove the collaAmt parameter, after updating params
		// calculate USDsAmt
		USDsAmt = USDsAmountCalculator(valueAmt, _VaultCoreContract, collaAddr);
		// calculate SPABurnAmt
		SPABurnAmt = SPAAmountCalculator(USDsAmt, _VaultCoreContract);
		// calculate swapFeeAmount
		swapFeeAmount = USDsAmt.mul(swapFeePercent).div(uint(_vaultContract.swapFee_prec()));

		USDsAmt = USDsAmt.sub(swapFeeAmount);
	}

	function SPAAmountCalculator(
		uint USDsAmt, address _VaultCoreContract
	) public view returns (uint256 SPABurnAmt) {
		IVaultCore _vaultContract = IVaultCore(_VaultCoreContract);
		uint priceSPA = IOracle(_vaultContract.oracleAddr()).getSPAprice();
		uint precisionSPA = IOracle(_vaultContract.oracleAddr()).getSPAprice_prec();
		// SPABurnAmt = USDsAmt * (chi_prec-chiMint) * precisionSPA / (priceSPA * chi_prec)
		SPABurnAmt = USDsAmt
			.mul(uint(_vaultContract.chi_prec()) - chiMint(_VaultCoreContract))
			.mul(precisionSPA)
			.div(
				priceSPA
				.mul(uint(_vaultContract.chi_prec()))
			);
	}

	function USDsAmountCalculator(
		uint collaAmt, address _VaultCoreContract, address collaAddr
	) public view returns (uint256 USDsAmt) {
		IVaultCore _vaultContract = IVaultCore(_VaultCoreContract);
		// USDsAmt = collaAmt * 10**(18-6) * (chi_prec * colla_price) / colla_price_prec / chi_Mint;
		USDsAmt = collaAmt
			.mul(10**(uint(18).sub(uint(ERC20Upgradeable(collaAddr).decimals()))))
			.mul(
				uint(_vaultContract.chi_prec())
				.mul(IOracle(_vaultContract.oracleAddr()).getCollateralPrice(collaAddr))
			)
			.div(IOracle(_vaultContract.oracleAddr()).getCollateralPrice_prec(collaAddr))
			.div(chiMint(_VaultCoreContract));
	}
}
