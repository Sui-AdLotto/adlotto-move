module adlotto::adlotto;

use adlotto::ad_entry;
use adlotto::lottery;
use adlotto::ad_staking as staking;
use adlotto::treasury;
use sui::tx_context::{TxContext, sender};

/// One-time initialization function called when the package is published
fun init(ctx: &mut TxContext) {
    let admin = sender(ctx);

    // Initialize AdRegistry
    ad_entry::create_registry(
        1000000000, // 1 SUI minimum stake
        1000, // Max 1000 ads per epoch
        admin,
        ctx,
    );

    // Initialize StakingPool
    staking::create_pool(
        800, // 8% APY (800 basis points)
        100000000, // 0.1 SUI minimum stake
        100000000000, // 100 SUI maximum stake
        admin,
        ctx,
    );

    // Initialize LotteryConfig
    lottery::create_config(
        10000, // 1:1 voting weight (10000 basis points)
        200, // 2% platform fee (200 basis points)
        admin,
        ctx,
    );

    // Initialize Treasury
    treasury::create_treasury(
        admin,
        ctx,
    );
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
