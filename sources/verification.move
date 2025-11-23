module adlotto::verification;

use adlotto::ad_entry::{Self, Advertisement};
use adlotto::lottery::{Self, LotteryConfig};
use adlotto::treasury::{Self, Treasury};
use std::option::{Self, Option};
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::random::{Self, Random};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ======== Constants ========
const WINNERS_COUNT: u64 = 50;
const REWARD_AMOUNT: u64 = 5_000_000_000; // 5 MOCK_SUI

// ======== Errors ========
const EAdNotActive: u64 = 1;
const EAlreadyVerified: u64 = 2;
const ENoNewWinner: u64 = 3;
const ESessionAlreadyRotated: u64 = 4;

// ======== Structs ========

public struct VerificationSession has key {
    id: UID,
    active_ad_id: ID, // The Ad currently being watched
    epoch_counter: u64, // Internal counter to separate viewer lists
    total_viewers: u64, // Viewers in THIS epoch
    // Map: Key is ((epoch << 64) + index) -> Address
    // This allows us to "reset" the table just by incrementing epoch_counter
    viewers: Table<u128, address>,
    // Map: Address -> Epoch (Tracks when user last claimed to prevent double dip in same epoch)
    user_last_claim_epoch: Table<address, u64>,
}

// ======== Events ========

public struct UserRegistered has copy, drop {
    user: address,
    ad_id: ID,
    ticket_number: u64,
}

public struct SessionRotated has copy, drop {
    old_ad_id: ID,
    new_ad_id: ID,
    viewers_paid: u64,
}

// ======== Init ========

fun init(ctx: &mut TxContext) {
    transfer::share_object(VerificationSession {
        id: object::new(ctx),
        active_ad_id: object::id_from_address(@0x0), // Placeholder
        epoch_counter: 0,
        total_viewers: 0,
        viewers: table::new(ctx),
        user_last_claim_epoch: table::new(ctx),
    });
}

// ======== User Function (Unchanged Param Signature) ========

public entry fun submit_proof_of_attention(
    session: &mut VerificationSession,
    ad: &Advertisement,
    ctx: &mut TxContext,
) {
    let user = tx_context::sender(ctx);
    let ad_id = object::id(ad);

    // 1. Validate Ad matches current Session
    assert!(ad_id == session.active_ad_id, EAdNotActive);

    // 2. Anti-Double Claim (Check if user already claimed in THIS epoch)
    if (table::contains(&session.user_last_claim_epoch, user)) {
        let last_epoch = *table::borrow(&session.user_last_claim_epoch, user);
        assert!(last_epoch != session.epoch_counter, EAlreadyVerified);
    };

    // 3. Register User
    // Construct unique key: Epoch prefix + Index
    let key = ((session.epoch_counter as u128) << 64) + (session.total_viewers as u128);

    table::add(&mut session.viewers, key, user);

    // Update user history
    if (table::contains(&session.user_last_claim_epoch, user)) {
        let record = table::borrow_mut(&mut session.user_last_claim_epoch, user);
        *record = session.epoch_counter;
    } else {
        table::add(&mut session.user_last_claim_epoch, user, session.epoch_counter);
    };

    event::emit(UserRegistered {
        user,
        ad_id,
        ticket_number: session.total_viewers,
    });

    session.total_viewers = session.total_viewers + 1;
}

// ======== NEW FUNCTION: Distribute & Rotate ========
// This extends functionality without touching lottery.move

public entry fun rotate_session(
    session: &mut VerificationSession,
    lottery_config: &LotteryConfig, // Read-Only access to Lottery
    treasury: &mut Treasury,
    r: &Random,
    ctx: &mut TxContext,
) {
    // 1. Fetch the NEW winner from Lottery Config
    let pending_winner_opt = lottery::get_pending_winner(lottery_config); // You need to ensure this view exists
    assert!(std::option::is_some(&pending_winner_opt), ENoNewWinner);

    let new_winner_id = *std::option::borrow(&pending_winner_opt);

    // 3. PAYOUT LOGIC (For the OLD session)
    let total = session.total_viewers;
    if (total > 0) {
        let count_to_pick = if (total < WINNERS_COUNT) { total } else { WINNERS_COUNT };
        let mut generator = random::new_generator(r, ctx);
        let mut i = 0;

        while (i < count_to_pick) {
            // Pick random index in current range
            let random_idx = random::generate_u64_in_range(&mut generator, 0, total - 1);

            // Reconstruct Key
            let key = ((session.epoch_counter as u128) << 64) + (random_idx as u128);

            if (table::contains(&session.viewers, key)) {
                let winner_addr = *table::borrow(&session.viewers, key);
                // Payout
                let reward = treasury::withdraw_yield(treasury, REWARD_AMOUNT, ctx);
                transfer::public_transfer(reward, winner_addr);
            };
            i = i + 1;
        };
    };

    // 4. ROTATE SESSION
    // We increment the epoch counter. This effectively "clears" the table
    // because new submitters will use a higher prefix for their keys.
    let old_ad_id = session.active_ad_id;

    session.epoch_counter = session.epoch_counter + 1;
    session.total_viewers = 0; // Reset viewer count for new ad
    session.active_ad_id = new_winner_id; // Point to new winner

    event::emit(SessionRotated {
        old_ad_id,
        new_ad_id: new_winner_id,
        viewers_paid: total,
    });
}
