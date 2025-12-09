
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
			b"https://weissfi.s3.eu-west-3.amazonaws.com/sdori.svg".to_string(),
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


// === Public Functions ===
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



// === Test Functions ===
// #[test_only]
// use std::debug;
#[test_only]
use sui::test_scenario::{Self, Scenario};
#[test_only]
use sui::clock;
// #[test_only]
// use weissfi::vault_registry::{VaultRegistry, create_vault_registry};

#[test_only]
const ADMIN :address = @0xCAFE;
#[test_only]
const BOB :address = @0xC;

#[test_only]
fun init_state(scenario: &mut Scenario){
   
	let (builder, treasury_cap) = coin_registry::new_currency_with_otw(
			SDORI{},
			9,
			b"sDORI".to_string(),
			b"Savings DORI".to_string(),
			b"Yield-bearing DORI from Weiss.Finance protocol. Stake DORI to earn protocol yield.".to_string(),
			b"https://purple-efficient-armadillo-520.mypinata.cloud/ipfs/bafkreickahkpchfakjsaq4rdnugq25lrcbdgfz6nawswlr3mlmhdwlyiju".to_string(),
			scenario.ctx(),
	);
    let metadata_cap = builder.finalize(scenario.ctx());
    transfer::public_freeze_object(metadata_cap);

    // Create savings vault
    let vault = SavingsVault {
        id: object::new(scenario.ctx()),
        version: VERSION,
        dori_balance: balance::zero<DORI>(),
        sdori_supply: coin::treasury_into_supply(treasury_cap),
        total_yield_distributed: 0,
        last_distribution_timestamp: 0,
    };
    transfer::share_object(vault);

}
#[test_only]
fun deposit_helper(scenario: &mut Scenario, user: address, amount: u64){
    scenario.next_tx(user);
    {
        let mut saving_vault = scenario.take_shared<SavingsVault>();
        let dori= coin::mint_for_testing<DORI>(amount, scenario.ctx());
        let sdori = deposit(&mut saving_vault, dori, scenario.ctx());
        transfer::public_transfer(sdori, user);
        transfer::share_object(saving_vault);
    }
     
}
#[test_only]
fun distribute_yield_helper(scenario: &mut Scenario, clock: &Clock, amount: u64){
    scenario.next_tx(ADMIN);
    {
        let mut saving_vault = scenario.take_shared<SavingsVault>();
        let dori= coin::mint_for_testing<DORI>(amount, scenario.ctx());
        distribute_yield(&mut saving_vault, dori, clock);
        transfer::share_object(saving_vault);
    };
}
// Test success deposit in saving vault
#[test]
fun test_deposit(){
    let mut scenario = test_scenario::begin(ADMIN);

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    scenario.next_tx(BOB);
    {
        let mut saving_vault = scenario.take_shared<SavingsVault>();
        let dori= coin::mint_for_testing<DORI>(100, scenario.ctx());
        let sdori = deposit(&mut saving_vault, dori, scenario.ctx());
        
        assert!(sdori.value() == 100);
        assert!(saving_vault.dori_balance.value() == 100);
        assert!(saving_vault.sdori_supply.value() == 100);
        assert!(saving_vault.total_yield_distributed == 0);
        assert!(saving_vault.last_distribution_timestamp == 0);
        
        transfer::public_transfer(sdori, BOB);
        transfer::share_object(saving_vault);
    };

    
    scenario.end();
}
// Test success withdraw in saving vault
#[test]
fun test_withdraw(){
    let mut scenario = test_scenario::begin(ADMIN);

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };
    // Bob deposit 
    {
        deposit_helper(&mut scenario, BOB, 100);
    };
    // Bob withdraw 
    scenario.next_tx(BOB);
    {
        let mut saving_vault = scenario.take_shared<SavingsVault>();
        let sdori = scenario.take_from_sender<Coin<SDORI>>();
        let dori = withdraw(&mut saving_vault, sdori, scenario.ctx());
        assert!(dori.value() == 100);
        assert!(saving_vault.sdori_supply.value() == 0);
        assert!(saving_vault.dori_balance.value() == 0);
        assert!(saving_vault.total_yield_distributed == 0);
        assert!(saving_vault.last_distribution_timestamp == 0);

        transfer::public_transfer(dori, BOB);
        transfer::share_object(saving_vault);
    };    

    scenario.end();
}

