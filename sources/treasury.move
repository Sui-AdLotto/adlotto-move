module adlotto::treasury;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;
use adlotto::mock_sui::MOCK_SUI;

// ======== Error Codes ========
const ENotAdmin: u64 = 1;
const EInsufficientBalance: u64 = 2;
const EInsufficientYieldReserve: u64 = 3;
const EInsufficientVotingRewards: u64 = 4;

// ======== Structs ========

public struct Treasury has key {
    id: UID,
    balance: Balance<MOCK_SUI>, // Platform funds
    total_fees_collected: u64, // Lifetime fees
    yield_reserves: Balance<MOCK_SUI>, // Reserved for staking yield
    voting_rewards_pool: Balance<MOCK_SUI>, // Reserved for voting incentives
    admin: address, // Admin/owner address
}

// ======== Events ========

public struct YieldDeposited has copy, drop {
    amount: u64,
    total_yield_reserve: u64,
}

public struct VotingRewardsFunded has copy, drop {
    amount: u64,
    total_voting_rewards: u64,
}


public struct YieldDistributed has copy, drop {
    amount: u64,
    recipient: address,
    remaining_reserve: u64,
}

// ======== Admin Functions ========

/// Initialize the Treasury (called once during deployment)
public fun create_treasury(admin: address, ctx: &mut TxContext) {
    let treasury = Treasury {
        id: object::new(ctx),
        balance: balance::zero(),
        total_fees_collected: 0,
        yield_reserves: balance::zero(),
        voting_rewards_pool: balance::zero(),
        admin,
    };
    transfer::share_object(treasury);
}

/// Deposit yield to the pool
public entry fun deposit_yield(treasury: &mut Treasury, yield_coin: Coin<MOCK_SUI>, ctx: &TxContext) {
    assert!(sui::tx_context::sender(ctx) == treasury.admin, ENotAdmin);

    let amount = coin::value(&yield_coin);
    balance::join(&mut treasury.yield_reserves, coin::into_balance(yield_coin));

    event::emit(YieldDeposited {
        amount,
        total_yield_reserve: balance::value(&treasury.yield_reserves),
    });
}

/// Fund voting rewards pool
public entry fun fund_voting_rewards(
    treasury: &mut Treasury,
    reward_coin: Coin<MOCK_SUI>,
    ctx: &TxContext,
) {
    assert!(sui::tx_context::sender(ctx) == treasury.admin, ENotAdmin);

    let amount = coin::value(&reward_coin);
    balance::join(&mut treasury.voting_rewards_pool, coin::into_balance(reward_coin));

    event::emit(VotingRewardsFunded {
        amount,
        total_voting_rewards: balance::value(&treasury.voting_rewards_pool),
    });
}


// ======== System Functions (Package Visibility) ========

/// Distribute yield to a recipient (called by staking module)
public(package) fun distribute_yield(
    treasury: &mut Treasury,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert!(balance::value(&treasury.yield_reserves) >= amount, EInsufficientYieldReserve);

    let yield_amount = balance::split(&mut treasury.yield_reserves, amount);
    let yield_coin = coin::from_balance(yield_amount, ctx);

    event::emit(YieldDistributed {
        amount,
        recipient,
        remaining_reserve: balance::value(&treasury.yield_reserves),
    });

    transfer::public_transfer(yield_coin, recipient);
}

/// Distribute voting rewards (called by voting module)
public(package) fun distribute_voting_reward(
    treasury: &mut Treasury,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    assert!(balance::value(&treasury.voting_rewards_pool) >= amount, EInsufficientVotingRewards);

    let reward_amount = balance::split(&mut treasury.voting_rewards_pool, amount);
    let reward_coin = coin::from_balance(reward_amount, ctx);

    transfer::public_transfer(reward_coin, recipient);
}


// ======== View Functions ========

public fun get_treasury_stats(
    treasury: &Treasury,
): (
    u64, // platform_balance
    u64, // total_fees_collected
    u64, // yield_reserves
    u64, // voting_rewards_pool
) {
    (
        balance::value(&treasury.balance),
        treasury.total_fees_collected,
        balance::value(&treasury.yield_reserves),
        balance::value(&treasury.voting_rewards_pool),
    )
}

public fun get_yield_reserve(treasury: &Treasury): u64 {
    balance::value(&treasury.yield_reserves)
}

public fun get_voting_rewards_pool(treasury: &Treasury): u64 {
    balance::value(&treasury.voting_rewards_pool)
}

public fun get_platform_balance(treasury: &Treasury): u64 {
    balance::value(&treasury.balance)
}

public fun get_total_fees_collected(treasury: &Treasury): u64 {
    treasury.total_fees_collected
}

public fun get_admin(treasury: &Treasury): address {
    treasury.admin
}

// ======== Test Functions ========
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    create_treasury(
        sui::tx_context::sender(ctx),
        ctx,
    );
}
