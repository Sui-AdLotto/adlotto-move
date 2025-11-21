module adlotto::ad_entry;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;
use sui::vec_set::{Self, VecSet};
use walrus::blob::Blob;
use adlotto::mock_sui::MOCK_SUI;

// ======== Error Codes ========
const EInsufficientStake: u64 = 1;
const EAdNotActive: u64 = 2;
const ENotAdvertiser: u64 = 3;
const EAdAlreadyInactive: u64 = 4;
const EMaxAdsReached: u64 = 5;

// ======== Structs ========

public struct Advertisement has key, store {
    id: UID,
    advertiser: address,
    sealed_blob: Blob, // Walrus Blob (Sealed/Encrypted content)
    stake_amount: u64, // Amount staked in MOCK_SUI
    stake_balance: Balance<MOCK_SUI>, // Actual balance held
    epoch_created: u64, // Epoch when ad was first submitted
    total_votes_received: u64, // Lifetime votes
    wins_count: u64, // Number of times this ad won
    is_active: bool, // If true, auto-enters next lottery
    is_unsealed: bool, // Visibility status (true if it ever won)
}

public struct AdRegistry has key {
    id: UID,
    active_ads: VecSet<ID>, // Registry of all currently active ads
    min_ad_stake: u64, // Minimum stake to maintain active status
    max_ads_per_epoch: u64, // Cap for gas optimization (optional)
    total_ads_sealed: u64, // Lifetime sealed ads counter
    admin: address,
}

// ======== Events ========

public struct AdSealed has copy, drop {
    ad_id: ID,
    advertiser: address,
    blob_id: ID,
    stake_amount: u64,
    is_active: bool,
    epoch: u64,
}

public struct AdUnstaked has copy, drop {
    ad_id: ID,
    advertiser: address,
    stake_amount: u64,
    epoch: u64,
}

public struct AdWon has copy, drop {
    ad_id: ID,
    advertiser: address,
    epoch: u64,
    total_wins: u64,
}

public struct VoteRecorded has copy, drop {
    ad_id: ID,
    total_votes: u64,
}

// ======== Admin Functions ========

/// Initialize the AdRegistry (called once during deployment)
public fun create_registry(
    min_ad_stake: u64,
    max_ads_per_epoch: u64,
    admin: address,
    ctx: &mut TxContext,
) {
    let registry = AdRegistry {
        id: object::new(ctx),
        active_ads: vec_set::empty(),
        min_ad_stake,
        max_ads_per_epoch,
        total_ads_sealed: 0,
        admin,
    };
    transfer::share_object(registry);
}

/// Update minimum stake requirement (admin only)
public entry fun update_min_stake(registry: &mut AdRegistry, new_min_stake: u64, ctx: &TxContext) {
    assert!(sui::tx_context::sender(ctx) == registry.admin, ENotAdvertiser);
    registry.min_ad_stake = new_min_stake;
}

// ======== Advertiser Functions ========

/// Submit a sealed ad with stake
public entry fun submit_sealed_ad(
    registry: &mut AdRegistry,
    blob: Blob,
    stake: Coin<MOCK_SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let stake_amount = coin::value(&stake);
    assert!(stake_amount >= registry.min_ad_stake, EInsufficientStake);

    // Check max ads limit if set
    if (registry.max_ads_per_epoch > 0) {
        assert!(vec_set::size(&registry.active_ads) < registry.max_ads_per_epoch, EMaxAdsReached);
    };

    let advertiser = sui::tx_context::sender(ctx);
    let ad_uid = object::new(ctx);
    let ad_id = object::uid_to_inner(&ad_uid);
    let blob_id = walrus::blob::object_id(&blob);
    let current_epoch = clock::timestamp_ms(clock) / 86400000; // Convert to days

    let ad = Advertisement {
        id: ad_uid,
        advertiser,
        sealed_blob: blob,
        stake_amount,
        stake_balance: coin::into_balance(stake),
        epoch_created: current_epoch,
        total_votes_received: 0,
        wins_count: 0,
        is_active: true,
        is_unsealed: false,
    };

    // Add to active registry
    vec_set::insert(&mut registry.active_ads, ad_id);
    registry.total_ads_sealed = registry.total_ads_sealed + 1;

    // Emit event
    event::emit(AdSealed {
        ad_id,
        advertiser,
        blob_id,
        stake_amount,
        is_active: true,
        epoch: current_epoch,
    });

    // Share the ad object so it can be referenced
    transfer::share_object(ad);
}