// Test yield deposit in saving vault
#[test]
fun test_yield_scenario(){
    let mut scenario = test_scenario::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // ADMIN distribute yield
    clock.increment_for_testing(5000);
    scenario.next_tx(ADMIN);
    {
        let mut saving_vault = scenario.take_shared<SavingsVault>();
        let dori= coin::mint_for_testing<DORI>(1000, scenario.ctx());
        distribute_yield(&mut saving_vault, dori, &clock);

        assert!(saving_vault.sdori_supply.value() == 0);
        assert!(saving_vault.dori_balance.value() == 1000);
        assert!(saving_vault.total_yield_distributed == 1000);
        assert!(saving_vault.last_distribution_timestamp == 5000);

        transfer::share_object(saving_vault);
    };

    clock.destroy_for_testing();
    scenario.end();
}

// Test multiple users sharing yield proportionally
#[test]
fun test_multiple_users_proportional_yield(){
    let mut scenario = test_scenario::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // BOB deposits 100 DORI
    deposit_helper(&mut scenario, BOB, 100);

    // ALICE deposits 200 DORI
    deposit_helper(&mut scenario, @0xAA, 200);

    // Total in vault: 300 DORI, 300 sDORI (ratio 1:1)

    // ADMIN distributes 30 DORI yield (10% yield)
    distribute_yield_helper(&mut scenario, &clock, 30);

    // Now: 330 DORI, 300 sDORI (ratio 1.1:1)
    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        let rate = get_exchange_rate(&vault);
        assert!(rate == 1_100_000_000); // 1.1 * 1e9
        assert!(vault.total_yield_distributed == 30);
        transfer::share_object(vault);
    };

    // BOB withdraws his 100 sDORI
    scenario.next_tx(BOB);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let sdori = scenario.take_from_sender<Coin<SDORI>>();
        let dori = withdraw(&mut vault, sdori, scenario.ctx());

        // BOB should get 110 DORI (100 sDORI * 1.1 rate)
        assert!(dori.value() == 110);

        transfer::public_transfer(dori, BOB);
        transfer::share_object(vault);
    };

    // ALICE withdraws her 200 sDORI
    scenario.next_tx(@0xAA);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let sdori = scenario.take_from_sender<Coin<SDORI>>();
        let dori = withdraw(&mut vault, sdori, scenario.ctx());

        // ALICE should get 220 DORI (200 sDORI * 1.1 rate)
        assert!(dori.value() == 220);

        transfer::public_transfer(dori, @0xAA);
        transfer::share_object(vault);
    };

    // Vault should be empty now
    scenario.next_tx(ADMIN);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(vault.dori_balance.value() == 0);
        assert!(vault.sdori_supply.value() == 0);
        transfer::share_object(vault);
    };

    clock.destroy_for_testing();
    scenario.end();
}

