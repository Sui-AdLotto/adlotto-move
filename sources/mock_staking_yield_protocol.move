module adlotto::mock_staking_yield_protocol;

use adlotto::mock_sui::{Self, MOCK_SUI};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;

// ======== Error Codes ========
const ENotOwner: u64 = 1;
const ENoRewardsToClaim: u64 = 2;
const ENotAdmin: u64 = 3;

// ======== Constants ========
const BASIS_POINTS: u64 = 10000;
const SECONDS_PER_YEAR: u64 = 31536000000; // milliseconds

// ======== Structs ========

public struct StakingPosition has key, store {
    id: UID,
    owner: address,
    amount: u64, // Principal staked
    ad_id: ID, // Linked Advertisement ID (required)
    epoch_staked: u64, // When position was created
    last_claim_epoch: u64, // Last epoch rewards were claimed
    advertiser_yield_claimable: u64, // Winner's 50% yield share
}

public struct MockStakingYieldProtocol has key {
    id: UID,
    total_staked: u64, // Total MOCK_SUI staked by all users
    staked_balance: Balance<MOCK_SUI>, // Actual staked MOCK_SUI held by pool
    apy_rate: u64, // APY in basis points (default 10000 = 100%)
    admin: address,
}

// ======== Events ========

public struct Staked has copy, drop {
    position_id: ID,
    owner: address,
    ad_id: ID,
    amount: u64,
    epoch: u64,
}

public struct Unstaked has copy, drop {
    position_id: ID,
    owner: address,
    amount: u64,
    yield_earned: u64,
    epoch: u64,
}

public struct YieldClaimed has copy, drop {
    position_id: ID,
    owner: address,
    yield_amount: u64,
    epoch: u64,
}

public struct YieldMinted has copy, drop {
    amount: u64,
    recipient: address,
}

// ======== Admin Functions ========

/// Initialize the MockStakingYieldProtocol (called once during deployment)
public fun create_protocol(apy_rate: u64, admin: address, ctx: &mut TxContext) {
    let protocol = MockStakingYieldProtocol {
        id: object::new(ctx),
        total_staked: 0,
        staked_balance: balance::zero(),
        apy_rate,
        admin,
    };
    transfer::share_object(protocol);
}

// ======== Package Functions (called by ad_entry module) ========

/// Create a staking position for an ad (called when submitting ad)
public(package) fun create_position_for_ad(
    protocol: &mut MockStakingYieldProtocol,
    owner: address,
    amount: u64,
    ad_id: ID,
    epoch: u64,
    stake_balance: Balance<MOCK_SUI>,
    ctx: &mut TxContext,
): ID {
    // Add stake to protocol balance
    balance::join(&mut protocol.staked_balance, stake_balance);
    protocol.total_staked = protocol.total_staked + amount;

    let position_uid = object::new(ctx);
    let position_id = object::uid_to_inner(&position_uid);

    let position = StakingPosition {
        id: position_uid,
        owner,
        amount,
        ad_id,
        epoch_staked: epoch,
        last_claim_epoch: epoch,
        advertiser_yield_claimable: 0,
    };

    event::emit(Staked {
        position_id,
        owner,
        ad_id,
        amount,
        epoch,
    });

    // Transfer position NFT to owner
    transfer::transfer(position, owner);

    position_id
}

/// Unstake position and return coins to owner
public entry fun unstake_position(
    protocol: &mut MockStakingYieldProtocol,
    treasury_cap: &mut TreasuryCap<MOCK_SUI>,
    position: StakingPosition,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let coins = unstake_position_internal(protocol, treasury_cap, position, clock, ctx);
    let sender = sui::tx_context::sender(ctx);
    transfer::public_transfer(coins, sender);
}

