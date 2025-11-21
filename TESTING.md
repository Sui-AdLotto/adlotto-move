# Testing AdLotto with MockSUI

## Overview

The AdLotto smart contracts support testing with MockSUI, a test token that mimics SUI's behavior.

## MockSUI Module

The `mock_sui.move` module provides a test token with the following features:

- Same decimals as SUI (9)
- Can be minted freely for testing
- Can be burned
- Fully compatible with Coin<T> generic functions

## Setup for Testing

### 1. Deploy MockSUI

```bash
sui client publish --gas-budget 100000000
```

After deployment, note the `TreasuryCap<MOCK_SUI>` object ID.

### 2. Mint MockSUI Tokens

```bash
# Mint 1000 MOCK_SUI to your address
sui client call \
  --package <PACKAGE_ID> \
  --module mock_sui \
  --function mint_and_transfer \
  --args <TREASURY_CAP_ID> 1000000000000 <YOUR_ADDRESS> \
  --gas-budget 10000000
```

## Testing Workflows

### For Advertisers

1. **Mint MockSUI** for your advertiser wallet
2. **Submit a sealed ad**:
   ```bash
   sui client call \
     --package <PACKAGE_ID> \
     --module ad_entry \
     --function submit_sealed_ad \
     --args <AD_REGISTRY_ID> <BLOB_ID> <MOCK_SUI_COIN> <CLOCK_ID> \
     --gas-budget 10000000
   ```

### For Users (Stakers)

1. **Mint MockSUI** for your user wallet
2. **Stake tokens**:
   ```bash
   sui client call \
     --package <PACKAGE_ID> \
     --module staking \
     --function stake \
     --args <STAKING_POOL_ID> <MOCK_SUI_COIN> <CLOCK_ID> \
     --gas-budget 10000000
   ```

3. **Check your staking position** - you'll receive a StakingPosition NFT

### For Admin

1. **Start a new epoch**:
   ```bash
   sui client call \
     --package <PACKAGE_ID> \
     --module lottery \
     --function start_new_epoch \
     --args <LOTTERY_CONFIG_ID> <AD_REGISTRY_ID> <CLOCK_ID> \
     --gas-budget 10000000
   ```

2. **Fund yield reserves**:
   ```bash
   sui client call \
     --package <PACKAGE_ID> \
     --module treasury \
     --function deposit_yield \
     --args <TREASURY_ID> <MOCK_SUI_COIN> \
     --gas-budget 10000000
   ```

## Integration Testing Script Example

Here's a TypeScript example for integration testing:

```typescript
import { SuiClient } from '@mysten/sui.js/client';
import { TransactionBlock } from '@mysten/sui.js/transactions';

async function setupTestEnvironment() {
  const client = new SuiClient({ url: 'http://localhost:9000' });
  
  // 1. Mint MockSUI for test users
  const tx = new TransactionBlock();
  tx.moveCall({
    target: `${packageId}::mock_sui::mint_and_transfer`,
    arguments: [
      tx.object(treasuryCapId),
      tx.pure(10_000_000_000), // 10 MOCK_SUI
      tx.pure(userAddress)
    ]
  });
  
  await client.signAndExecuteTransactionBlock({
    signer: keypair,
    transactionBlock: tx
  });
  
  // 2. Submit ad
  // 3. Stake tokens
  // 4. Vote
  // etc.
}
```

## Manual Testing Checklist

- [ ] Deploy contracts
- [ ] Mint MockSUI for advertiser
- [ ] Submit sealed ad
- [ ] Verify ad appears in registry
- [ ] Mint MockSUI for users
- [ ] Users stake tokens
- [ ] Start epoch
- [ ] Users vote on ads
- [ ] Finalize epoch
- [ ] Verify winner is determined
- [ ] Unseal winner ad
- [ ] Claim rewards

## Differences from Production

When using MockSUI for testing:

- **No real value** - MockSUI has no economic value
- **Unlimited supply** - Can mint as much as needed
- **Same interfaces** - All contract functions work identically
- **Production ready** - Once tested, switch to real SUI for deployment

## Switching to Production SUI

The contracts are already configured to use SUI. For production:

1. Deploy to mainnet/testnet
2. Use real SUI instead of MockSUI
3. All functions work the same way
4. Real economic incentives apply

## Common Issues

### Issue: "Insufficient funds"
**Solution**: Mint more MockSUI using the treasury cap

### Issue: "Invalid stake amount"
**Solution**: Check minimum stake requirements (1 SUI for ads, 0.1 SUI for staking)

### Issue: "Ad not active"
**Solution**: Ensure ad was submitted with sufficient stake and hasn't been unstaked

## Advanced Testing

### Testing Yield Distribution

```bash
# 1. Admin adds yield to pool
sui client call --package <ID> --module treasury --function deposit_yield \
  --args <TREASURY> <LARGE_MOCK_SUI_AMOUNT> --gas-budget 10000000

# 2. Wait or simulate time passing
# 3. User claims rewards
sui client call --package <ID> --module staking --function claim_rewards \
  --args <POOL> <POSITION> <CLOCK> --gas-budget 10000000
```

### Testing Epoch Lifecycle

```bash
# 1. Start epoch
# 2. Multiple users vote
# 3. Fast-forward time (on local testnet)
# 4. Finalize epoch
# 5. Verify winner
# 6. Unseal ad
```

## Testing Best Practices

1. **Use separate wallets** for different roles (admin, advertiser, users)
2. **Test edge cases** (minimum stakes, zero votes, tie votes)
3. **Verify events** are emitted correctly
4. **Check state changes** after each transaction
5. **Test error conditions** (insufficient funds, wrong permissions)

## Automated Test Suite

While the built-in Move tests have some framework compatibility issues, you can create integration tests using:

- **Sui TypeScript SDK** for end-to-end testing
- **Local Sui network** for fast iteration
- **MockSUI** for unlimited test tokens

Example test structure:

```typescript
describe('AdLotto Integration Tests', () => {
  beforeAll(async () => {
    // Setup: deploy contracts, mint tokens
  });
  
  it('should allow advertiser to submit ad', async () => {
    // Test ad submission
  });
  
  it('should allow users to stake', async () => {
    // Test staking
  });
  
  it('should run complete epoch cycle', async () => {
    // Test full lottery cycle
  });
});
```

## Support

For issues with testing, check:
- Sui framework version compatibility
- Gas budget limits
- Object ownership and sharing
- Transaction block construction