// Test new user joining after yield distribution (non-1:1 exchange rate)
#[test]
fun test_new_user_joins_after_yield(){
    let mut scenario = test_scenario::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // BOB deposits 100 DORI at 1:1 rate
    deposit_helper(&mut scenario, BOB, 100);

    // ADMIN distributes 10 DORI yield (10% yield)
    distribute_yield_helper(&mut scenario, &clock, 10);

    // Now exchange rate is 1.1:1 (110 DORI / 100 sDORI)
    scenario.next_tx(ADMIN);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(get_exchange_rate(&vault) == 1_100_000_000);
        transfer::share_object(vault);
    };

    // ALICE deposits 110 DORI at the new rate
    scenario.next_tx(@0xAA);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let dori = coin::mint_for_testing<DORI>(110, scenario.ctx());
        let sdori = deposit(&mut vault, dori, scenario.ctx());

        // ALICE should receive 100 sDORI (110 DORI / 1.1 rate)
        // Calculation: sdori = dori_amount * total_sdori / total_dori
        //            = 110 * 100 / 110 = 100
        assert!(sdori.value() == 100);

        transfer::public_transfer(sdori, @0xAA);
        transfer::share_object(vault);
    };

    // Now vault has: 220 DORI, 200 sDORI (still 1.1:1)
    scenario.next_tx(ADMIN);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(vault.dori_balance.value() == 220);
        assert!(vault.sdori_supply.value() == 200);
        assert!(get_exchange_rate(&vault) == 1_100_000_000);
        transfer::share_object(vault);
    };

    // BOB withdraws his 100 sDORI
    scenario.next_tx(BOB);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let sdori = scenario.take_from_sender<Coin<SDORI>>();
        let dori = withdraw(&mut vault, sdori, scenario.ctx());

        // BOB gets 110 DORI (100 sDORI * 1.1 rate) = his 100 + 10 yield
        assert!(dori.value() == 110);

        transfer::public_transfer(dori, BOB);
        transfer::share_object(vault);
    };

    // ALICE withdraws her 100 sDORI
    scenario.next_tx(@0xAA);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let sdori = scenario.take_from_sender<Coin<SDORI>>();
        let dori = withdraw(&mut vault, sdori, scenario.ctx());

        // ALICE gets 110 DORI (100 sDORI * 1.1 rate) = exactly what she deposited
        assert!(dori.value() == 110);

        transfer::public_transfer(dori, @0xAA);
        transfer::share_object(vault);
    };

    // Vault should be empty
    scenario.next_tx(ADMIN);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(vault.dori_balance.value() == 0);
        assert!(vault.sdori_supply.value() == 0);
        transfer::share_object(vault);
    };

    clock.destroy_for_testing();
    scenario.end();
}

// === Error Test Cases ===

// Test deposit with zero amount fails
#[test]
#[expected_failure(abort_code = EZeroAmount)]
fun test_deposit_zero_fails(){
    let mut scenario = test_scenario::begin(ADMIN);

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    scenario.next_tx(BOB);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let dori = coin::mint_for_testing<DORI>(0, scenario.ctx());
        let sdori = deposit(&mut vault, dori, scenario.ctx());

        transfer::public_transfer(sdori, BOB);
        transfer::share_object(vault);
    };

    scenario.end();
}

// Test withdraw with zero amount fails
#[test]
#[expected_failure(abort_code = EZeroAmount)]
fun test_withdraw_zero_fails(){
    let mut scenario = test_scenario::begin(ADMIN);

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    scenario.next_tx(BOB);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let sdori = coin::mint_for_testing<SDORI>(0, scenario.ctx());
        let dori = withdraw(&mut vault, sdori, scenario.ctx());

        transfer::public_transfer(dori, BOB);
        transfer::share_object(vault);
    };

    scenario.end();
}

// Test withdraw exceeding vault balance fails
#[test]
#[expected_failure(abort_code = EInsufficientBalance)]
fun test_withdraw_insufficient_balance(){
    let mut scenario = test_scenario::begin(ADMIN);

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // BOB deposits 100 DORI
    deposit_helper(&mut scenario, BOB, 100);

    // ALICE tries to withdraw with fake sDORI (more than vault has)
    scenario.next_tx(@0xAA);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        // Create fake sDORI that would require more DORI than in vault
        let fake_sdori = coin::mint_for_testing<SDORI>(1000, scenario.ctx());
        let dori = withdraw(&mut vault, fake_sdori, scenario.ctx());

        transfer::public_transfer(dori, @0xAA);
        transfer::share_object(vault);
    };

    scenario.end();
}

