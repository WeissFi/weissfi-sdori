
/// Module: sdori
module sdori::sdori;

// === Imports ===
use sui::coin_registry;
use sui::balance::{Self, Balance, Supply};
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use weissfi::dori::DORI;
use weissfi::governance_admin::AdminCap;

// === Errors ===
const EWrongPackageVersion: u64 = 0;
const EZeroAmount: u64 = 1;
const EInsufficientBalance: u64 = 2;
const ENotUpgrade: u64 = 3;

// === Constants ===
const VERSION: u64 = 1; // Version for package updates
const PRECISION: u256 = 1_000_000_000; // 1e9 for ratio calculations

// === Events ===
public struct DepositEvent has copy, drop {
    user: address,
    dori_amount: u64,
    sdori_amount: u64,
    exchange_rate: u64,
}

public struct WithdrawEvent has copy, drop {
    user: address,
    sdori_amount: u64,
    dori_amount: u64,
    exchange_rate: u64,
}

public struct YieldDistributedEvent has copy, drop {
    amount: u64,
    new_exchange_rate: u64,
    total_dori: u64,
    total_sdori: u64,
}

// === Structs ===
// SDORI type coin
public struct SDORI has drop {}
/// Savings vault that holds DORI and mints sDORI
public struct SavingsVault has key {
    id: UID,
    version: u64,
    /// Total DORI in the vault (principal + yield)
    dori_balance: Balance<DORI>,
    /// Supply of sDORI tokens
    sdori_supply: Supply<SDORI>,
    /// Total yield distributed (for tracking/stats)
    total_yield_distributed: u64,
    /// Last distribution timestamp
    last_distribution_timestamp: u64,
}

// === Private Functions ===
fun init(witness: SDORI, ctx: &mut TxContext) {

	let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
			witness,
			9,
			b"sDORI".to_string(),
			b"Savings DORI".to_string(),
			b"Yield-bearing DORI from Weiss.Finance protocol. Stake DORI to earn protocol yield.".to_string(),
			b"https://purple-efficient-armadillo-520.mypinata.cloud/ipfs/bafkreickahkpchfakjsaq4rdnugq25lrcbdgfz6nawswlr3mlmhdwlyiju".to_string(),
			ctx,
	);
    let metadata_cap = builder.finalize(ctx);
    transfer::public_freeze_object(metadata_cap);
    

    // Create savings vault
    let vault = SavingsVault {
        id: object::new(ctx),
        version: VERSION,
        dori_balance: balance::zero<DORI>(),
        sdori_supply: coin::treasury_into_supply(treasury_cap),
        total_yield_distributed: 0,
        last_distribution_timestamp: 0,
    };

    transfer::share_object(vault);

	//transfer::public_transfer(treasury_cap, ctx.sender());

}


// === Public Entry Functions ===
/// Deposit DORI and receive sDORI at current exchange rate
public fun deposit(
    vault: &mut SavingsVault,
    dori: Coin<DORI>,
    ctx: &mut TxContext
): Coin<SDORI> {
    assert!(vault.version == VERSION, EWrongPackageVersion);

    let dori_amount = dori.value();
    assert!(dori_amount > 0, EZeroAmount);

    // Calculate sDORI to mint based on current exchange rate
    let sdori_to_mint = dori_to_sdori(vault, dori_amount);

    // Add DORI to vault
    balance::join(&mut vault.dori_balance, coin::into_balance(dori));

    // Mint sDORI to user
    let sdori = coin::from_balance(
        balance::increase_supply(&mut vault.sdori_supply, sdori_to_mint),
        ctx
    );

    // Emit event
    sui::event::emit(DepositEvent {
        user: ctx.sender(),
        dori_amount,
        sdori_amount: sdori_to_mint,
        exchange_rate: get_exchange_rate(vault),
    });

    sdori
    //transfer::public_transfer(sdori, ctx.sender());
}

/// Burn sDORI and receive DORI at current exchange rate (with accrued yield)
public fun withdraw(
    vault: &mut SavingsVault,
    sdori: Coin<SDORI>,
    ctx: &mut TxContext
): Coin<DORI> {
    assert!(vault.version == VERSION, EWrongPackageVersion);

    let sdori_amount = coin::value(&sdori);
    assert!(sdori_amount > 0, EZeroAmount);

    // Calculate DORI to return based on current exchange rate
    let dori_to_return = sdori_to_dori(vault, sdori_amount);

    assert!(balance::value(&vault.dori_balance) >= dori_to_return, EInsufficientBalance);

    let exchange_rate = get_exchange_rate(vault);

    // Burn sDORI
    balance::decrease_supply(&mut vault.sdori_supply, coin::into_balance(sdori));

    // Return DORI to user
    let dori = coin::from_balance(
        balance::split(&mut vault.dori_balance, dori_to_return),
        ctx
    );

    // Emit event
    sui::event::emit(WithdrawEvent {
        user: ctx.sender(),
        sdori_amount,
        dori_amount: dori_to_return,
        exchange_rate,
    });

    dori
    //transfer::public_transfer(dori, ctx.sender());
}


