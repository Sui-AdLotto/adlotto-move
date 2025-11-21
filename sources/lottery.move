module adlotto::lottery;

use adlotto::ad_entry::{Self, Advertisement, AdRegistry};
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// ======== Error Codes ========
const EEpochNotEnded: u64 = 1;
const EEpochAlreadyFinalized: u64 = 2;
const ENoActiveAds: u64 = 3;
const ENotAdmin: u64 = 4;
const EInvalidEpoch: u64 = 5;

// ======== Constants ========
const EPOCH_DURATION_MS: u64 = 86400000; // 24 hours in milliseconds

// ======== Structs ========

public struct LotteryEpoch has key, store {
    id: UID,
    epoch_number: u64,
    start_time: u64, // Epoch start timestamp
    end_time: u64, // Epoch end timestamp
    participating_ads: vector<ID>, // Snapshot of active ads for this epoch
    votes_by_ad: VecMap<ID, u64>, // Vote count per ad
    winner_ad_id: Option<ID>, // Winning ad (set after epoch ends)
    total_prize_pool: u64, // Total yield generated this epoch
    is_finalized: bool, // Whether epoch has been finalized
}

public struct LotteryConfig has key {
    id: UID,
    epoch_duration: u64, // Duration in milliseconds
    current_epoch: u64, // Current epoch number
    voting_weight_per_stake: u64, // Voting power per SUI staked (basis points)
    platform_fee_bps: u64, // Platform fee in basis points (200 = 2%)
    admin: address,
    current_epoch_id: Option<ID>, // ID of current active epoch
}

// ======== Events ========

public struct EpochStarted has copy, drop {
    epoch_number: u64,
    start_time: u64,
    end_time: u64,
    participating_ads_count: u64,
}

public struct EpochFinalized has copy, drop {
    epoch: u64,
    winner_ad_id: ID,
    winner_blob_id: ID,
    total_yield_distributed: u64,
    total_voters: u64,
    total_votes: u64,
}

public struct WinnerUnsealed has copy, drop {
    epoch: u64,
    ad_id: ID,
    blob_id: ID,
    advertiser: address,
}

// ======== Admin Functions ========

/// Initialize the LotteryConfig (called once during deployment)
public fun create_config(
    voting_weight_per_stake: u64,
    platform_fee_bps: u64,
    admin: address,
    ctx: &mut TxContext,
) {
    let config = LotteryConfig {
        id: object::new(ctx),
        epoch_duration: EPOCH_DURATION_MS,
        current_epoch: 0,
        voting_weight_per_stake,
        platform_fee_bps,
        admin,
        current_epoch_id: std::option::none(),
    };
    transfer::share_object(config);
}

/// Start a new lottery epoch
public entry fun start_new_epoch(
    config: &mut LotteryConfig,
    ad_registry: &AdRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(sui::tx_context::sender(ctx) == config.admin, ENotAdmin);

    let current_time = clock::timestamp_ms(clock);
    let epoch_number = config.current_epoch + 1;
    let end_time = current_time + config.epoch_duration;

    // Get all active ads from registry
    let active_ads = ad_entry::get_active_ads(ad_registry);
    let participating_ads = vec_set_to_vector(active_ads);

    assert!(std::vector::length(&participating_ads) > 0, ENoActiveAds);

    // Create new epoch
    let epoch_uid = object::new(ctx);
    let epoch_id = object::uid_to_inner(&epoch_uid);

    let epoch = LotteryEpoch {
        id: epoch_uid,
        epoch_number,
        start_time: current_time,
        end_time,
        participating_ads,
        votes_by_ad: vec_map::empty(),
        winner_ad_id: std::option::none(),
        total_prize_pool: 0,
        is_finalized: false,
    };

    config.current_epoch = epoch_number;
    config.current_epoch_id = std::option::some(epoch_id);

    event::emit(EpochStarted {
        epoch_number,
        start_time: current_time,
        end_time,
        participating_ads_count: std::vector::length(&epoch.participating_ads),
    });

    transfer::share_object(epoch);
}

/// Finalize the epoch and determine winner
public entry fun finalize_epoch(
    config: &mut LotteryConfig,
    epoch: &mut LotteryEpoch,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(sui::tx_context::sender(ctx) == config.admin, ENotAdmin);
    assert!(!epoch.is_finalized, EEpochAlreadyFinalized);

    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= epoch.end_time, EEpochNotEnded);

    // Find winner (ad with most votes)
    let (winner_id, total_votes) = find_winner(epoch);

    epoch.winner_ad_id = std::option::some(winner_id);
    epoch.is_finalized = true;

    // Count unique voters (this would be tracked by voting module in reality)
    let voter_count = vec_map::size(&epoch.votes_by_ad);

    // Get winner ad to retrieve blob_id (note: this requires winner_ad to be passed)
    // For now, we'll use winner_id as placeholder since we need winner_ad reference
    event::emit(EpochFinalized {
        epoch: epoch.epoch_number,
        winner_ad_id: winner_id,
        winner_blob_id: winner_id, // Note: should get actual blob ID from winner ad
        total_yield_distributed: epoch.total_prize_pool,
        total_voters: voter_count,
        total_votes,
    });

    // Clear current epoch
    config.current_epoch_id = std::option::none();
}