// Test distribute zero yield fails
#[test]
#[expected_failure(abort_code = EZeroAmount)]
fun test_distribute_zero_yield_fails(){
    let mut scenario = test_scenario::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    scenario.next_tx(ADMIN);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let zero_yield = coin::mint_for_testing<DORI>(0, scenario.ctx());
        distribute_yield(&mut vault, zero_yield, &clock);

        transfer::share_object(vault);
    };

    clock.destroy_for_testing();
    scenario.end();
}

// === Edge Cases Tests ===

// Test partial withdraw (user withdraws only part of their sDORI)
#[test]
fun test_partial_withdraw(){
    let mut scenario = test_scenario::begin(ADMIN);

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // BOB deposits 100 DORI
    deposit_helper(&mut scenario, BOB, 100);

    // BOB withdraws only 30 sDORI (keeping 70 sDORI)
    scenario.next_tx(BOB);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let mut sdori = scenario.take_from_sender<Coin<SDORI>>();

        // Split to withdraw only 30
        let sdori_to_withdraw = coin::split(&mut sdori, 30, scenario.ctx());
        let dori = withdraw(&mut vault, sdori_to_withdraw, scenario.ctx());

        // Should get 30 DORI back
        assert!(dori.value() == 30);
        // Vault should have 70 DORI remaining
        assert!(vault.dori_balance.value() == 70);
        assert!(vault.sdori_supply.value() == 70);

        transfer::public_transfer(dori, BOB);
        transfer::public_transfer(sdori, BOB); // Return remaining 70 sDORI
        transfer::share_object(vault);
    };

    // BOB withdraws remaining 70 sDORI
    scenario.next_tx(BOB);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let sdori = scenario.take_from_sender<Coin<SDORI>>();
        let dori = withdraw(&mut vault, sdori, scenario.ctx());

        assert!(dori.value() == 70);
        assert!(vault.dori_balance.value() == 0);
        assert!(vault.sdori_supply.value() == 0);

        transfer::public_transfer(dori, BOB);
        transfer::share_object(vault);
    };

    scenario.end();
}

// Test multiple yield distributions (compound yield)
#[test]
fun test_multiple_yield_distributions(){
    let mut scenario = test_scenario::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // BOB deposits 1000 DORI
    deposit_helper(&mut scenario, BOB, 1000);

    // First yield: 100 DORI (10% yield)
    clock.increment_for_testing(1000);
    distribute_yield_helper(&mut scenario, &clock, 100);

    // Check rate: (1100/1000) * 1e9 = 1.1e9
    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(get_exchange_rate(&vault) == 1_100_000_000);
        assert!(vault.total_yield_distributed == 100);
        transfer::share_object(vault);
    };

    // Second yield: 110 DORI (10% on new total of 1100)
    clock.increment_for_testing(1000);
    distribute_yield_helper(&mut scenario, &clock, 110);

    // Check rate: (1210/1000) * 1e9 = 1.21e9
    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(get_exchange_rate(&vault) == 1_210_000_000);
        assert!(vault.total_yield_distributed == 210);
        assert!(vault.last_distribution_timestamp == 2000);
        transfer::share_object(vault);
    };

    // Third yield: 121 DORI (10% on new total of 1210)
    clock.increment_for_testing(1000);
    distribute_yield_helper(&mut scenario, &clock, 121);

    // Check rate: (1331/1000) * 1e9 = 1.331e9
    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(get_exchange_rate(&vault) == 1_331_000_000);
        assert!(vault.total_yield_distributed == 331);
        transfer::share_object(vault);
    };

    // BOB withdraws all 1000 sDORI
    scenario.next_tx(BOB);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let sdori = scenario.take_from_sender<Coin<SDORI>>();
        let dori = withdraw(&mut vault, sdori, scenario.ctx());

        // BOB gets 1331 DORI (1000 principal + 331 compound yield)
        assert!(dori.value() == 1331);

        transfer::public_transfer(dori, BOB);
        transfer::share_object(vault);
    };

    clock.destroy_for_testing();
    scenario.end();
}

