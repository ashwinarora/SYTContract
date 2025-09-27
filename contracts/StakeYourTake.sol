// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DebateVoting
/// @notice Create debates with an end date. The creator must cast the first vote at creation
/// and sets a fixed vote price. All voters (including the creator) pay this price per vote.
/// After the end date, the side with more votes splits the losing side's vote pot equally.

contract StakeYourTake {
  using SafeERC20 for IERC20;

  /// @notice ERC20 token used for all payments in this contract
  IERC20 public immutable token;

  /// @param tokenAddress ERC20 token address used for paying vote fees and rewards
  constructor(address tokenAddress) {
    require(tokenAddress != address(0), "token is zero");
    token = IERC20(tokenAddress);
  }
  enum Result { Pending, YesWin, NoWin, Tie }

  struct VoterInfo {
    bool hasVoted;
    bool supportYes;
    bool hasClaimed;
  }

  struct DebateInfo {
    address creator;
    uint64 endTime;
    uint128 voteFee; // fixed price per vote in token units decided by creator at creation
    uint128 yesCount;
    uint128 noCount;
    uint256 yesPot; // total tokens paid by yes voters
    uint256 noPot;  // total tokens paid by no voters
    bool finalized;
    Result result;
    uint256 residual; // leftover tokens from integer division during splitting
  }

  /// @dev debateId => voter => info
  mapping(uint256 => mapping(address => VoterInfo)) public voters;
  DebateInfo[] public debates;

  event DebateCreated(uint256 indexed debateId, address indexed creator, uint64 endTime, uint128 voteFee, bool supportYes);
  event Voted(uint256 indexed debateId, address indexed voter, bool supportYes, uint128 newYesCount, uint128 newNoCount);
  event Finalized(uint256 indexed debateId, Result result, uint256 yesPot, uint256 noPot, uint256 residual);
  event Claimed(uint256 indexed debateId, address indexed voter, uint256 amount);

  /// @notice Total number of created debates
  function totalDebates() external view returns (uint256) {
    return debates.length;
  }

  /// @notice Create a new debate. Creator must cast the first vote and set a fixed vote price.
  /// @param endTime Unix timestamp strictly greater than now.
  /// @param supportYes true if creator's first vote supports YES, false for NO.
  /// @param voteFee Fixed price per vote in token units (must be transferred at creation).
  /// @return debateId Index of the newly created debate.
  function createDebate(uint64 endTime, bool supportYes, uint128 voteFee) external returns (uint256 debateId) {
    require(endTime > block.timestamp, "endTime must be in the future");
    require(voteFee > 0, "vote price must be > 0");

    // Pull creator's first vote fee in tokens
    token.safeTransferFrom(msg.sender, address(this), uint256(voteFee));

    DebateInfo memory info = DebateInfo({
      creator: msg.sender,
      endTime: endTime,
      voteFee: voteFee,
      yesCount: supportYes ? 1 : 0,
      noCount: supportYes ? 0 : 1,
      yesPot: supportYes ? uint256(voteFee) : 0,
      noPot: supportYes ? 0 : uint256(voteFee),
      finalized: false,
      result: Result.Pending,
      residual: 0
    });

    debates.push(info);
    debateId = debates.length - 1;

    // Mark creator as having voted
    VoterInfo storage v = voters[debateId][msg.sender];
    v.hasVoted = true;
    v.supportYes = supportYes;

    emit DebateCreated(debateId, msg.sender, endTime, voteFee, supportYes);
    emit Voted(debateId, msg.sender, supportYes, debates[debateId].yesCount, debates[debateId].noCount);
  }

  /// @notice Get the vote price for a debate.
  function getVoteFee(uint256 debateId) public view returns (uint128) {
    require(debateId < debates.length, "invalid debateId");
    return debates[debateId].voteFee;
  }

  /// @notice Vote yes/no for a debate. Each address can vote once per debate.
  /// @param debateId The id of the debate.
  /// @param supportYes true for yes, false for no.
  function vote(uint256 debateId, bool supportYes) external {
    require(debateId < debates.length, "invalid debateId");
    DebateInfo storage info = debates[debateId];
    require(block.timestamp < info.endTime, "debate ended");
    require(!info.finalized, "already finalized");

    VoterInfo storage v = voters[debateId][msg.sender];
    require(!v.hasVoted, "already voted");

    uint128 fee = info.voteFee;
    // Pull voter's fee in tokens
    token.safeTransferFrom(msg.sender, address(this), uint256(fee));

    v.hasVoted = true;
    v.supportYes = supportYes;

    if (supportYes) {
      info.yesCount += 1;
      info.yesPot += uint256(fee);
    } else {
      info.noCount += 1;
      info.noPot += uint256(fee);
    }

    emit Voted(debateId, msg.sender, supportYes, info.yesCount, info.noCount);
  }

  /// @notice Finalize a debate after endTime to set the result and compute residuals.
  function finalize(uint256 debateId) public {
    require(debateId < debates.length, "invalid debateId");
    DebateInfo storage info = debates[debateId];
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
    emit Finalized(debateId, info.result, info.yesPot, info.noPot, info.residual);
  }

  /// @notice Claim your payout (or refund on tie) after finalization.
  function claim(uint256 debateId) external {
    require(debateId < debates.length, "invalid debateId");
    DebateInfo storage info = debates[debateId];
    require(info.finalized, "not finalized");

    VoterInfo storage v = voters[debateId][msg.sender];
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
      token.safeTransfer(msg.sender, amount);
    }

    emit Claimed(debateId, msg.sender, amount);
  }

  /// @notice Withdraw the creator's original stake after finalization.
  // removed: original stake mechanism no longer exists

  /// @notice Withdraw any residual tokens from integer division after finalization (creator only).
  function withdrawResidual(uint256 debateId) external {
    require(debateId < debates.length, "invalid debateId");
    DebateInfo storage info = debates[debateId];
    require(info.finalized, "not finalized");
    require(msg.sender == info.creator, "not creator");

    uint256 amount = info.residual;
    require(amount > 0, "no residual");
    info.residual = 0;
    token.safeTransfer(info.creator, amount);
  }
}


