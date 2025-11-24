module adlotto::treasury;

use adlotto::mock_sui::{Self, MOCK_SUI};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

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
public entry fun deposit_yield(
    treasury: &mut Treasury,
    yield_coin: Coin<MOCK_SUI>,
    ctx: &TxContext,
) {
    assert!(sui::tx_context::sender(ctx) == treasury.admin, ENotAdmin);

    let amount = coin::value(&yield_coin);
    balance::join(&mut treasury.yield_reserves, coin::into_balance(yield_coin));

    event::emit(YieldDeposited {
        amount,
        total_yield_reserve: balance::value(&treasury.yield_reserves),
    });
}

public entry fun admin_fund_yield(
    treasury: &mut Treasury,
    treasury_cap: &mut TreasuryCap<MOCK_SUI>,
    amount: u64,
    ctx: &mut TxContext,
) {
    // 1. Mint new coins
    let new_coin = adlotto::mock_sui::mint(treasury_cap, amount, ctx);

    // 2. Deposit directly to reserves
    balance::join(&mut treasury.yield_reserves, coin::into_balance(new_coin));

    // 3. Emit event
    event::emit(YieldDeposited {
        amount,
        total_yield_reserve: balance::value(&treasury.yield_reserves),
    });
}

public fun withdraw_yield(
    treasury: &mut Treasury,
    amount: u64,
    ctx: &mut TxContext,
): Coin<MOCK_SUI> {
    // In production: Add assert!(msg_sender is verification_module)
    // Check if there's sufficient balance before attempting to split
    let available = balance::value(&treasury.yield_reserves);
    assert!(available >= amount, EInsufficientYieldReserve);

    let balance = balance::split(&mut treasury.yield_reserves, amount);
    coin::from_balance(balance, ctx)
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
