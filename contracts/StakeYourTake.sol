// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title EventVoting
/// @notice Create events with a stake and end date. Users vote yes/no by paying 10% of the stake.
/// After the end date, the side with more votes splits the losing side's vote pot equally.
/// The creator can withdraw their original stake after finalization.
contract EventVoting {
  enum Result { Pending, YesWin, NoWin, Tie }

  struct VoterInfo {
    bool hasVoted;
    bool supportYes;
    bool hasClaimed;
  }

  struct EventInfo {
    address creator;
    uint256 stake;
    uint64 endTime;
    uint128 voteFee; // 10% of stake (stake / 10)
    uint128 yesCount;
    uint128 noCount;
    uint256 yesPot; // total wei paid by yes voters
    uint256 noPot;  // total wei paid by no voters
    bool finalized;
    Result result;
    bool creatorStakeWithdrawn;
    uint256 residual; // leftover from integer division during splitting
  }

  /// @dev eventId => voter => info
  mapping(uint256 => mapping(address => VoterInfo)) public voters;
  EventInfo[] public events;

  event EventCreated(uint256 indexed eventId, address indexed creator, uint256 stake, uint64 endTime, uint128 voteFee);
  event Voted(uint256 indexed eventId, address indexed voter, bool supportYes, uint128 newYesCount, uint128 newNoCount);
  event Finalized(uint256 indexed eventId, Result result, uint256 yesPot, uint256 noPot, uint256 residual);
  event Claimed(uint256 indexed eventId, address indexed voter, uint256 amount);
  event CreatorStakeWithdrawn(uint256 indexed eventId, address indexed creator, uint256 amount, uint256 residual);

  /// @notice Total number of created events
  function totalEvents() external view returns (uint256) {
    return events.length;
  }

  /// @notice Create a new event by depositing a stake. Vote fee is 10% of the stake.
  /// @param endTime Unix timestamp strictly greater than now.
  /// @return eventId Index of the newly created event.
  function createEvent(uint64 endTime) external payable returns (uint256 eventId) {
    require(endTime > block.timestamp, "endTime must be in the future");
    require(msg.value > 0, "stake must be > 0");

    uint128 fee = uint128(msg.value / 10); // 10% of stake
    require(fee > 0, "stake too small for 10% fee");

    EventInfo memory info = EventInfo({
      creator: msg.sender,
      stake: msg.value,
      endTime: endTime,
      voteFee: fee,
      yesCount: 0,
      noCount: 0,
      yesPot: 0,
      noPot: 0,
      finalized: false,
      result: Result.Pending,
      creatorStakeWithdrawn: false,
      residual: 0
    });

    events.push(info);
    eventId = events.length - 1;
    emit EventCreated(eventId, msg.sender, msg.value, endTime, fee);
  }

  /// @notice Get the vote fee (10% of stake) for an event.
  function getVoteFee(uint256 eventId) public view returns (uint128) {
    require(eventId < events.length, "invalid eventId");
    return events[eventId].voteFee;
  }

  /// @notice Vote yes/no for an event. Each address can vote once per event.
  /// @param eventId The id of the event.
  /// @param supportYes true for yes, false for no.
  function vote(uint256 eventId, bool supportYes) external payable {
    require(eventId < events.length, "invalid eventId");
    EventInfo storage info = events[eventId];
    require(block.timestamp < info.endTime, "event ended");
    require(!info.finalized, "already finalized");

    VoterInfo storage v = voters[eventId][msg.sender];
    require(!v.hasVoted, "already voted");

    uint128 fee = info.voteFee;
    require(msg.value == fee, "incorrect vote fee");

    v.hasVoted = true;
    v.supportYes = supportYes;

    if (supportYes) {
      info.yesCount += 1;
      info.yesPot += msg.value;
    } else {
      info.noCount += 1;
      info.noPot += msg.value;
    }

    emit Voted(eventId, msg.sender, supportYes, info.yesCount, info.noCount);
  }

  /// @notice Finalize an event after endTime to set the result and compute residuals.
  function finalize(uint256 eventId) public {
    require(eventId < events.length, "invalid eventId");
    EventInfo storage info = events[eventId];
    require(block.timestamp >= info.endTime, "not ended yet");
    require(!info.finalized, "already finalized");

    if (info.yesCount > info.noCount) {
      info.result = Result.YesWin;
      if (info.yesCount > 0) {
        uint256 share = info.noPot / uint256(info.yesCount);
        uint256 distributed = share * uint256(info.yesCount);
        info.residual = info.noPot - distributed;
      }
    } else if (info.noCount > info.yesCount) {
      info.result = Result.NoWin;
      if (info.noCount > 0) {
        uint256 share = info.yesPot / uint256(info.noCount);
        uint256 distributed = share * uint256(info.noCount);
        info.residual = info.yesPot - distributed;
      }
    } else {
      info.result = Result.Tie;
      // In a tie, everyone can claim back their fee; no residual expected.
      info.residual = 0;
    }

    info.finalized = true;
    emit Finalized(eventId, info.result, info.yesPot, info.noPot, info.residual);
  }

  /// @notice Claim your payout (or refund on tie) after finalization.
  function claim(uint256 eventId) external {
    require(eventId < events.length, "invalid eventId");
    EventInfo storage info = events[eventId];
    require(info.finalized, "not finalized");

    VoterInfo storage v = voters[eventId][msg.sender];
    require(v.hasVoted, "not a voter");
    require(!v.hasClaimed, "already claimed");

    uint256 amount;

    if (info.result == Result.Tie) {
      amount = uint256(info.voteFee);
    } else if (info.result == Result.YesWin) {
      if (v.supportYes) {
        // equal split of losing pot among YES voters
        amount = info.yesCount > 0 ? (info.noPot / uint256(info.yesCount)) : 0;
      } else {
        amount = 0;
      }
    } else if (info.result == Result.NoWin) {
      if (!v.supportYes) {
        // equal split of losing pot among NO voters
        amount = info.noCount > 0 ? (info.yesPot / uint256(info.noCount)) : 0;
      } else {
        amount = 0;
      }
    }

    v.hasClaimed = true;

    if (amount > 0) {
      (bool ok, ) = msg.sender.call{value: amount}("");
      require(ok, "transfer failed");
    }

    emit Claimed(eventId, msg.sender, amount);
  }

  /// @notice Withdraw the creator's original stake after finalization.
  function withdrawCreatorStake(uint256 eventId) external {
    require(eventId < events.length, "invalid eventId");
    EventInfo storage info = events[eventId];
    require(info.finalized, "not finalized");
    require(msg.sender == info.creator, "not creator");
    require(!info.creatorStakeWithdrawn, "stake withdrawn");

    info.creatorStakeWithdrawn = true;

    uint256 amount = info.stake;
    (bool ok, ) = info.creator.call{value: amount}("");
    require(ok, "stake transfer failed");
    emit CreatorStakeWithdrawn(eventId, info.creator, amount, 0);
  }

  /// @notice Withdraw any residual wei from integer division after finalization (creator only).
  function withdrawResidual(uint256 eventId) external {
    require(eventId < events.length, "invalid eventId");
    EventInfo storage info = events[eventId];
    require(info.finalized, "not finalized");
    require(msg.sender == info.creator, "not creator");

    uint256 amount = info.residual;
    require(amount > 0, "no residual");
    info.residual = 0;
    (bool ok, ) = info.creator.call{value: amount}("");
    require(ok, "residual transfer failed");
  }
}


