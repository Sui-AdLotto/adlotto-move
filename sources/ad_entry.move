module adlotto::ad_entry;

use adlotto::mock_staking_yield_protocol::{Self as protocol, MockStakingYieldProtocol};
use adlotto::mock_sui::MOCK_SUI;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;
use sui::vec_set::{Self, VecSet};
use walrus::blob::Blob;

// ======== Error Codes ========
const EAdNotActive: u64 = 1;
const ENotAdvertiser: u64 = 2;
const EAdAlreadyInactive: u64 = 3;
const EAdNotUnsealed: u64 = 4;
const EInvalidIdentity: u64 = 5;

// ======== Structs ========

public struct Advertisement has key, store {
    id: UID,
    advertiser: address,
    sealed_blob_id: ID, // Walrus Blob ID (blob remains as separate object for Walrus scan)
    stake_amount: u64, // Amount staked in MOCK_SUI
    stake_balance: Balance<MOCK_SUI>, // Actual balance held
    encryption_id: vector<u8>,
    staking_position_id: ID, // Linked StakingPosition for unified tracking
    epoch_created: u64, // Epoch when ad was first submitted
    total_votes_received: u64, // Lifetime votes
    wins_count: u64, // Number of times this ad won
    is_active: bool, // If true, auto-enters next lottery
    is_unsealed: bool, // Visibility status (true if it ever won)
}

public struct AdRegistry has key {
    id: UID,
    active_ads: VecSet<ID>, // Registry of all currently active ads
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

public struct AdUnsealed has copy, drop {
    ad_id: ID,
    advertiser: address,
    blob_id: ID,
    epoch: u64,
}

// ======== Admin Functions ========

/// Initialize the AdRegistry (called once during deployment)
public fun create_registry(admin: address, ctx: &mut TxContext) {
    let registry = AdRegistry {
        id: object::new(ctx),
        active_ads: vec_set::empty(),
        total_ads_sealed: 0,
        admin,
    };
    transfer::share_object(registry);
}

// ======== Advertiser Functions ========

/// Submit a sealed ad with stake (also creates a StakingPosition)
///
/// IMPORTANT: The `blob` parameter should be a shared or owned Blob object.
/// We store only the blob ID in the Advertisement struct, keeping the blob as a separate object
/// so it remains accessible via Walrus scan tools. The blob should be shared using
/// `walrus::shared_blob::new()` before calling this function to ensure it stays alive.
public entry fun submit_sealed_ad(
    registry: &mut AdRegistry,
    yield_protocol: &mut MockStakingYieldProtocol,
    blob: &Blob, // Reference to blob (blob remains separate for Walrus scan)
    stake: Coin<MOCK_SUI>,
    clock: &Clock,
    encryption_id: vector<u8>,
    ctx: &mut TxContext,
) {
    let stake_amount = coin::value(&stake);
    let advertiser = sui::tx_context::sender(ctx);
    let ad_uid = object::new(ctx);
    let ad_id = object::uid_to_inner(&ad_uid);
    let blob_id = walrus::blob::object_id(blob);
    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    let staking_position_id = protocol::create_position_for_ad(
        yield_protocol,
        advertiser,
        stake_amount,
        ad_id,
        current_epoch,
        coin::into_balance(stake),
        ctx,
    );

    let ad = Advertisement {
        id: ad_uid,
        advertiser,
        sealed_blob_id: blob_id, // Store blob ID only, blob remains as separate object
        encryption_id,
        stake_amount,
        stake_balance: balance::zero(),
        staking_position_id,
        epoch_created: current_epoch,
        total_votes_received: 0,
        wins_count: 0,
        is_active: true,
        is_unsealed: false,
    };

    vec_set::insert(&mut registry.active_ads, ad_id);
    registry.total_ads_sealed = registry.total_ads_sealed + 1;

    event::emit(AdSealed {
        ad_id,
        advertiser,
        blob_id,
        stake_amount,
        is_active: true,
        epoch: current_epoch,
    });

    transfer::share_object(ad);
}

public fun mark_as_winner(ad: &mut Advertisement, clock: &Clock) {
    ad.is_unsealed = true;
    let ad_id = object::uid_to_inner(&ad.id);
    let blob_id = ad.sealed_blob_id;
    let current_epoch = clock::timestamp_ms(clock) / 86400000;
    event::emit(AdUnsealed {
        ad_id,
        advertiser: ad.advertiser,
        blob_id,
        epoch: current_epoch,
    });
}

public entry fun seal_approve(id: vector<u8>, ad: &Advertisement) {
    // 1. Verify Identity: The ID requested by Seal must match the ID stored in this Ad
    assert!(ad.encryption_id == id, EInvalidIdentity);

    // 2. Verify Access: Ensure the ad has actually won
    assert!(ad.is_unsealed, EAdNotUnsealed);
}

/// Deactivate ad (mark as inactive).
/// Note: Funds must be unstaked separately by calling the protocol with the StakingPosition NFT
public entry fun deactivate_ad(
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

    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    // Emit event
    event::emit(AdUnstaked {
        ad_id,
        advertiser: sender,
        stake_amount: ad.stake_amount,
        epoch: current_epoch,
    });
}

// ======== View Functions ========

public fun get_list_ads(registry: &AdRegistry): vector<ID> {
    vec_set::into_keys(registry.active_ads)
}

public fun get_ad_details(
    ad: &Advertisement,
): (
    address, // advertiser
    ID, // sealed_blob_id
    u64, // stake_amount
    ID, // staking_position_id
    u64, // epoch_created
    u64, // total_votes_received
    u64, // wins_count
    bool, // is_active
    bool, // is_unsealed
    vector<u8>, // encryption_id
) {
    (
        ad.advertiser,
        ad.sealed_blob_id,
        ad.stake_amount,
        ad.staking_position_id,
        ad.epoch_created,
        ad.total_votes_received,
        ad.wins_count,
        ad.is_active,
        ad.is_unsealed,
        ad.encryption_id,
    )
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
        sui::tx_context::sender(ctx),
        ctx,
    );
}
