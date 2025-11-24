module adlotto::mock_sui;

use sui::coin::{Self, Coin, TreasuryCap};
use sui::transfer;
use sui::tx_context::TxContext;

/// Mock SUI token for testing
public struct MOCK_SUI has drop {}

/// Initialize the mock SUI token with a treasury cap
fun init(witness: MOCK_SUI, ctx: &mut TxContext) {
    let (mut treasury, metadata) = coin::create_currency(
        witness,
        9, // decimals (same as SUI)
        b"MOCK_SUI",
        b"Mock SUI",
        b"Mock SUI token for testing AdLotto",
        std::option::none(),
        ctx,
    );

    // send mock sui to admin
    let admin = @0x061d0e283d69e865a0b771f2744a3df75889c7c341217bca905421cc7ba69e7e;
    let amount = 1000000000000000000;
    coin::mint_and_transfer(&mut treasury, amount, admin, ctx);

    transfer::public_freeze_object(metadata);
    // Share treasury cap so it can be used by protocol and other modules
    transfer::public_share_object(treasury);
}

/// Mint mock SUI tokens for testing
public fun mint(
    treasury: &mut TreasuryCap<MOCK_SUI>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<MOCK_SUI> {
    coin::mint(treasury, amount, ctx)
}

/// Mint and transfer to recipient
public entry fun mint_and_transfer(
    treasury: &mut TreasuryCap<MOCK_SUI>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    let coin = coin::mint(treasury, amount, ctx);
    transfer::public_transfer(coin, recipient);
}

/// Burn mock SUI tokens
public fun burn(treasury: &mut TreasuryCap<MOCK_SUI>, coin: Coin<MOCK_SUI>) {
    coin::burn(treasury, coin);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(MOCK_SUI {}, ctx);
}
