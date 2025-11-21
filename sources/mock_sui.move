module adlotto::mock_sui {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::tx_context::{TxContext};
    use sui::transfer;

    /// Mock SUI token for testing
    public struct MOCK_SUI has drop {}

    /// Initialize the mock SUI token with a treasury cap
    fun init(witness: MOCK_SUI, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            witness,
            9, // decimals (same as SUI)
            b"MOCK_SUI",
            b"Mock SUI",
            b"Mock SUI token for testing AdLotto",
            std::option::none(),
            ctx
        );
        
        transfer::public_freeze_object(metadata);
        transfer::public_share_object(treasury);
    }

    /// Mint mock SUI tokens for testing
    public fun mint(
        treasury: &mut TreasuryCap<MOCK_SUI>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<MOCK_SUI> {
        coin::mint(treasury, amount, ctx)
    }

    /// Mint and transfer to recipient
    public entry fun mint_and_transfer(
        treasury: &mut TreasuryCap<MOCK_SUI>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let coin = coin::mint(treasury, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }

    /// Burn mock SUI tokens
    public fun burn(
        treasury: &mut TreasuryCap<MOCK_SUI>,
        coin: Coin<MOCK_SUI>
    ) {
        coin::burn(treasury, coin);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(MOCK_SUI {}, ctx);
    }
}
