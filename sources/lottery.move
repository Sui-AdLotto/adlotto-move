module adlotto::lottery;

use adlotto::ad_entry::{Self, AdRegistry, Advertisement};
use adlotto::treasury::{Self, Treasury};
use adlotto::verification::{Self, VerificationSession};
use std::vector;
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::random::{Self, Random};
use sui::transfer;
use sui::tx_context::TxContext;
use sui::vec_set;

// ======== Error Codes ========
const ETooEarly: u64 = 1;
const ENoActiveAds: u64 = 2;
const ENoPendingWinner: u64 = 3;
const EWrongWinnerObject: u64 = 4;
const EWinnerAlreadyPicked: u64 = 5;

// ======== Constants ========
const EPOCH_DURATION_MS: u64 = 3600000; // 1 hour (Testnet)

// ======== Structs ========

/// Singleton config that tracks the state of the lottery
public struct LotteryConfig has key {
    id: UID,
    epoch_duration: u64,
    current_epoch: u64,
    last_draw_time: u64,
    admin: address,
    // State for the 2-step process
    pending_winner_id: Option<ID>,
    latest_winner_id: Option<ID>,
}

/// Immutable record of past winners (lighter than storing the whole epoch)
public struct PastWinner has key, store {
    id: UID,
    epoch: u64,
    winner_ad_id: ID,
    timestamp: u64,
}

// ======== Events ========

public struct WinnerPicked has copy, drop {
    epoch: u64,
    winner_ad_id: ID,
    timestamp: u64,
}

public struct EpochFinalized has copy, drop {
    epoch: u64,
    winner_ad_id: ID,
    // Added fields for UI Gallery:
    blob_id: ID,
    advertiser: address,
    timestamp: u64,
    encryption_id: vector<u8>,
}
/// This is not stored on-chain, just returned by view functions.
public struct LotteryState has copy, drop {
    current_epoch: u64,
    last_draw_time: u64,
    next_draw_time: u64,
    time_remaining_ms: u64,
    status: vector<u8>, // "Running", "PickReady", "FinalizeReady"
    pending_winner: Option<ID>,
    latest_winner: Option<ID>,
    epoch_duration: u64,
}

// ======== Init ========

public entry fun create_config(admin: address, ctx: &mut TxContext) {
    transfer::share_object(LotteryConfig {
        id: object::new(ctx),
        epoch_duration: EPOCH_DURATION_MS,
        current_epoch: 0,
        last_draw_time: 0,
        admin,
        pending_winner_id: std::option::none(),
        latest_winner_id: std::option::none(),
    });
}

// ======== Main Logic ========

/// Step 1: Randomly pick a winner from AdRegistry.
public entry fun pick_winner(
    config: &mut LotteryConfig,
    registry: &AdRegistry,
    r: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Checks
    assert!(std::option::is_none(&config.pending_winner_id), EWinnerAlreadyPicked);
    let current_time = clock::timestamp_ms(clock);

    // Time Check
    // if (config.current_epoch > 0) {
    //     assert!(current_time >= config.last_draw_time + config.epoch_duration, ETooEarly);
    // };

    // 2. Get Candidates
    let active_ads = ad_entry::get_list_ads(registry);
    let total_ads = vector::length(&active_ads);
    assert!(total_ads > 0, ENoActiveAds);

    // 3. Random Selection
    let mut generator = random::new_generator(r, ctx);
    let random_index = random::generate_u64_in_range(&mut generator, 0, total_ads - 1);
    let winner_id = *vector::borrow(&active_ads, random_index);

    // 4. Store State
    config.pending_winner_id = std::option::some(winner_id);
    config.last_draw_time = current_time; // Reset timer

    event::emit(WinnerPicked {
        epoch: config.current_epoch + 1,
        winner_ad_id: winner_id,
        timestamp: current_time,
    });
}

/// Step 2: Reveal (Unseal) the winner.
public entry fun finalize_epoch(
    config: &mut LotteryConfig,
    winner_ad_obj: &mut Advertisement,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Validation
    assert!(std::option::is_some(&config.pending_winner_id), ENoPendingWinner);
    let expected_id = *std::option::borrow(&config.pending_winner_id);

    assert!(object::id(winner_ad_obj) == expected_id, EWrongWinnerObject);

    // 2. Execute Unseal Logic
    ad_entry::mark_as_winner(winner_ad_obj, clock);

    // 3. Finalize State
    config.current_epoch = config.current_epoch + 1;
    config.pending_winner_id = std::option::none();

    // IMPROVEMENT: Update latest winner for easy querying
    config.latest_winner_id = std::option::some(expected_id);

    let (
        advertiser,
        blob_id,
        stake_amount,
        staking_position_id,
        epoch_created,
        total_votes_received,
        wins_count,
        is_active,
        is_unsealed,
        encryption_id,
    ) = ad_entry::get_ad_details(winner_ad_obj);
    let now = sui::clock::timestamp_ms(clock);

    // 4. Archive Result
    let record = PastWinner {
        id: object::new(ctx),
        epoch: config.current_epoch,
        winner_ad_id: expected_id,
        timestamp: config.last_draw_time,
    };

    event::emit(EpochFinalized {
        epoch: config.current_epoch,
        winner_ad_id: object::id(winner_ad_obj),
        blob_id: blob_id,
        advertiser: advertiser,
        timestamp: now,
        encryption_id: encryption_id,
    });
    transfer::public_freeze_object(record);
}
// ======== View Functions ========

public fun get_current_epoch(config: &LotteryConfig): u64 {
    config.current_epoch
}

public fun get_pending_winner(config: &LotteryConfig): Option<ID> {
    config.pending_winner_id
}

public fun get_lottery_state(config: &LotteryConfig, clock: &Clock): LotteryState {
    let now = clock::timestamp_ms(clock);
    let next_draw = config.last_draw_time + config.epoch_duration;

    let time_remaining = if (now >= next_draw) { 0 } else { next_draw - now };

    // Determine Status String for UI logic
    let status_str = if (std::option::is_some(&config.pending_winner_id)) {
        b"FinalizeReady" // Step 2 is needed
    } else if (now >= next_draw) {
        b"PickReady" // Step 1 is needed
    } else {
        b"Running" // Timer is running
    };

    LotteryState {
        current_epoch: config.current_epoch,
        last_draw_time: config.last_draw_time,
        next_draw_time: next_draw,
        time_remaining_ms: time_remaining,
        status: status_str,
        pending_winner: config.pending_winner_id,
        latest_winner: config.latest_winner_id,
        epoch_duration: config.epoch_duration,
    }
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    create_config(sui::tx_context::sender(ctx), ctx);
}
