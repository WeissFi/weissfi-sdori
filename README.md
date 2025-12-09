# sDORI - Savings DORI Vault

A yield-bearing savings vault for DORI tokens on the Sui blockchain. Users deposit DORI and receive sDORI tokens that automatically accrue yield over time.

## Overview

The sDORI vault implements a **wrapper token mechanism** (similar to wstETH or cTokens) where:
- Users deposit DORI tokens and receive sDORI (savings DORI)
- **Your sDORI balance stays constant**, but the exchange rate increases as yield accrues
- Protocol yield is distributed to the vault, increasing the DORI/sDORI exchange rate
- Users can withdraw their sDORI at any time to receive their principal + accrued yield

**Important**: This is NOT a rebasing token. Your sDORI balance doesn't change - instead, each sDORI becomes worth more DORI over time.

### Rebasing vs Non-Rebasing (Wrapper) Tokens

| Feature | Rebasing Token (e.g., stETH) | Wrapper Token (sDORI) |
|---------|------------------------------|------------------------|
| **Balance Change** | ✅ Your balance increases automatically | ❌ Your balance stays the same |
| **Price Change** | ❌ Price stays at 1:1 | ✅ Exchange rate increases |
| **Example** | 100 tokens → 110 tokens (same value each) | 100 tokens → 100 tokens (each worth 1.1x more) |
| **DeFi Integration** | ⚠️ Complex (balance changes) | ✅ Easier (standard token) |

## Key Features

- **Automatic Yield Accrual**: Yield is distributed to all sDORI holders proportionally
- **No Lock-up Period**: Users can withdraw at any time
- **Fair Distribution**: New depositors receive sDORI based on current exchange rate
- **Composable**: sDORI tokens can be transferred and used in other DeFi protocols
- **Transparent**: All exchange rates and yields are on-chain and verifiable

## How It Works

### Exchange Rate Mechanism

The vault maintains an exchange rate between DORI and sDORI:

```
Exchange Rate = Total DORI in Vault / Total sDORI Supply
```

**Example Flow:**

1. **Initial State**: Vault is empty
   - Exchange rate: 1:1

2. **Bob deposits 100 DORI**:
   - Receives: 100 sDORI (at 1:1 rate)
   - Vault: 100 DORI, 100 sDORI

3. **Protocol distributes 10 DORI yield**:
   - Vault: 110 DORI, 100 sDORI
   - New exchange rate: 1.1 DORI per sDORI

4. **Alice deposits 110 DORI**:
   - Receives: 100 sDORI (at 1.1:1 rate)
   - Vault: 220 DORI, 200 sDORI

5. **Bob withdraws 100 sDORI**:
   - Receives: 110 DORI (100 principal + 10 yield)
   - Vault: 110 DORI, 100 sDORI

6. **Alice withdraws 100 sDORI**:
   - Receives: 110 DORI (her original deposit)
   - Vault: 0 DORI, 0 sDORI

## Smart Contract Functions

### Public Functions

#### `deposit(vault: &mut SavingsVault, dori: Coin<DORI>, ctx: &mut TxContext): Coin<SDORI>`
Deposit DORI tokens and receive sDORI at the current exchange rate.

#### `withdraw(vault: &mut SavingsVault, sdori: Coin<SDORI>, ctx: &mut TxContext): Coin<DORI>`
Burn sDORI tokens and receive DORI at the current exchange rate (including accrued yield).

#### `distribute_yield(vault: &mut SavingsVault, yield: Coin<DORI>, clock: &Clock)`
Distribute yield to the vault (increases exchange rate). Called by the protocol.

### View Functions

#### `get_exchange_rate(vault: &SavingsVault): u64`
Returns the current DORI/sDORI exchange rate (scaled by 1e9).
- Example: `1_100_000_000` means 1 sDORI = 1.1 DORI

#### `dori_to_sdori(vault: &SavingsVault, dori_amount: u64): u64`
Calculate how much sDORI you would receive for a given DORI amount.

#### `sdori_to_dori(vault: &SavingsVault, sdori_amount: u64): u64`
Calculate how much DORI you would receive for a given sDORI amount.

#### `get_estimated_apy(vault: &SavingsVault, clock: &Clock, lookback_period_ms: u64): u64`
Get estimated APY based on recent yield distributions (in basis points).