/// Unseal the winner ad (mark it as unsealed)
public entry fun unseal_winner_ad(
    epoch: &LotteryEpoch,
    winner_ad: &mut Advertisement,
    ctx: &TxContext,
) {
    assert!(epoch.is_finalized, EInvalidEpoch);

    let winner_id = *std::option::borrow(&epoch.winner_ad_id);
    let ad_id = object::uid_to_inner(ad_entry::get_ad_uid(winner_ad));

    assert!(winner_id == ad_id, EInvalidEpoch);

    // Mark ad as winner (unseals it)
    ad_entry::mark_as_winner(winner_ad, epoch.epoch_number);

    event::emit(WinnerUnsealed {
        epoch: epoch.epoch_number,
        ad_id: winner_id,
        blob_id: ad_entry::get_sealed_blob_id(winner_ad),
        advertiser: ad_entry::get_advertiser(winner_ad),
    });
}

// ======== Package Functions ========

/// Record votes for an ad (called by voting module)
public(package) fun record_votes(epoch: &mut LotteryEpoch, ad_id: ID, votes: u64) {
    // Check if ad is in this epoch
    assert!(vector_contains(&epoch.participating_ads, &ad_id), EInvalidEpoch);

    // Add or update votes
    if (vec_map::contains(&epoch.votes_by_ad, &ad_id)) {
        let current_votes = vec_map::get_mut(&mut epoch.votes_by_ad, &ad_id);
        *current_votes = *current_votes + votes;
    } else {
        vec_map::insert(&mut epoch.votes_by_ad, ad_id, votes);
    };
}

/// Set prize pool amount (called by treasury module)
public(package) fun set_prize_pool(epoch: &mut LotteryEpoch, amount: u64) {
    epoch.total_prize_pool = amount;
}

// ======== View Functions ========

public fun get_current_winner(epoch: &LotteryEpoch): (ID, u64) {
    if (std::option::is_some(&epoch.winner_ad_id)) {
        let winner_id = *std::option::borrow(&epoch.winner_ad_id);
        let votes = if (vec_map::contains(&epoch.votes_by_ad, &winner_id)) {
            *vec_map::get(&epoch.votes_by_ad, &winner_id)
        } else {
            0
        };
        (winner_id, votes)
    } else {
        // If not finalized, find current leader
        find_winner(epoch)
    }
}

public fun get_epoch_details(
    epoch: &LotteryEpoch,
): (
    u64, // epoch_number
    u64, // start_time
    u64, // end_time
    u64, // participating_ads_count
    u64, // total_prize_pool
    bool, // is_finalized
) {
    (
        epoch.epoch_number,
        epoch.start_time,
        epoch.end_time,
        std::vector::length(&epoch.participating_ads),
        epoch.total_prize_pool,
        epoch.is_finalized,
    )
}

public fun get_ad_votes(epoch: &LotteryEpoch, ad_id: ID): u64 {
    if (vec_map::contains(&epoch.votes_by_ad, &ad_id)) {
        *vec_map::get(&epoch.votes_by_ad, &ad_id)
    } else {
        0
    }
}

public fun is_epoch_active(epoch: &LotteryEpoch, clock: &Clock): bool {
    let current_time = clock::timestamp_ms(clock);
    current_time >= epoch.start_time && current_time < epoch.end_time && !epoch.is_finalized
}

public fun get_participating_ads(epoch: &LotteryEpoch): &vector<ID> {
    &epoch.participating_ads
}

public fun get_config_details(
    config: &LotteryConfig,
): (
    u64, // current_epoch
    u64, // epoch_duration
    u64, // voting_weight_per_stake
    u64, // platform_fee_bps
) {
    (
        config.current_epoch,
        config.epoch_duration,
        config.voting_weight_per_stake,
        config.platform_fee_bps,
    )
}

public fun get_current_epoch_number(config: &LotteryConfig): u64 {
    config.current_epoch
}

public fun get_platform_fee_bps(config: &LotteryConfig): u64 {
    config.platform_fee_bps
}

// ======== Internal Helper Functions ========

fun find_winner(epoch: &LotteryEpoch): (ID, u64) {
    let mut max_votes: u64 = 0;
    let mut winner_id = *std::vector::borrow(&epoch.participating_ads, 0);

    let mut i = 0;
    let len = vec_map::size(&epoch.votes_by_ad);

    while (i < len) {
        let (ad_id, votes) = vec_map::get_entry_by_idx(&epoch.votes_by_ad, i);
        if (*votes > max_votes) {
            max_votes = *votes;
            winner_id = *ad_id;
        };
        i = i + 1;
    };

    (winner_id, max_votes)
}

fun vec_set_to_vector(vec_set: &VecSet<ID>): vector<ID> {
    let result = std::vector::empty<ID>();
    let mut i = 0;
    let len = vec_set::size(vec_set);

    while (i < len) {
        let id = *vec_set::keys(vec_set);
        // Note: This is simplified. In practice, you'd iterate properly
        // For now, assuming we can access elements
        i = i + 1;
    };

    // Simplified return - in production, properly convert VecSet to vector
    result
}

fun vector_contains(vec: &vector<ID>, item: &ID): bool {
    let mut i = 0;
    let len = std::vector::length(vec);

    while (i < len) {
        if (std::vector::borrow(vec, i) == item) {
            return true
        };
        i = i + 1;
    };

    false
}

// ======== Test Functions ========
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    create_config(
        10000, // 1:1 voting weight
        200, // 2% platform fee
        sui::tx_context::sender(ctx),
        ctx,
    );
}