/// Internal unstake logic (used by entry function and potentially other modules)
fun unstake_position_internal(
    protocol: &mut MockStakingYieldProtocol,
    treasury_cap: &mut TreasuryCap<MOCK_SUI>,
    position: StakingPosition,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<MOCK_SUI> {
    let sender = sui::tx_context::sender(ctx);
    assert!(position.owner == sender, ENotOwner);

    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    // Calculate pending yield (auto-mint)
    let pending_yield = calculate_yield_internal(
        &position,
        protocol.apy_rate,
        current_epoch,
    );

    let total_yield = pending_yield + position.advertiser_yield_claimable;

    // Update protocol
    protocol.total_staked = protocol.total_staked - position.amount;

    // Withdraw principal from protocol
    let principal_balance = balance::split(&mut protocol.staked_balance, position.amount);
    let mut principal_coin = coin::from_balance(principal_balance, ctx);

    // Mint yield (auto-mint for mock protocol)
    if (total_yield > 0) {
        let yield_coin = mock_sui::mint(treasury_cap, total_yield, ctx);
        coin::join(&mut principal_coin, yield_coin);

        event::emit(YieldMinted {
            amount: total_yield,
            recipient: sender,
        });
    };

    let position_id = object::uid_to_inner(&position.id);

    event::emit(Unstaked {
        position_id,
        owner: sender,
        amount: position.amount,
        yield_earned: total_yield,
        epoch: current_epoch,
    });

    // Destroy position
    let StakingPosition {
        id,
        owner: _,
        amount: _,
        ad_id: _,
        epoch_staked: _,
        last_claim_epoch: _,
        advertiser_yield_claimable: _,
    } = position;
    object::delete(id);

    principal_coin
}

/// Calculate yield for a position at epoch end (called by lottery module)
public(package) fun calculate_epoch_yield(
    position: &StakingPosition,
    protocol: &MockStakingYieldProtocol,
    current_epoch: u64,
): u64 {
    calculate_yield_internal(position, protocol.apy_rate, current_epoch)
}

/// Harvest yield from a position and split 50/50 (treasury/advertiser)
/// Returns the treasury's share as a coin
public fun harvest_yield(
    position: &mut StakingPosition,
    protocol: &MockStakingYieldProtocol,
    treasury_cap: &mut TreasuryCap<MOCK_SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<MOCK_SUI> {
    let current_epoch = clock::timestamp_ms(clock) / 86400000;
    let pending_yield = calculate_yield_internal(position, protocol.apy_rate, current_epoch);

    if (pending_yield == 0) {
        return coin::zero<MOCK_SUI>(ctx)
    };

    // Split 50/50: 50% to treasury, 50% to advertiser (stored in position)
    let treasury_share = pending_yield / 2;
    let advertiser_share = pending_yield - treasury_share; // Handle odd amounts

    // Update position
    position.last_claim_epoch = current_epoch;
    position.advertiser_yield_claimable = position.advertiser_yield_claimable + advertiser_share;

    // Mint treasury's share
    let treasury_coin = mock_sui::mint(treasury_cap, treasury_share, ctx);

    event::emit(YieldMinted {
        amount: treasury_share,
        recipient: @0x0, // Treasury address (placeholder)
    });

    treasury_coin
}

// ======== View Functions ========

public fun calculate_yield(
    position: &StakingPosition,
    protocol: &MockStakingYieldProtocol,
    clock: &Clock,
): u64 {
    let current_epoch = clock::timestamp_ms(clock) / 86400000;
    calculate_yield_internal(position, protocol.apy_rate, current_epoch)
}

public fun get_position_value(
    position: &StakingPosition,
    protocol: &MockStakingYieldProtocol,
    clock: &Clock,
): u64 {
    let pending_yield = calculate_yield(position, protocol, clock);
    position.amount + pending_yield + position.advertiser_yield_claimable
}

public fun get_position_details(
    position: &StakingPosition,
): (
    address, // owner
    u64, // amount
    ID, // ad_id
    u64, // epoch_staked
    u64, // last_claim_epoch
    u64, // advertiser_yield_claimable
) {
    (
        position.owner,
        position.amount,
        position.ad_id,
        position.epoch_staked,
        position.last_claim_epoch,
        position.advertiser_yield_claimable,
    )
}

// ======== Internal Functions ========

fun calculate_yield_internal(position: &StakingPosition, apy_rate: u64, current_epoch: u64): u64 {
    if (current_epoch <= position.last_claim_epoch) {
        return 0
    };

    let epochs_elapsed = current_epoch - position.last_claim_epoch;
    // Simplified: 1 epoch = 1 day, so daily yield = (amount * apy) / 365
    let daily_rate = (apy_rate * 100) / 365; // Convert to daily basis points
    let yield = (position.amount * daily_rate * epochs_elapsed) / (BASIS_POINTS * 100);
    yield
}

// ======== Test Functions ========
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    // Initialize MOCK_SUI first (treasury cap will be shared)
    mock_sui::init_for_testing(ctx);
    // Initialize protocol
    create_protocol(
        10000, // 100% APY
        sui::tx_context::sender(ctx),
        ctx,
    );
}
