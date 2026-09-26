//SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IJobsManager, Jobs, Stake, BanCred} from "./interfaces/IJobsManager.sol";

/// @title JobsManager
/// @notice Escrows client payments and contractor commitments for freelance jobs.
/// @dev Risk tiering by nomination: a client-nominated contractor is paid from funds pulled
///      into escrow at acceptJob and can never be stiffed by client insolvency. An open-market
///      contractor takes on client-solvency risk and is compensated from the client's slashed
///      stake if the client cannot pay on completion. This contract therefore holds client
///      stakes plus escrowed job payments plus accrued protocol fees -- never anything else.
contract JobsManager is IJobsManager, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Ceiling on admin fee discretion; caps PROTOCOL_FEE_BP at 10%.
    uint16 constant MAX_FEE_BP = 1_000;
    uint16 constant BPS = 10_000;

    uint256 nextJobId;
    uint16 public protocolFeeBP;
    mapping(address asset => uint256) _protocolFees;

    /// @dev 0 means the asset is not supported. Gates both staking and job payment --
    ///      see the "why one whitelist" note on setStakeRequirement.
    mapping(address asset => uint256 required) public stakeRequirement;
    mapping(address client => Stake) _clientStakes;
    /// @dev Prevents banned address from re-registering, even with different World ID nullifier.
    mapping(address client => bool banned) _clientBanned;
    /// TODO: unused for now; will be used to prevent banned clients from re-registering with a different wallet.
    mapping(bytes32 worldIdNullifier => bool known) _nullifierUsed;

    /// @dev Cumulative un-escrowed job obligations per client per asset. Escrowing a job
    ///      (nominated acceptJob) moves its amount out of here; it cannot be derived from
    ///      _jobs without iterating every job a client has ever created.
    mapping(address client => mapping(address asset => uint256)) _clientAllowance;
    mapping(address client => uint256) _activeJobs;

    mapping(uint256 jobId => Jobs) private _jobs;
    mapping(address client => uint256[]) private _clientJobs;

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Sets the protocol fee, deducted from the contractor's payout on completion.
    function setProtocolFeeBP(uint16 feeBP) external onlyOwner {
        if (feeBP > MAX_FEE_BP) revert FeeTooHigh(feeBP, MAX_FEE_BP);
        protocolFeeBP = feeBP;
        emit ProtocolFeeBPSet(feeBP);
    }

    /// @notice Lists or de-lists an asset for both staking and job payment.
    /// @dev One whitelist serves both purposes: a client cannot price a job in a token the
    ///      protocol has not vetted, which closes the "lying token" attack where a malicious
    ///      transferFrom returns true without moving value and would otherwise report a
    ///      successful pull and never trigger a slash. `amount == 0` de-lists the asset.
    ///      Only registerAndStake and createJob consult this mapping -- acceptJob, completeJob,
    ///      closeJob, and unregisterAndUnstake read the asset from the stored Jobs/Stake struct,
    ///      so de-listing never bricks an in-flight job or an existing stake.
    function setStakeRequirement(address asset, uint256 amount) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        stakeRequirement[asset] = amount;
        emit StakeRequirementSet(asset, amount);
    }

    /// @notice Withdraws accrued protocol fees. Cannot touch client stakes or escrow.
    function withdrawProtocolFees(address asset, address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = _protocolFees[asset];
        _protocolFees[asset] = 0;
        IERC20(asset).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Client
    // ---------------------------------------------------------------------

    /// @notice Stakes the required amount of `asset` and registers the caller as a client.
    /// @param data Reserved for proof-of-humanhood verification
    function registerAndStake(address asset, bytes calldata data) external nonReentrant {
        if (_clientBanned[msg.sender]) revert ClientBanned(BanCred.EOA);
        if (_clientHasRegistered(msg.sender)) revert ClientHasRegistered();
        uint256 required = stakeRequirement[asset];
        if (required == 0) revert InvalidAsset(asset);

        // TODO: perform WorldID nullifier check here...

        _clientStakes[msg.sender] = Stake({stakedAsset: asset, stakedAmount: required});
        IERC20(asset).safeTransferFrom(msg.sender, address(this), required);
        emit ClientRegistered(msg.sender);
    }

    /// @notice Returns the caller's stake and unregisters them, provided no job is open.
    function unregisterAndUnstake() external nonReentrant {
        if (!_clientHasRegistered(msg.sender)) revert ClientNotRegistered();
        Stake memory stake = _clientStakes[msg.sender];
        uint256 open = _activeJobs[msg.sender];
        if (open != 0) revert ClientStakeLocked();

        delete _clientStakes[msg.sender];

        IERC20(stake.stakedAsset).safeTransfer(msg.sender, stake.stakedAmount);
        emit ClientUnregistered(msg.sender);
    }

    /// @notice Creates a job, checking that the caller has approved and holds enough of
    ///         `asset` to cover this job plus every other un-escrowed job they have open.
    function createJob(bytes32 jobHash, address asset, uint96 amount, uint64 duration, address resolver)
        external
        nonReentrant
        returns (uint256 jobId)
    {
        if (!_clientHasRegistered(msg.sender)) revert ClientNotRegistered();
        if (amount == 0) revert InvalidJobPaymentAmount();
        if (duration == 0) revert InvalidJobDuration();
        if (!isSupportedAsset(asset)) revert InvalidAsset(asset);
        if (resolver == address(0) || resolver == msg.sender) revert InvalidJobResolver();

        // Cumulative, not per-job: a single approval must not be able to back many jobs.
        uint256 outstanding = _clientAllowance[msg.sender][asset] + amount;
        uint256 approved = IERC20(asset).allowance(msg.sender, address(this));
        if (approved < outstanding) revert InsufficientApproval(outstanding, approved);
        uint256 held = IERC20(asset).balanceOf(msg.sender);
        if (held < outstanding) revert InsufficientBalance(outstanding, held);

        _clientAllowance[msg.sender][asset] = outstanding;
        _activeJobs[msg.sender]++;
        jobId = ++nextJobId; // 1-indexed job IDs

        // TODO: consider using a vetted resolver, either with ENS reputation system
        // or protocol-approved resolvers

        _jobs[jobId] = Jobs({
            jobHash: jobHash,
            client: msg.sender,
            startTime: 0,
            creationTime: uint48(block.timestamp),
            closed: false,
            escrowed: false,
            contractor: address(0),
            duration: duration,
            feeBP: protocolFeeBP,
            asset: asset,
            amount: amount,
            resolver: resolver
        });
        _clientJobs[msg.sender].push(jobId);

        emit JobCreated(jobId, msg.sender);
    }

    /// @notice Nominates (or clears, with address(0)) the contractor allowed to accept a job.
    /// @dev Only callable before the job is accepted (startTime == 0); a client may change
    ///      the nomination as many times as they like up to that point.
    function nominateContractor(uint256 jobId, address contractor) external {
        Jobs storage job = _jobs[jobId];
        if (!_jobExists(job)) revert JobNotFound();
        if (!_jobHasStarted(job)) {
            if (_jobHasStaled(job)) revert JobExpired();
        } else {
            revert JobHasStarted();
        }
        if (job.closed) revert JobHasBeenClosed();

        if (msg.sender != job.client) revert MismatchedJobClient();
        if (contractor == job.client || contractor == job.resolver) revert InvalidJobContractor();

        job.contractor = contractor;

        emit JobContractorNominated(jobId, contractor);
    }

    // ---------------------------------------------------------------------
    // Contractor
    // ---------------------------------------------------------------------

    /// @notice Accepts an open job. If the caller was explicitly nominated, the client's
    ///         payment is pulled into escrow immediately; otherwise nothing is transferred
    ///         and the contractor is taking on client-solvency risk.
    function acceptJob(uint256 jobId) external nonReentrant {
        Jobs storage job = _jobs[jobId];
        if (!_jobExists(job)) revert JobNotFound();
        if (!_jobHasStarted(job)) {
            if (_jobHasStaled(job)) revert JobExpired();
        } else {
            revert JobHasStarted();
        }
        if (job.closed) revert JobHasBeenClosed();

        bool nominated = job.contractor != address(0);

        if (nominated) {
            if (msg.sender != job.contractor) revert MismatchedJobContractor();
            job.escrowed = true;
            _clientAllowance[job.client][job.asset] -= job.amount;
            // `job.client` is not attacker-controlled input: it was set to msg.sender in
            // createJob and the client pre-approved this contract to pull their own funds.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            IERC20(job.asset).safeTransferFrom(job.client, address(this), job.amount);
        } else {
            if (msg.sender == job.client || msg.sender == job.resolver) revert InvalidJobContractor();
            job.contractor = msg.sender;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        job.startTime = uint48(block.timestamp);

        emit JobAccepted(jobId, msg.sender, nominated);
    }

    // ---------------------------------------------------------------------
    // Resolver
    // ---------------------------------------------------------------------

    /// @notice Closes a job: the client may close after the deadline has
    ///         passed (or if the job was never accepted), the resolver may close at any time and compensate the contractor.
    /// @param data Supplementary data from the resolver, to be quried off-chain for auditability. Not interpreted by this contract.
    function closeJob(uint256 jobId, bytes calldata data) external nonReentrant {
        Jobs storage job = _jobs[jobId];
        if (!_jobExists(job)) revert JobNotFound();
        if (job.closed) revert JobHasBeenClosed();
        bool jobCompleted;

        if ((!_jobHasStarted(job) && _jobHasStaled(job)) || _activeJobHasExpired(job)) {
            if (msg.sender != job.client && msg.sender != job.resolver) revert MismatchedJobResolver();
            if (job.escrowed) {
                IERC20(job.asset).safeTransfer(job.client, job.amount);
            } else {
                _clientAllowance[job.client][job.asset] -= job.amount;
            }

            // TODO: we need to come up with a penalty system for contractors who don't complete the job on time.
            // Current idea: consider implementing ENS reputation system on contractor's side too
            // Contractors who don't register ENS subdomain must also stake some amount of money to be able to accept jobs.
            // Contractors with an ENS record will be affected here.. without the need for staking.
        } else {
            if (msg.sender != job.resolver) revert MismatchedJobResolver();
            jobCompleted = true;
            uint256 fee = (uint256(job.amount) * job.feeBP) / BPS;
            uint256 payout = job.amount - fee;
            if (job.escrowed) {
                _protocolFees[job.asset] += fee;
                IERC20(job.asset).safeTransfer(job.contractor, payout);
            } else {
                _clientAllowance[job.client][job.asset] -= job.amount;
                if (_tryPull(job.asset, job.client, job.amount)) {
                    _protocolFees[job.asset] += fee;
                    // _tryPull's own call already happened above; nonReentrant blocks real
                    // reentrancy, and the payout amount is only known once the pull succeeds.
                    // forge-lint: disable-next-line(reentrancy-events)
                    IERC20(job.asset).safeTransfer(job.contractor, payout);
                } else {
                    _slash(job.client, job.contractor);
                }
            }
        }

        _activeJobs[job.client]--;
        job.closed = true;
        emit JobClosed(jobId, job.contractor, jobCompleted);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function clientAllowance(address client, address asset) external view returns (uint256) {
        return _clientAllowance[client][asset];
    }

    function clientJobs(address client) external view returns (uint256[] memory) {
        return _clientJobs[client];
    }

    function jobs(uint256 jobId) external view returns (Jobs memory) {
        return _jobs[jobId];
    }

    function clientStaked(address client) external view returns (bool) {
        return _clientStakes[client].stakedAmount != 0;
    }

    function clientStake(address client) external view returns (Stake memory) {
        return _clientStakes[client];
    }

    function isSupportedAsset(address asset) public view returns (bool) {
        return stakeRequirement[asset] != 0;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _clientHasRegistered(address client) internal view returns (bool) {
        return _clientStakes[client].stakedAmount != 0;
    }

    function _jobExists(Jobs storage job) internal view returns (bool) {
        return job.client != address(0);
    }

    function _jobHasStarted(Jobs storage job) internal view returns (bool) {
        return job.startTime != 0;
    }

    function _jobHasStaled(Jobs storage job) internal view returns (bool) {
        return block.timestamp > uint256(job.creationTime) + uint256(job.duration);
    }

    function _activeJobHasExpired(Jobs storage job) internal view returns (bool) {
        return block.timestamp > uint256(job.startTime) + uint256(job.duration);
    }

    /// @dev Low-level call, not a typed try/transferFrom: a token that returns no data on
    ///      success (USDT-style) would fail a typed return decode and incorrectly slash a
    ///      solvent client. Empty returndata and an explicit `true` both count as success.
    function _tryPull(address asset, address from, uint256 value) internal returns (bool) {
        (bool success, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transferFrom, (from, address(this), value)));
        return success && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// @dev Transfers the client's whole stake to the contractor and bans the client. Never
    ///      reverts on an already-empty stake: a client with several open jobs can be slashed
    ///      once, and every later job of theirs must still settle.
    function _slash(address client, address contractor) internal {
        Stake memory stake = _clientStakes[client];
        delete _clientStakes[client];
        _clientBanned[client] = true;

        if (stake.stakedAmount != 0) {
            // Reached only after completeJob's failed _tryPull, itself an external call;
            // nonReentrant on completeJob blocks real reentrancy from either call.
            // forge-lint: disable-next-line(reentrancy-events)
            emit ClientSlashed(client);
            IERC20(stake.stakedAsset).safeTransfer(contractor, stake.stakedAmount);
        }
    }
}
