# AdLotto - Decentralized Advertising Lottery Platform

A decentralized advertising lottery platform built on **Sui blockchain** using **Walrus Protocol** for storage and **Seal** for encryption.

## Overview

AdLotto allows advertisers to submit sealed (encrypted) advertisements and stake SUI tokens to participate in daily lotteries. Users stake tokens to earn passive yield (~8% APY) and can vote on advertisements. The winning ad is unsealed and displayed to all participants.

## Core Features

### For Advertisers
- Store **Sealed Ads** on Walrus (using Blob ID) + Stake SUI
- Ads automatically enter every subsequent daily lottery
- Winner ad is unsealed for all participants
- Zero-loss mechanism - stake remains safe

### For Users
- Stake SUI tokens for passive yield (~8% APY)
- View unsealed daily ads
- Vote on ad quality
- Earn voting incentives

## Smart Contract Architecture

### Modules

#### 1. **Advertisement Module** (`ad_entry.move`)
Handles advertiser interactions and persistent ad management.

**Key Functions:**
- `submit_sealed_ad()` - Submit Walrus Blob ID + stake
- `unstake_ad()` - Withdraw stake and exit lottery
- `get_ad_details()` - View advertisement information

**Key Structs:**
- `Advertisement` - Individual ad with sealed blob ID, stake, and status
- `AdRegistry` - Registry of all active ads

#### 2. **Staking Module** (`staking.move`)
Manages user staking positions and yield generation.

**Key Functions:**
- `stake()` - Stake SUI tokens
- `unstake()` - Withdraw principal + yield
- `claim_rewards()` - Claim accumulated yield without unstaking
- `calculate_yield()` - Calculate pending rewards

**Key Structs:**
- `StakingPosition` - User's staking position NFT
- `StakingPool` - Global staking pool

#### 3. **Lottery Module** (`lottery.move`)
Manages epoch-based lottery mechanics and unsealing.

**Key Functions:**
- `start_new_epoch()` - Initialize new 24-hour lottery epoch
- `finalize_epoch()` - Calculate winner and distribute rewards
- `unseal_winner_ad()` - Reveal winning ad content

**Key Structs:**
- `LotteryEpoch` - Individual lottery epoch data
- `LotteryConfig` - Global lottery configuration

#### 4. **Voting Module** (`voting.move`)
Handles user voting on advertisements.

**Key Functions:**
- `cast_vote()` - Vote for an ad (requires staking position)
- `claim_voting_reward()` - Claim rewards for voting participation
- `distribute_voting_rewards()` - Admin function to set rewards

**Key Structs:**
- `Vote` - Individual vote NFT
- `VotingRecord` - Epoch voting statistics

#### 5. **Treasury Module** (`treasury.move`)
Manages platform funds, yield distribution, and fee collection.

**Key Functions:**
- `deposit_yield()` - Add funds to yield reserve
- `fund_voting_rewards()` - Add funds for voting incentives
- `withdraw_fees()` - Admin withdraws platform fees

**Key Struct:**
- `Treasury` - Platform treasury with separated balances

## System Flow

### Epoch Lifecycle

```
1. Epoch Start (00:00 UTC)
   - New LotteryEpoch created
   - All active ads automatically enter
   - Users can submit new ads

2. During Epoch (24 hours)
   - Users view current leading ad
   - Users vote on ad quality
   - Staking yield accrues in real-time

3. Epoch End (23:59 UTC)
   - Winner determined by highest votes
   - Winner ad permanently unsealed
   - Yield distributed to stakers
   - Voting rewards distributed
   - Losing ads remain active for next epoch

4. New Epoch Begins (Cycle Repeats)
```

### Fee Structure

- **Platform Fee**: 2% of all yield generated
- **Advertiser Stake**: Remains locked while active, no penalty for losing
- **Staking APY**: ~8% (800 basis points)
- **Voting Weight**: 1:1 with staked amount

## Deployment

### Build the Package

```bash
sui move build
```

### Publish to Network

```bash
sui client publish --gas-budget 100000000
```

### Initialization

The `init` function automatically creates:
- AdRegistry (min stake: 1 SUI, max 1000 ads/epoch)
- StakingPool (8% APY, 0.1-100 SUI stake range)
- LotteryConfig (1:1 voting weight, 2% platform fee)
- Treasury

## Integration with Walrus & Seal

### Advertiser Workflow

```typescript
// 1. Upload and seal advertisement
const { blob_id, encryption_metadata } = await upload_and_seal_ad(file);

// 2. Submit to smart contract
await contract.submit_sealed_ad(registry, blob_id, stake_coin, clock);
```

### User Workflow

```typescript
// 1. Fetch winning ad blob ID from events
const winner_event = await get_epoch_finalized_event(epoch);

// 2. Fetch and unseal from Walrus
const ad_content = await get_unsealed_ad_content(winner_event.winner_blob_id);
```

## Events

The contract emits comprehensive events for frontend integration:

- `AdSealed` - New ad submitted
- `AdUnstaked` - Ad withdrawn
- `AdWon` - Ad won lottery
- `Staked` - User staked tokens
- `Unstaked` - User withdrew stake
- `RewardsClaimed` - Rewards claimed
- `VoteCast` - Vote recorded
- `EpochStarted` - New epoch begins
- `EpochFinalized` - Epoch ended with winner
- `WinnerUnsealed` - Winner ad revealed

## Security Considerations

1. **Blob Availability**: Ensure sealed_blob_id points to valid, paid Walrus blob
2. **Unsealing**: Decryption key managed via Seal for winner propagation
3. **Gas Limits**: Max ads per epoch prevents gas exhaustion
4. **Zero-Loss**: User principal always safe in staking pool

## Configuration

Default parameters (can be modified during deployment):

```move
// AdRegistry
min_ad_stake: 1_000_000_000,     // 1 SUI
max_ads_per_epoch: 1000,

// StakingPool
apy_rate: 800,                   // 8% APY
min_stake: 100_000_000,          // 0.1 SUI
max_stake: 100_000_000_000,      // 100 SUI

// LotteryConfig
voting_weight_per_stake: 10000,  // 1:1 (basis points)
platform_fee_bps: 200,           // 2%
epoch_duration: 86400000,        // 24 hours (milliseconds)
```

## Testing

The package includes test-only initialization functions for each module:

```bash
sui move test
```

## License

MIT

## Contact

For questions or support, please open an issue in the repository.
