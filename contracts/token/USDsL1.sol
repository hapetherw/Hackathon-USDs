// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;


import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { StableMath } from "../libraries/StableMath.sol";
import "arb-bridge-peripherals/contracts/tokenbridge/ethereum/ICustomToken.sol";
import "arb-bridge-peripherals/contracts/tokenbridge/ethereum/gateway/L1CustomGateway.sol";
import "arb-bridge-peripherals/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";

/**
 * @title USDs Token Contract on L1
 * @dev a simple ERC20 token with ICustomToken interface to interact with Arbitrum gateways
 * @author Sperax Foundation
 */
contract USDsL1 is Initializable, ERC20Upgradeable, OwnableUpgradeable, ICustomToken {
    using SafeMathUpgradeable for uint256;
    using StableMath for uint256;

    // Arbitrum Bridge
    address public bridge;
    address public router;
    bool private shouldRegisterGateway;

    event ArbitrumGatewayRouterChanged(address newBridge, address newRouter);

    function initialize(
        string calldata _nameArg,
        string calldata _symbolArg,
        address _bridge,
        address _router
    ) external initializer {
        ERC20Upgradeable.__ERC20_init(_nameArg, _symbolArg);
        OwnableUpgradeable.__Ownable_init();
        _bridge = bridge;
        _router = router;
    }

    function balanceOf(address account)
        public
        view
        override(ERC20Upgradeable, ICustomToken)
        returns (uint256)
    {
        return ERC20Upgradeable.balanceOf(account);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override(ERC20Upgradeable, ICustomToken) returns (bool) {
        return ERC20Upgradeable.transferFrom(sender, recipient, amount);
    }

    /// @dev we only set shouldRegisterGateway to true when in `registerTokenOnL2`
    function isArbitrumEnabled() external view override returns (uint8) {
        require(shouldRegisterGateway, "NOT_EXPECTED_CALL");
        return uint8(0xa4b1);
    }

    /**
     * @notice change the arbitrum bridge and router address
     * @dev normally this function should not be called
     * @param newBridge the new bridge address
     * @param newRouter the new router address
     */
    function changeArbToken(address newBridge, address newRouter) external onlyOwner {
        bridge = newBridge;
        router = newRouter;
        emit ArbitrumGatewayRouterChanged(newBridge, newRouter);
    }

    function registerTokenOnL2(
        address l2CustomTokenAddress,
        uint256 maxSubmissionCostForCustomBridge,
        uint256 maxSubmissionCostForRouter,
        uint256 maxGas,
        uint256 gasPriceBid,
        uint256 valueForGateway,
        uint256 valueForRouter,
        address creditBackAddress
    ) external payable onlyOwner override {
        // we temporarily set `shouldRegisterGateway` to true for the callback in registerTokenToL2 to succeed
        bool prev = shouldRegisterGateway;
        shouldRegisterGateway = true;

        L1CustomGateway(bridge).registerTokenToL2{value:valueForGateway}(
            l2CustomTokenAddress,
            maxGas,
            gasPriceBid,
            maxSubmissionCostForCustomBridge,
            creditBackAddress
        );

        L1GatewayRouter(router).setGateway{value:valueForRouter}(
            bridge,
            maxGas,
            gasPriceBid,
            maxSubmissionCostForRouter,
            creditBackAddress
        );

        shouldRegisterGateway = prev;
    }
}
