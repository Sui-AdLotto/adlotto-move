module adlotto::voting;

use adlotto::ad_entry::{Self, Advertisement};
use adlotto::lottery::{Self, LotteryEpoch};
use adlotto::ad_staking::{Self as staking, StakingPosition};
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;
use sui::vec_set::{Self, VecSet};

// ======== Error Codes ========
const ENotStakeholder: u64 = 1;
const EAlreadyVoted: u64 = 2;
const EInvalidAd: u64 = 3;
const EEpochNotActive: u64 = 4;
const EVoteNotFound: u64 = 5;
const ERewardAlreadyClaimed: u64 = 6;

// ======== Structs ========

public struct Vote has key, store {
    id: UID,
    voter: address,
    ad_id: ID,
    staking_position_id: ID, // Must have active stake to vote
    voting_power: u64, // Based on stake amount
    epoch: u64, // Epoch of vote
    reward_claimed: bool, // Whether voting reward was claimed
}

public struct VotingRecord has key {
    id: UID,
    epoch: u64,
    total_votes: u64, // Total votes in this epoch
    voters: VecSet<address>, // Unique voters
    reward_per_vote: u64, // Reward amount per vote
}

// ======== Events ========

public struct VoteCast has copy, drop {
    vote_id: ID,
    voter: address,
    ad_id: ID,
    voting_power: u64,
    epoch: u64,
}

public struct VotingRewardClaimed has copy, drop {
    vote_id: ID,
    voter: address,
    reward_amount: u64,
    epoch: u64,
}

public struct VotingRewardsDistributed has copy, drop {
    epoch: u64,
    total_rewards: u64,
    reward_per_vote: u64,
    total_voters: u64,
}

// ======== Admin Functions ========

/// Create a new voting record for an epoch
public fun create_voting_record(epoch: u64, reward_per_vote: u64, ctx: &mut TxContext) {
    let record = VotingRecord {
        id: object::new(ctx),
        epoch,
        total_votes: 0,
        voters: vec_set::empty(),
        reward_per_vote,
    };
    transfer::share_object(record);
}

// ======== User Functions ========

/// Cast a vote for an advertisement
public entry fun cast_vote(
    ad: &mut Advertisement,
    staking_position: &StakingPosition,
    epoch: &mut LotteryEpoch,
    voting_record: &mut VotingRecord,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let voter = sui::tx_context::sender(ctx);

    // Verify ownership of staking position
    assert!(staking::get_position_owner(staking_position) == voter, ENotStakeholder);

    // Verify epoch is active
    assert!(lottery::is_epoch_active(epoch, clock), EEpochNotActive);

    // Check if already voted in this epoch
    assert!(!vec_set::contains(&voting_record.voters, &voter), EAlreadyVoted);

    // Verify ad is active
    assert!(ad_entry::is_active(ad), EInvalidAd);

    // Calculate voting power based on stake
    let voting_power = staking::get_voting_power(staking_position);

    let vote_uid = object::new(ctx);
    let vote_id = object::uid_to_inner(&vote_uid);
    let ad_id = object::uid_to_inner(ad_entry::get_ad_uid(ad));
    let position_id = staking::get_position_id(staking_position);

    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    // Create vote NFT
    let vote = Vote {
        id: vote_uid,
        voter,
        ad_id,
        staking_position_id: position_id,
        voting_power,
        epoch: current_epoch,
        reward_claimed: false,
    };

    // Record vote in ad
    ad_entry::record_vote(ad, voting_power);

    // Record vote in lottery epoch
    lottery::record_votes(epoch, ad_id, voting_power);

    // Update voting record
    voting_record.total_votes = voting_record.total_votes + voting_power;
    vec_set::insert(&mut voting_record.voters, voter);

    event::emit(VoteCast {
        vote_id,
        voter,
        ad_id,
        voting_power,
        epoch: current_epoch,
    });

    // Transfer vote NFT to voter
    transfer::transfer(vote, voter);
}

/// Claim voting reward
public entry fun claim_voting_reward(
    vote: &mut Vote,
    voting_record: &VotingRecord,
    staking_position: &mut StakingPosition,
    ctx: &TxContext,
) {
    let sender = sui::tx_context::sender(ctx);
    assert!(vote.voter == sender, ENotStakeholder);
    assert!(!vote.reward_claimed, ERewardAlreadyClaimed);
    assert!(vote.epoch == voting_record.epoch, EVoteNotFound);

    // Calculate reward
    let reward_amount = vote.voting_power * voting_record.reward_per_vote / 10000;

    // Mark as claimed
    vote.reward_claimed = true;

    // Add reward to staking position
    staking::add_voting_rewards(staking_position, reward_amount);

    event::emit(VotingRewardClaimed {
        vote_id: object::uid_to_inner(&vote.id),
        voter: sender,
        reward_amount,
        epoch: vote.epoch,
    });
}

// ======== Admin/System Functions ========

/// Distribute voting rewards at epoch end (called by admin/system)
public entry fun distribute_voting_rewards(
    voting_record: &mut VotingRecord,
    total_reward_pool: u64,
    ctx: &TxContext,
) {
    // Calculate reward per vote
    if (voting_record.total_votes > 0) {
        voting_record.reward_per_vote = (total_reward_pool * 10000) / voting_record.total_votes;
    };

    event::emit(VotingRewardsDistributed {
        epoch: voting_record.epoch,
        total_rewards: total_reward_pool,
        reward_per_vote: voting_record.reward_per_vote,
        total_voters: vec_set::size(&voting_record.voters),
    });
}

// ======== View Functions ========

public fun get_vote_details(
    vote: &Vote,
): (
    address, // voter
    ID, // ad_id
    ID, // staking_position_id
    u64, // voting_power
    u64, // epoch
    bool, // reward_claimed
) {
    (
        vote.voter,
        vote.ad_id,
        vote.staking_position_id,
        vote.voting_power,
        vote.epoch,
        vote.reward_claimed,
    )
}

public fun get_voting_record_stats(
    record: &VotingRecord,
): (
    u64, // epoch
    u64, // total_votes
    u64, // total_voters
    u64, // reward_per_vote
) {
    (record.epoch, record.total_votes, vec_set::size(&record.voters), record.reward_per_vote)
}

public fun has_voted(record: &VotingRecord, voter: address): bool {
    vec_set::contains(&record.voters, &voter)
}

public fun get_pending_reward(vote: &Vote, voting_record: &VotingRecord): u64 {
    if (vote.reward_claimed || vote.epoch != voting_record.epoch) {
        0
    } else {
        vote.voting_power * voting_record.reward_per_vote / 10000
    }
}

// ======== Test Functions ========
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    create_voting_record(1, 100, ctx); // Epoch 1, 100 reward per vote
}
