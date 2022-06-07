// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Pausable.sol";
import "arb-bridge-peripherals/contracts/tokenbridge/arbitrum/IArbToken.sol";
import "../utils/MintPausable.sol";

/**
 * @title SPA Token Contract on Arbitrum (L2)
 * @author Sperax Foundation
 */
contract SperaxTokenL2 is ERC20Pausable, MintPausable, Ownable, IArbToken {
    event BlockTransfer(address indexed account);
    event AllowTransfer(address indexed account);
    /**
    * @dev Emitted when an account is set mintabl
    */
    event Mintable(address account);
    /**
     * @dev Emitted when an account is set unmintable
     */
    event Unmintable(address account);
    event ArbitrumGatewayL1TokenChanged(address gateway, address l1token);


    modifier onlyMintableGroup() {
        require(mintableGroup[_msgSender()], "SPA: not in mintable group");
        _;
    }


    struct TimeLock {
        uint256 releaseTime;
        uint256 amount;
    }
    mapping(address => TimeLock) private _timelock;
    // @dev mintable group
    mapping(address => bool) public mintableGroup;
    // @dev record mintable accounts
    address [] public mintableAccounts;

    // Arbitrum Bridge
    address public l2Gateway;
    address public override l1Address;

    /**
     * @dev Initialize the contract give all tokens to the deployer
     * @param _l2Gateway address of Arbitrum custom L2 Gateway
     * @param _l2Gateway address of SperaxTokenL1 on L1
     */
    constructor(string memory _name, string memory _symbol, address _l2Gateway, address _l1Address)
        ERC20(_name, _symbol) public {
        l2Gateway = _l2Gateway;
        l1Address = _l1Address;
    }

    /**
     * @dev set or remove address to mintable group
     */
    function setMintable(address account, bool allow) public onlyOwner {
        mintableGroup[account] = allow;
        mintableAccounts.push(account);

        if (allow) {
            emit Mintable(account);
        }  else {
            emit Unmintable(account);
        }
    }

    /**
     * @dev remove all mintable account
     */
    function revokeAllMintable() public onlyOwner {
        uint n = mintableAccounts.length;
        for (uint i=0;i<n;i++) {
            delete mintableGroup[mintableAccounts[i]];
        }
        delete mintableAccounts;
    }


    /**
     * @dev mint SPA when USDs is burnt
     */
    function mintForUSDs(address account, uint256 amount) whenMintNotPaused onlyMintableGroup external {
        _mint(account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 amount) public {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public {
        uint256 decreasedAllowance = allowance(account, _msgSender()).sub(amount, "SperaxToken: burn amount exceeds allowance");

        _approve(account, _msgSender(), decreasedAllowance);
        _burn(account, amount);
    }


    /**
     * @dev View `account` locked information
     */
    function timelockOf(address account) public view returns(uint256 releaseTime, uint256 amount) {
        TimeLock memory timelock = _timelock[account];
        return (timelock.releaseTime, timelock.amount);
    }

    /**
     * @dev Transfer to the "recipient" some specified 'amount' that is locked until "releaseTime"
     * @notice only Owner call
     */
    function transferWithLock(address recipient, uint256 amount, uint256 releaseTime) public onlyOwner returns (bool) {
        require(recipient != address(0), "SperaxToken: transferWithLock to zero address");
        require(releaseTime > block.timestamp, "SperaxToken: release time before lock time");
        require(_timelock[recipient].releaseTime == 0, "SperaxToken: already locked");

        TimeLock memory timelock = TimeLock({
            releaseTime : releaseTime,
            amount      : amount
        });
        _timelock[recipient] = timelock;

        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev Release the specified `amount` of locked amount
     * @notice only Owner call
     */
    function release(address account, uint256 releaseAmount) public onlyOwner {
        require(account != address(0), "SperaxToken: release zero address");

        TimeLock storage timelock = _timelock[account];
        timelock.amount = timelock.amount.sub(releaseAmount);
        if(timelock.amount == 0) {
            timelock.releaseTime = 0;
        }
    }

    /**
     * @dev Triggers stopped state.
     * @notice only Owner call
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Returns to normal state.
     * @notice only Owner call
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Triggers stopped state of mint.
     * @notice only Owner call
     */
    function mintPause() public onlyOwner {
        _mintPause();
    }

    /**
     * @dev Returns to normal state of mint.
     * @notice only Owner call
     */
    function mintUnpause() public onlyOwner {
        _mintUnpause();
    }

    /**
     * @dev Batch transfer amount to recipient
     * @notice that excessive gas consumption causes transaction revert
     */
    function batchTransfer(address[] memory recipients, uint256[] memory amounts) public {
        require(recipients.length > 0, "SperaxToken: least one recipient address");
        require(recipients.length == amounts.length, "SperaxToken: number of recipient addresses does not match the number of tokens");

        for(uint256 i = 0; i < recipients.length; ++i) {
            _transfer(_msgSender(), recipients[i], amounts[i]);
        }
    }

    /**
     * @dev See {ERC20-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - the contract must not be paused.
     * - accounts must not trigger the locked `amount` during the locked period.
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(!paused(), "SperaxToken: token transfer while paused");

        // Check whether the locked amount is triggered
        TimeLock storage timelock = _timelock[from];
        if(timelock.releaseTime != 0 && balanceOf(from).sub(amount) < timelock.amount) {
            require(block.timestamp >= timelock.releaseTime, "SperaxToken: current time is before from account release time");

            // Update the locked `amount` if the current time reaches the release time
            timelock.amount = 0;
            if(timelock.amount == 0) {
                timelock.releaseTime = 0;
            }
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    // Arbitrum Bridge

    /**
     * @notice change the arbitrum bridge address and corresponding L1 token address
     * @dev normally this function should not be called
     * @param newL2Gateway the new bridge address
     * @param newL1Address the new router address
     */
    function changeArbToken(address newL2Gateway, address newL1Address) external onlyOwner {
        l2Gateway = newL2Gateway;
        l1Address = newL1Address;
        emit ArbitrumGatewayL1TokenChanged(l2Gateway, l1Address);
    }

    modifier onlyGateway() {
        require(msg.sender == l2Gateway, "ONLY_l2GATEWAY");
        _;
    }

    function bridgeMint(address account, uint256 amount) external override onlyGateway {
        _mint(account, amount);
    }

    function bridgeBurn(address account, uint256 amount) external override onlyGateway {
        _burn(account, amount);
    }
}
