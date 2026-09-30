// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Errors.sol";

/// @notice Home NAV oracle (spec §3.3, ADR-004 A1). Receives PRUV NavReporter messages via the
/// mailbox, enforces staleness + sanity + monotonic srcTimestamp + origin, and is seeded once at
/// deploy so nav() is never stale/zero at first use. A single nav() (ADR-014 dropped dual-NAV).
contract NavOracleConsumer is Ownable2Step, ReentrancyGuard, IMessageRecipient {
    IMailbox public immutable mailbox;
    uint32 public immutable reporterDomain;
    uint256 public immutable stalenessWindow;
    uint256 public immutable maxNavMoveBps;

    uint64 public constant SKEW_TOLERANCE = 1 hours; // reject source stamps beyond home now + tolerance

    bytes32 public reporter; // enrolled PRUV reporter (owner-set)
    uint256 private _nav;
    uint64 private _lastUpdated; // accepted PRUV-side source timestamp (monotonic guard only)
    uint64 private _receivedAt; // home-clock time the last accepted NAV was observed (M-4 staleness basis)
    bool private _seeded;

    event NavUpdated(uint256 value, uint64 srcTimestamp);
    event ReporterEnrolled(bytes32 reporter);

    constructor(IMailbox mailbox_, uint32 reporterDomain_, uint256 stalenessWindow_, uint256 maxNavMoveBps_)
        Ownable(msg.sender)
    {
        mailbox = mailbox_;
        reporterDomain = reporterDomain_;
        stalenessWindow = stalenessWindow_;
        maxNavMoveBps = maxNavMoveBps_;
    }

    /// @notice ADR-011 / spec section 12: renounce would permanently brick enrollReporter and halt NAV.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function enrollReporter(bytes32 reporter_) external onlyOwner {
        reporter = reporter_;
        emit ReporterEnrolled(reporter_);
    }

    /// @notice One-shot deploy seed (spec §3.3): set the first NAV so nav() is live before the
    /// launchpad closes and the first epoch runs. lastUpdated is the home clock here (initial value).
    function seedNav(uint256 value) external onlyOwner {
        if (_seeded) revert AlreadySeeded();
        if (value == 0) revert ZeroAmount();
        _seeded = true;
        _nav = value;
        _lastUpdated = uint64(block.timestamp);
        _receivedAt = uint64(block.timestamp);
        emit NavUpdated(value, uint64(block.timestamp));
    }

    function nav() external view returns (uint256) {
        // Staleness is keyed on the home-clock receive time only (M-4) — a PRUV source
        // timestamp ahead of the home clock must never disable this check (fail closed).
        if (block.timestamp - _receivedAt > stalenessWindow) revert StalePrice();
        return _nav;
    }

    function lastUpdated() external view returns (uint64) {
        return _lastUpdated;
    }

    /// @notice Inbound NAV from the enrolled PRUV reporter (spec §3.3/§9, ADR-004 A1).
    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable nonReentrant {
        if (msg.sender != address(mailbox) || origin != reporterDomain || sender != reporter) {
            revert UnauthorizedSender();
        }
        (uint256 value, uint64 srcTimestamp) = abi.decode(body, (uint256, uint64));
        _apply(value, srcTimestamp);
    }

    /// @dev monotonic (accept only strictly-newer srcTimestamp; drop replays/out-of-order, no revert),
    /// then sanity-bound vs the last accepted value.
    function _apply(uint256 value, uint64 srcTimestamp) internal {
        if (srcTimestamp <= _lastUpdated) return; // Hyperlane unordered — never regress
        if (srcTimestamp > block.timestamp + SKEW_TOLERANCE) revert StalePrice(); // reject far-future
        if (value == 0) revert ZeroAmount();
        uint256 prev = _nav;
        uint256 diff = value > prev ? value - prev : prev - value;
        if (diff * 10_000 > prev * maxNavMoveBps) revert NavSanityBound();
        _nav = value;
        _lastUpdated = srcTimestamp;
        _receivedAt = uint64(block.timestamp);
        emit NavUpdated(value, srcTimestamp);
    }
}
