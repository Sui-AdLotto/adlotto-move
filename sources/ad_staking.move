module adlotto::ad_staking;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;
use adlotto::mock_sui::MOCK_SUI;

// ======== Error Codes ========
const EInsufficientStake: u64 = 1;
const EExceedsMaxStake: u64 = 2;
const ENotOwner: u64 = 3;
const ENoRewardsToClaim: u64 = 4;
const EInsufficientYieldReserve: u64 = 5;
const ENotAdmin: u64 = 6;

// ======== Constants ========
const BASIS_POINTS: u64 = 10000;
const SECONDS_PER_YEAR: u64 = 31536000000; // milliseconds

// ======== Structs ========

public struct StakingPosition has key, store {
    id: UID,
    owner: address,
    amount: u64, // Principal staked
    epoch_staked: u64, // When position was created
    accumulated_yield: u64, // Passive staking yield earned
    voting_rewards: u64, // Rewards from voting
    last_claim_epoch: u64, // Last epoch rewards were claimed
}

public struct StakingPool has key {
    id: UID,
    total_staked: u64, // Total MOCK_SUI staked by all users
    staked_balance: Balance<MOCK_SUI>, // Actual staked MOCK_SUI held by pool
    yield_reserve: Balance<MOCK_SUI>, // Pool of yield to distribute
    apy_rate: u64, // APY in basis points (e.g., 800 = 8%)
    min_stake: u64, // Minimum stake
    max_stake: u64, // Maximum stake
    admin: address,
}

// ======== Events ========

public struct Staked has copy, drop {
    position_id: ID,
    owner: address,
    amount: u64,
    epoch: u64,
}

public struct Unstaked has copy, drop {
    position_id: ID,
    owner: address,
    amount: u64,
    yield_earned: u64,
    voting_rewards: u64,
    epoch: u64,
}

public struct RewardsClaimed has copy, drop {
    position_id: ID,
    owner: address,
    yield_claimed: u64,
    voting_rewards_claimed: u64,
    epoch: u64,
}

public struct YieldAdded has copy, drop {
    amount: u64,
    total_reserve: u64,
}

// ======== Admin Functions ========

/// Initialize the StakingPool (called once during deployment)
public fun create_pool(
    apy_rate: u64,
    min_stake: u64,
    max_stake: u64,
    admin: address,
    ctx: &mut TxContext,
) {
    let pool = StakingPool {
        id: object::new(ctx),
        total_staked: 0,
        staked_balance: balance::zero(),
        yield_reserve: balance::zero(),
        apy_rate,
        min_stake,
        max_stake,
        admin,
    };
    transfer::share_object(pool);
}

/// Update APY rate (admin only)
public entry fun update_apy(pool: &mut StakingPool, new_apy_rate: u64, ctx: &TxContext) {
    assert!(sui::tx_context::sender(ctx) == pool.admin, ENotAdmin);
    pool.apy_rate = new_apy_rate;
}

/// Add yield to the pool (admin/treasury function)
public entry fun add_yield_to_pool(pool: &mut StakingPool, yield_coin: Coin<MOCK_SUI>, ctx: &TxContext) {
    assert!(sui::tx_context::sender(ctx) == pool.admin, ENotAdmin);
    let amount = coin::value(&yield_coin);
    balance::join(&mut pool.yield_reserve, coin::into_balance(yield_coin));

    event::emit(YieldAdded {
        amount,
        total_reserve: balance::value(&pool.yield_reserve),
    });
}

// ======== User Functions ========

/// Stake MOCK_SUI tokens
public entry fun stake(
    pool: &mut StakingPool,
    stake_coin: Coin<MOCK_SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = coin::value(&stake_coin);
    assert!(amount >= pool.min_stake, EInsufficientStake);
    assert!(amount <= pool.max_stake, EExceedsMaxStake);

    let owner = sui::tx_context::sender(ctx);
    let position_uid = object::new(ctx);
    let position_id = object::uid_to_inner(&position_uid);
    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    // Add stake to pool balance
    balance::join(&mut pool.staked_balance, coin::into_balance(stake_coin));
    pool.total_staked = pool.total_staked + amount;

    let position = StakingPosition {
        id: position_uid,
        owner,
        amount,
        epoch_staked: current_epoch,
        accumulated_yield: 0,
        voting_rewards: 0,
        last_claim_epoch: current_epoch,
    };

    event::emit(Staked {
        position_id,
        owner,
        amount,
        epoch: current_epoch,
    });

    // Transfer position NFT to user
    transfer::transfer(position, owner);
}