## Installation & Testing

### Prerequisites

- [Sui CLI](https://docs.sui.io/build/install) installed
- Move compiler

### Clone and Build

```bash
git clone <repository-url>
cd sdori
sui move build
```

### Run Tests

```bash
sui move test
```

### Test Coverage

The project includes comprehensive test coverage:

**Unit Tests**:
- ✅ Basic deposit functionality
- ✅ Basic withdraw functionality
- ✅ Yield distribution

**Scenario Tests**:
- ✅ Multiple users sharing yield proportionally
- ✅ New users joining after yield distribution
- ✅ Partial withdrawals
- ✅ Multiple yield distributions (compound yield)

**Error Tests**:
- ✅ Zero amount deposits/withdrawals fail
- ✅ Insufficient balance withdrawals fail
- ✅ Zero yield distribution fails

**Edge Cases**:
- ✅ Rounding with small amounts
- ✅ Compound yield calculations

Total: **12 tests, 100% pass rate**

## Deployment

### Testnet Deployment

```bash
sui client publish --gas-budget 100000000
```

### Mainnet Deployment

⚠️ **Before deploying to mainnet:**
1. Complete a professional security audit
2. Test thoroughly on testnet with real users
3. Verify gas costs and transaction limits
4. Prepare incident response procedures
5. Set up monitoring and alerts

## Security Considerations

### Implemented Security Features

- ✅ Zero amount checks on all operations
- ✅ Insufficient balance checks
- ✅ Version control for upgrades
- ✅ Comprehensive test coverage
- ✅ Integer overflow protection (via Move's type system)

### Recommended Before Production

- [ ] Professional security audit by reputable firm
- [ ] Economic simulation and stress testing
- [ ] Admin key management procedures
- [ ] Emergency pause mechanism (if needed)
- [ ] Bug bounty program

## Architecture

```
┌─────────────────────────────────────────┐
│         SavingsVault                    │
├─────────────────────────────────────────┤
│ - dori_balance: Balance<DORI>          │
│ - sdori_supply: Supply<SDORI>          │
│ - total_yield_distributed: u64         │
│ - last_distribution_timestamp: u64     │
└─────────────────────────────────────────┘
           │
           │ Exchange Rate = dori_balance / sdori_supply
           │
    ┌──────┴──────┐
    │             │
┌───▼───┐   ┌────▼────┐
│ DORI  │   │  sDORI  │
│ Token │   │  Token  │
└───────┘   └─────────┘
```

## Constants

- `PRECISION`: 1e9 (used for exchange rate calculations)
- `VERSION`: 1 (current package version)

## Error Codes

- `EWrongPackageVersion` (0): Package version mismatch
- `EZeroAmount` (1): Amount cannot be zero
- `EInsufficientBalance` (2): Vault has insufficient balance
- `ENotUpgrade` (3): Not an upgrade (version error)

## Events

### `DepositEvent`
```move
{
    user: address,
    dori_amount: u64,
    sdori_amount: u64,
    exchange_rate: u64,
}
```

### `WithdrawEvent`
```move
{
    user: address,
    sdori_amount: u64,
    dori_amount: u64,
    exchange_rate: u64,
}
```

### `YieldDistributedEvent`
```move
{
    amount: u64,
    new_exchange_rate: u64,
    total_dori: u64,
    total_sdori: u64,
}
```

## FAQ

**Q: Can I lose money by depositing?**
A: The exchange rate only increases (never decreases), so you'll always be able to withdraw at least what you deposited, plus any accrued yield.

**Q: What happens if I'm the first depositor?**
A: You receive sDORI at a 1:1 rate initially. As yield is distributed, the rate increases.

**Q: Can I transfer my sDORI to someone else?**
A: Yes! sDORI are standard Sui Coin objects and can be transferred freely.

**Q: How is yield distributed?**
A: The protocol deposits yield DORI into the vault, which increases the exchange rate proportionally for all sDORI holders.

**Q: Is there a deposit or withdrawal fee?**
A: No fees are charged by the vault contract. Only standard Sui network gas fees apply.

## Contact & Support

contact@weiss.finance

## Audit Status

⚠️ **This contract has not been audited.** Use at your own risk. 

---

Built with ❤️ on Sui
