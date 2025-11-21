#[test_only]
module adlotto::adlotto_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object;
    use sui::clock::{Self, Clock};
    
    use adlotto::mock_sui::{Self, MOCK_SUI};
    use adlotto::ad_entry::{Self, AdRegistry};
    use adlotto::ad_staking::{Self as staking, StakingPool};
    use adlotto::lottery::{Self, LotteryConfig};
    use adlotto::treasury::{Self, Treasury};
    // Note: Walrus Blob creation requires storage resources and is not easily testable
    // in unit tests. Ad submission tests are commented out until proper test infrastructure is available.

    const ADMIN: address = @0xAD;
    const ADVERTISER: address = @0xAD1;
    const USER1: address = @0xAD2;
    const USER2: address = @0xAD3;

    // Helper function to setup the system
    fun setup_system(scenario: &mut Scenario) {
        // Initialize all AdLotto modules
        ts::next_tx(scenario, ADMIN);
        {
            // Initialize MockSui treasury
            mock_sui::init_for_testing(ts::ctx(scenario));
            
            ad_entry::create_registry(
                1_000_000_000, // 1 MOCK_SUI minimum
                100,
                ADMIN,
                ts::ctx(scenario)
            );

            staking::create_pool(
                800,            // 8% APY
                100_000_000,    // 0.1 MOCK_SUI min
                100_000_000_000, // 100 MOCK_SUI max
                ADMIN,
                ts::ctx(scenario)
            );

            lottery::create_config(
                10000,  // 1:1 voting weight
                200,    // 2% platform fee
                ADMIN,
                ts::ctx(scenario)
            );

            treasury::create_treasury(
                ADMIN,
                ts::ctx(scenario)
            );
        };
    }

    // Helper to mint test MOCK_SUI coins
    fun mint_sui_for_testing(scenario: &mut Scenario, recipient: address, amount: u64) {
        ts::next_tx(scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<TreasuryCap<MOCK_SUI>>(scenario);
            mock_sui::mint_and_transfer(&mut treasury, amount, recipient, ts::ctx(scenario));
            ts::return_shared(treasury);
        };
    }

    #[test]
    fun test_basic_system_initialization() {
        let mut scenario = ts::begin(ADMIN);
        setup_system(&mut scenario);

        // Verify AdRegistry exists
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<AdRegistry>(&scenario);
            assert!(ad_entry::get_total_ads_sealed(&registry) == 0, 0);
            assert!(ad_entry::get_min_stake(&registry) == 1_000_000_000, 1);
            ts::return_shared(registry);
        };

        // Verify StakingPool exists
        ts::next_tx(&mut scenario, ADMIN);
        {
            let pool = ts::take_shared<StakingPool>(&scenario);
            let (total_staked, staked_balance, yield_reserve, apy, min_stake, max_stake) = 
                staking::get_pool_stats(&pool);
            assert!(total_staked == 0, 2);
            assert!(apy == 800, 3);
            assert!(min_stake == 100_000_000, 4);
            ts::return_shared(pool);
        };

        // Verify LotteryConfig exists
        ts::next_tx(&mut scenario, ADMIN);
        {
            let config = ts::take_shared<LotteryConfig>(&scenario);
            let (current_epoch, duration, voting_weight, platform_fee) = 
                lottery::get_config_details(&config);
            assert!(current_epoch == 0, 5);
            assert!(platform_fee == 200, 6);
            ts::return_shared(config);
        };

        // Verify Treasury exists
        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury_obj = ts::take_shared<Treasury>(&scenario);
            let (balance, fees, yield_reserve, voting_rewards) = 
                treasury::get_treasury_stats(&treasury_obj);
            assert!(balance == 0, 7);
            assert!(fees == 0, 8);
            ts::return_shared(treasury_obj);
        };

        ts::end(scenario);
    }

    #[test]
    fun test_user_can_stake() {
        let mut scenario = ts::begin(ADMIN);
        setup_system(&mut scenario);
        
        // Mint MOCK_SUI for user
        mint_sui_for_testing(&mut scenario, USER1, 10_000_000_000); // 10 MOCK_SUI

        // Create clock
        ts::next_tx(&mut scenario, ADMIN);
        {
            let clock_obj = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::share_for_testing(clock_obj);
        };

        // User stakes
        ts::next_tx(&mut scenario, USER1);
        {
            let mut pool = ts::take_shared<StakingPool>(&scenario);
            let coin = ts::take_from_sender<Coin<MOCK_SUI>>(&scenario);
            let clock = ts::take_shared<Clock>(&scenario);
            
            staking::stake(&mut pool, coin, &clock, ts::ctx(&mut scenario));
            
            ts::return_shared(pool);
            ts::return_shared(clock);
        };

        // Verify staking position created
        ts::next_tx(&mut scenario, USER1);
        {
            let pool = ts::take_shared<StakingPool>(&scenario);
            let (total_staked, _, _, _, _, _) = staking::get_pool_stats(&pool);
            assert!(total_staked == 10_000_000_000, 0);
            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    // Test disabled: Requires Walrus Blob object which needs storage resources
    // TODO: Re-enable when proper test infrastructure for Walrus Blob is available
    // #[test]
    // fun test_advertiser_can_submit_ad() { ... }

    // Test disabled: Requires Walrus Blob object which needs storage resources
    // TODO: Re-enable when proper test infrastructure for Walrus Blob is available
    // #[test]
    // fun test_end_to_end_flow() { ... }

    #[test]
    fun test_treasury_operations() {
        let mut scenario = ts::begin(ADMIN);
        setup_system(&mut scenario);
        
        // Mint MOCK_SUI for admin
        mint_sui_for_testing(&mut scenario, ADMIN, 100_000_000_000); // 100 MOCK_SUI

        // Admin deposits yield
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury_obj = ts::take_shared<Treasury>(&scenario);
            let coin = ts::take_from_sender<Coin<MOCK_SUI>>(&scenario);
            
            treasury::deposit_yield(&mut treasury_obj, coin, ts::ctx(&mut scenario));
            
            ts::return_shared(treasury_obj);
        };

        // Verify yield was deposited
        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury_obj = ts::take_shared<Treasury>(&scenario);
            let yield_reserve = treasury::get_yield_reserve(&treasury_obj);
            assert!(yield_reserve == 100_000_000_000, 0);
            ts::return_shared(treasury_obj);
        };

        ts::end(scenario);
    }
}