/// Unstake and withdraw all funds
public entry fun unstake(
    pool: &mut StakingPool,
    position: StakingPosition,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = sui::tx_context::sender(ctx);
    assert!(position.owner == sender, ENotOwner);

    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    // Calculate pending yield
    let pending_yield = calculate_yield_internal(
        &position,
        pool.apy_rate,
        current_epoch,
    );

    let total_rewards = pending_yield + position.accumulated_yield + position.voting_rewards;
    let total_withdrawal = position.amount + total_rewards;

    // Check yield reserve
    assert!(balance::value(&pool.yield_reserve) >= total_rewards, EInsufficientYieldReserve);

    // Update pool
    pool.total_staked = pool.total_staked - position.amount;

    // Withdraw principal from pool
    let principal_balance = balance::split(&mut pool.staked_balance, position.amount);
    let mut principal_coin = coin::from_balance(principal_balance, ctx);

    // Withdraw rewards from yield reserve
    let reward_balance = balance::split(&mut pool.yield_reserve, total_rewards);
    let reward_coin = coin::from_balance(reward_balance, ctx);

    // Combine principal and rewards
    coin::join(&mut principal_coin, reward_coin);

    let position_id = object::uid_to_inner(&position.id);

    event::emit(Unstaked {
        position_id,
        owner: sender,
        amount: position.amount,
        yield_earned: pending_yield + position.accumulated_yield,
        voting_rewards: position.voting_rewards,
        epoch: current_epoch,
    });

    // Destroy position
    let StakingPosition {
        id,
        owner: _,
        amount: _,
        epoch_staked: _,
        accumulated_yield: _,
        voting_rewards: _,
        last_claim_epoch: _,
    } = position;
    object::delete(id);

    // Transfer funds
    transfer::public_transfer(principal_coin, sender);
}

/// Claim rewards without unstaking
public entry fun claim_rewards(
    pool: &mut StakingPool,
    position: &mut StakingPosition,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = sui::tx_context::sender(ctx);
    assert!(position.owner == sender, ENotOwner);

    let current_epoch = clock::timestamp_ms(clock) / 86400000;

    // Calculate pending yield
    let pending_yield = calculate_yield_internal(
        position,
        pool.apy_rate,
        current_epoch,
    );

    let total_rewards = pending_yield + position.accumulated_yield + position.voting_rewards;
    assert!(total_rewards > 0, ENoRewardsToClaim);

    // Check yield reserve
    assert!(balance::value(&pool.yield_reserve) >= total_rewards, EInsufficientYieldReserve);

    // Extract rewards
    let reward_balance = balance::split(&mut pool.yield_reserve, total_rewards);
    let reward_coin = coin::from_balance(reward_balance, ctx);

    // Reset reward counters
    position.accumulated_yield = 0;
    position.voting_rewards = 0;
    position.last_claim_epoch = current_epoch;

    let position_id = object::uid_to_inner(&position.id);

    event::emit(RewardsClaimed {
        position_id,
        owner: sender,
        yield_claimed: pending_yield,
        voting_rewards_claimed: position.voting_rewards,
        epoch: current_epoch,
    });

    // Transfer rewards
    transfer::public_transfer(reward_coin, sender);
}

// ======== View Functions ========

public fun calculate_yield(position: &StakingPosition, pool: &StakingPool, clock: &Clock): u64 {
    let current_epoch = clock::timestamp_ms(clock) / 86400000;
    calculate_yield_internal(position, pool.apy_rate, current_epoch)
}

public fun get_position_value(position: &StakingPosition, pool: &StakingPool, clock: &Clock): u64 {
    let pending_yield = calculate_yield(position, pool, clock);
    position.amount + pending_yield + position.accumulated_yield + position.voting_rewards
}

public fun get_position_details(
    position: &StakingPosition,
): (
    address, // owner
    u64, // amount
    u64, // epoch_staked
    u64, // accumulated_yield
    u64, // voting_rewards
    u64, // last_claim_epoch
) {
    (
        position.owner,
        position.amount,
        position.epoch_staked,
        position.accumulated_yield,
        position.voting_rewards,
        position.last_claim_epoch,
    )
}

public fun get_pool_stats(
    pool: &StakingPool,
): (
    u64, // total_staked
    u64, // staked_balance
    u64, // yield_reserve
    u64, // apy_rate
    u64, // min_stake
    u64, // max_stake
) {
    (
        pool.total_staked,
        balance::value(&pool.staked_balance),
        balance::value(&pool.yield_reserve),
        pool.apy_rate,
        pool.min_stake,
        pool.max_stake,
    )
}

public fun get_voting_power(position: &StakingPosition): u64 {
    position.amount
}

public fun get_position_owner(position: &StakingPosition): address {
    position.owner
}

public fun get_position_amount(position: &StakingPosition): u64 {
    position.amount
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

// ======== Package Functions ========

/// Add voting rewards to a position (called by voting module)
public(package) fun add_voting_rewards(position: &mut StakingPosition, reward_amount: u64) {
    position.voting_rewards = position.voting_rewards + reward_amount;
}

/// Get position ID
public(package) fun get_position_id(position: &StakingPosition): ID {
    object::uid_to_inner(&position.id)
}

// ======== Test Functions ========
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    create_pool(
        800, // 8% APY
        100000000, // 0.1 MOCK_SUI minimum
        100000000000, // 100 MOCK_SUI maximum
        sui::tx_context::sender(ctx),
        ctx,
    );
}

#[test_only]
public fun mint_for_testing(ctx: &mut TxContext): Coin<MOCK_SUI> {
    coin::mint_for_testing<MOCK_SUI>(1000000000, ctx)
}