/// Distribute yield to the savings vault (called by protocol)
/// This increases the exchange rate of sDORI → DORI
public fun distribute_yield(
    vault: &mut SavingsVault,
    yield: Coin<DORI>,
    clock: &Clock,
) {
    // assert!(vault.version == VERSION, EWrongPackageVersion);
    let yield_amount = yield.value();
    // Check if yield amount > 0
    assert!(yield_amount > 0, EZeroAmount);

    // Add yield to vault balance
    balance::join(&mut vault.dori_balance, coin::into_balance(yield));

    // Track stats
    vault.total_yield_distributed = vault.total_yield_distributed + yield_amount;
    vault.last_distribution_timestamp = clock.timestamp_ms();

    // Emit event
    sui::event::emit(YieldDistributedEvent {
        amount: yield_amount,
        new_exchange_rate: get_exchange_rate(vault),
        total_dori: balance::value(&vault.dori_balance),
        total_sdori: balance::supply_value(&vault.sdori_supply),
    });
    
}

// === View Functions ===
/// Get current exchange rate (how much DORI you get for 1 sDORI)
/// Returns the rate scaled by 1e9
/// Example: 1_100_000_000 means 1 sDORI = 1.1 DORI
public fun get_exchange_rate(vault: &SavingsVault): u64 {
    let total_dori = balance::value(&vault.dori_balance);
    let total_sdori = balance::supply_value(&vault.sdori_supply);

    if (total_sdori == 0) {
        (PRECISION as u64) // 1:1 ratio initially
    } else {
        // exchange_rate = (total_dori / total_sdori) * PRECISION
        (((total_dori as u256) * PRECISION / (total_sdori as u256)) as u64)
    }
}
/// Convert DORI amount to sDORI amount at current rate
public fun dori_to_sdori(vault: &SavingsVault, dori_amount: u64): u64 {
    let total_dori = balance::value(&vault.dori_balance);
    let total_sdori = balance::supply_value(&vault.sdori_supply);

    if (total_sdori == 0 || total_dori == 0) {
        // First deposit: 1:1 ratio
        dori_amount
    } else {
        // sdori_amount = dori_amount * total_sdori / total_dori
        (((dori_amount as u256) * (total_sdori as u256) / (total_dori as u256)) as u64)
    }
}
/// Convert sDORI amount to DORI amount at current rate
public fun sdori_to_dori(vault: &SavingsVault, sdori_amount: u64): u64 {
    let total_dori = balance::value(&vault.dori_balance);
    let total_sdori = balance::supply_value(&vault.sdori_supply);

    if (total_sdori == 0) {
        0
    } else {
        // dori_amount = sdori_amount * total_dori / total_sdori
        (((sdori_amount as u256) * (total_dori as u256) / (total_sdori as u256)) as u64)
    }
}
/// Calculate current APY based on recent yield
/// Returns APY in basis points (e.g., 500 = 5% APY)
/// Note: This is a simple estimation, actual APY varies based on protocol usage
public fun get_estimated_apy(
    vault: &SavingsVault,
    clock: &Clock,
    lookback_period_ms: u64, // e.g., 7 days = 604_800_000 ms
): u64 {
    let current_time = clock.timestamp_ms();
    let time_since_last_distribution = current_time - vault.last_distribution_timestamp;

    // If no recent distribution, return 0
    if (time_since_last_distribution > lookback_period_ms || vault.total_yield_distributed == 0) {
        return 0
    };

    // Simple APY calculation based on exchange rate growth
    // APY ≈ ((exchange_rate - 1.0) / time_period) * 1_year
    let exchange_rate = get_exchange_rate(vault);

    if (exchange_rate <= (PRECISION as u64)) {
        return 0
    };

    // Calculate yield percentage
    let yield_pct = exchange_rate - (PRECISION as u64);

    // Annualize it (very rough estimation)
    let one_year_ms = 31_536_000_000u64; // 365 days in ms
    let annualized = (yield_pct as u256) * (one_year_ms as u256) / (time_since_last_distribution as u256);

    // Convert to basis points (10000 bps = 100%)
    ((annualized * 10000 / PRECISION) as u64)
}

// Migrate the module to a new version
entry fun migrate(_admin: &mut AdminCap, g: &mut SavingsVault) {
    assert!(g.version < VERSION, ENotUpgrade);
    g.version = VERSION;
}