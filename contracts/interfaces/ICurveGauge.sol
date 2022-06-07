// SPDX-License-Identifier: agpl-3.0
//pragma solidity ^0.8.0;
pragma solidity ^0.6.12;

interface ICurveGauge {
    function balanceOf(address account) external view returns (uint256);

    function deposit(uint256 _value) external;

    function withdraw(uint256 value) external;

    function claim_rewards(address _addr, address _receiver) external;

    function claimable_reward(
        address _addr, address _token) external view returns (uint256);

    function claimed_reward(
        address _addr, address _token) external view returns (uint256);
}