/// Unstake ad and withdraw funds
public entry fun unstake_ad(
    registry: &mut AdRegistry,
    ad: &mut Advertisement,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = sui::tx_context::sender(ctx);
    assert!(ad.advertiser == sender, ENotAdvertiser);
    assert!(ad.is_active, EAdAlreadyInactive);

    // Mark as inactive
    ad.is_active = false;
    let ad_id = object::uid_to_inner(&ad.id);

    // Remove from active registry
    vec_set::remove(&mut registry.active_ads, &ad_id);

    // Withdraw stake
    let stake_amount = ad.stake_amount;
    let stake_to_return = coin::from_balance(
        balance::withdraw_all(&mut ad.stake_balance),
        ctx,
    );

    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    // Emit event
    event::emit(AdUnstaked {
        ad_id,
        advertiser: sender,
        stake_amount,
        epoch: current_epoch,
    });

    // Transfer stake back to advertiser
    transfer::public_transfer(stake_to_return, sender);
}

// ======== View Functions ========

public fun get_ad_details(
    ad: &Advertisement,
): (
    address, // advertiser
    ID, // sealed_blob_id
    u64, // stake_amount
    u64, // epoch_created
    u64, // total_votes_received
    u64, // wins_count
    bool, // is_active
    bool, // is_unsealed
) {
    (
        ad.advertiser,
        walrus::blob::object_id(&ad.sealed_blob),
        ad.stake_amount,
        ad.epoch_created,
        ad.total_votes_received,
        ad.wins_count,
        ad.is_active,
        ad.is_unsealed,
    )
}

public fun is_active(ad: &Advertisement): bool {
    ad.is_active
}

public fun is_unsealed(ad: &Advertisement): bool {
    ad.is_unsealed
}

public fun get_sealed_blob_id(ad: &Advertisement): ID {
    walrus::blob::object_id(&ad.sealed_blob)
}

public fun get_sealed_blob(ad: &Advertisement): &Blob {
    &ad.sealed_blob
}

public fun get_stake_amount(ad: &Advertisement): u64 {
    ad.stake_amount
}

public fun get_total_votes(ad: &Advertisement): u64 {
    ad.total_votes_received
}

public fun get_wins_count(ad: &Advertisement): u64 {
    ad.wins_count
}

public fun get_active_ads(registry: &AdRegistry): &VecSet<ID> {
    &registry.active_ads
}

public fun get_total_ads_sealed(registry: &AdRegistry): u64 {
    registry.total_ads_sealed
}

public fun get_min_stake(registry: &AdRegistry): u64 {
    registry.min_ad_stake
}

// ======== Internal Functions (package visibility) ========

/// Record a vote for this ad (called by voting module)
public(package) fun record_vote(ad: &mut Advertisement, votes: u64) {
    ad.total_votes_received = ad.total_votes_received + votes;

    event::emit(VoteRecorded {
        ad_id: object::uid_to_inner(&ad.id),
        total_votes: ad.total_votes_received,
    });
}

/// Mark ad as winner and unseal it (called by lottery module)
public(package) fun mark_as_winner(ad: &mut Advertisement, epoch: u64) {
    ad.wins_count = ad.wins_count + 1;
    ad.is_unsealed = true;

    event::emit(AdWon {
        ad_id: object::uid_to_inner(&ad.id),
        advertiser: ad.advertiser,
        epoch,
        total_wins: ad.wins_count,
    });
}

/// Get advertiser address (package visibility for validation)
public(package) fun get_advertiser(ad: &Advertisement): address {
    ad.advertiser
}

/// Get ad UID (package visibility)
public(package) fun get_ad_uid(ad: &Advertisement): &UID {
    &ad.id
}

// ======== Test Functions ========
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    create_registry(
        1000000000, // 1 MOCK_SUI minimum
        100,
        sui::tx_context::sender(ctx),
        ctx,
    );
}
