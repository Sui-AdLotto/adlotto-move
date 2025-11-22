module adlotto::adlotto;

use adlotto::ad_entry;
use adlotto::lottery;
use adlotto::mock_staking_yield_protocol as protocol;
use adlotto::treasury;
use sui::tx_context::{TxContext, sender};

/// One-time initialization function called when the package is published
fun init(ctx: &mut TxContext) {
    let admin = sender(ctx);

    // Initialize AdRegistry
    ad_entry::create_registry(
        admin,
        ctx,
    );

    // Initialize MockStakingYieldProtocol
    protocol::create_protocol(
        10000, // 100% APY (10000 basis points)
        admin,
        ctx,
    );

    // Initialize LotteryConfig
    lottery::create_config(
        10000, // 1:1 voting weight (10000 basis points)
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