// Test rounding with small amounts
#[test]
fun test_rounding_small_amounts(){
    let mut scenario = test_scenario::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // BOB deposits 3 DORI (very small amount)
    deposit_helper(&mut scenario, BOB, 3);

    // Distribute 1 DORI yield
    distribute_yield_helper(&mut scenario, &clock, 1);

    // Rate should be (4/3) * 1e9 = 1.333...e9
    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        let rate = get_exchange_rate(&vault);
        // Allow for rounding: should be around 1.333e9
        assert!(rate >= 1_333_000_000 && rate <= 1_334_000_000);
        transfer::share_object(vault);
    };

    // ALICE deposits 4 DORI at new rate
    scenario.next_tx(@0xAA);
    {
        let mut vault = scenario.take_shared<SavingsVault>();
        let dori = coin::mint_for_testing<DORI>(4, scenario.ctx());
        let sdori = deposit(&mut vault, dori, scenario.ctx());

        // ALICE should get 3 sDORI (4 * 3 / 4 = 3)
        assert!(sdori.value() == 3);

        transfer::public_transfer(sdori, @0xAA);
        transfer::share_object(vault);
    };

    // Total should be 8 DORI, 6 sDORI
    scenario.next_tx(ADMIN);
    {
        let vault = scenario.take_shared<SavingsVault>();
        assert!(vault.dori_balance.value() == 8);
        assert!(vault.sdori_supply.value() == 6);
        transfer::share_object(vault);
    };

    clock.destroy_for_testing();
    scenario.end();
}

// Test estimated APY calculation
#[test]
fun test_estimated_apy(){
    let mut scenario = test_scenario::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        init_state(&mut scenario);
    };

    // BOB deposits 1000 DORI
    deposit_helper(&mut scenario, BOB, 1000);

    // Distribute 100 DORI yield (10% yield)
    distribute_yield_helper(&mut scenario, &clock, 100);

    // Advance clock by 1 day AFTER distribution
    let one_day_ms = 86_400_000; // 1 day in ms
    clock.increment_for_testing(one_day_ms);

    // Check APY after 1 day with 10% yield
    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        let one_week_ms = 604_800_000; // 7 days lookback
        let apy = get_estimated_apy(&vault, &clock, one_week_ms);

        // APY calculation: 10% yield in 1 day
        // Annualized: roughly 10% * 365 ≈ 3650% APY ≈ 365000 basis points
        // Should return a high non-zero value
        assert!(apy > 0, 0);
        assert!(apy > 100000, 1); // Should be > 1000% APY (100000 bps)

        transfer::share_object(vault);
    };

    // Test: APY returns 0 if lookback period exceeded
    let two_weeks_ms = 1_209_600_000; // 2 weeks
    clock.increment_for_testing(two_weeks_ms);

    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        let short_lookback = 1000; // 1 second
        let apy = get_estimated_apy(&vault, &clock, short_lookback);

        // Should return 0 because last distribution was > 1 second ago
        assert!(apy == 0);

        transfer::share_object(vault);
    };

    // Test: APY with recent distribution (within lookback)
    distribute_yield_helper(&mut scenario, &clock, 121); // More yield

    // Advance clock by 1 hour after distribution
    let one_hour_ms = 3_600_000;
    clock.increment_for_testing(one_hour_ms);

    scenario.next_tx(BOB);
    {
        let vault = scenario.take_shared<SavingsVault>();
        let one_week_ms = 604_800_000; // 7 days lookback
        let apy = get_estimated_apy(&vault, &clock, one_week_ms);

        // Should have non-zero APY since distribution was within lookback
        assert!(apy > 0);

        transfer::share_object(vault);
    };

    clock.destroy_for_testing();
    scenario.end();
}