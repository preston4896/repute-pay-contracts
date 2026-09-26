//SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

struct Jobs {
    bytes32 jobHash;

    address client;
    // Gas efficient: 6-byte timestamp even though unconventional, should be fine.
    uint48 startTime;
    uint48 creationTime;

    address contractor;
    uint64 duration;
    uint16 feeBP;
    bool closed;
    bool escrowed;

    address asset;
    uint96 amount;

    address resolver;
}

struct Stake {
    address stakedAsset;
    uint256 stakedAmount;
}

enum BanCred {
    None,
    EOA,
    Nullifier
}

interface IJobsManager {
    // events

    event JobCreated(uint256 indexed jobId, address indexed client);
    event JobContractorNominated(uint256 indexed jobId, address indexed contractor);
    event JobAccepted(uint256 indexed jobId, address indexed contractor, bool escrowed);
    event JobClosed(uint256 indexed jobId, address indexed contractor, bool completed);

    event ClientRegistered(address indexed client);
    event ClientUnregistered(address indexed client);
    event ClientSlashed(address indexed client);

    event ProtocolFeeBPSet(uint16 feeBP);
    event StakeRequirementSet(address indexed asset, uint256 amount);

    // errors

    error ZeroAddress();
    error InvalidAsset(address asset);
    error FeeTooHigh(uint16 feeBP, uint16 maxFeeBP);

    error ClientNotRegistered();
    error ClientHasRegistered();
    error ClientStakeLocked();
    error ClientBanned(BanCred cred);

    error InvalidJobPaymentAmount();
    error InvalidJobDuration();
    error InvalidJobResolver();
    error InvalidJobContractor();

    error InsufficientApproval(uint256 required, uint256 actual);
    error InsufficientBalance(uint256 required, uint256 actual);

    error JobNotFound();
    error JobHasStarted();
    error JobHasNotStarted();
    error JobExpired();
    error JobIsStillActive();
    error JobHasBeenClosed();

    error MismatchedJobClient();
    error MismatchedJobContractor();
    error MismatchedJobResolver();

    // Read functions

    function clientAllowance(address client, address asset) external view returns (uint256 allowance);
    function clientJobs(address client) external view returns (uint256[] memory jobIds);
    function jobs(uint256 jobId) external view returns (Jobs memory job);
    function clientStaked(address client) external view returns (bool staked);

    function protocolFeeBP() external view returns (uint16);
    function stakeRequirement(address asset) external view returns (uint256 amount);
    function isSupportedAsset(address asset) external view returns (bool supported);

    // write functions

    function registerAndStake(address asset, bytes calldata data) external;
    function createJob(bytes32 jobHash, address asset, uint96 amount, uint64 duration, address resolver)
        external
        returns (uint256 jobId);
    function nominateContractor(uint256 jobId, address contractor) external;
    function acceptJob(uint256 jobId) external;
    function closeJob(uint256 jobId, bytes calldata data) external;
    function unregisterAndUnstake() external;

    // admin functions

    function setProtocolFeeBP(uint16 feeBP) external;
    function setStakeRequirement(address asset, uint256 amount) external;
    function withdrawProtocolFees(address asset, address to) external;
}
