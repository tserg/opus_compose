use core::num::traits::{Pow, Zero};
use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
use ekubo::interfaces::core::{GetPositionWithFeesResult, ICoreDispatcher, ICoreDispatcherTrait};
use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::bounds::Bounds;
use ekubo::types::delta::Delta;
use ekubo::types::i129::i129;
use ekubo::types::keys::{PoolKey, PositionKey};
use opus::types::AssetBalance;
use opus_compose::addresses::mainnet;
use opus_compose::cultivator::contracts::cultivator::cultivator as cultivator_contract;
use opus_compose::cultivator::interfaces::cultivator::ICultivatorDispatcherTrait;
use opus_compose::cultivator::tests::utils::cultivator_utils::{CultivatorTestConfig, setup};
use opus_compose::cultivator::types::{Order, Seed};
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait,
    cheat_caller_address, declare, spy_events, start_cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp_global
};
use starknet::{ContractAddress, get_block_timestamp};
use wadray::WAD_ONE;

const BOOL_PARAMETRIZED: [bool; 2] = [true, false];

const INITIAL_CASH_LP_AMT: u128 = 50 * WAD_ONE;
const INITIAL_EKUBO_LP_AMT: u128 = 5 * WAD_ONE;

const CASH_SWAP_AMT: u128 = WAD_ONE;

const BAD_GUY: ContractAddress = 'bad guy'.try_into().unwrap();

fn yin() -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: mainnet::SHRINE }
}

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher { contract_address: mainnet::EKUBO_CORE }
}

fn ekubo_token() -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: mainnet::EKUBO }
}

fn ekubo_positions() -> IPositionsDispatcher {
    IPositionsDispatcher { contract_address: mainnet::EKUBO_POSITIONS }
}

fn ekubo_positions_nft() -> IERC721Dispatcher {
    IERC721Dispatcher { contract_address: mainnet::EKUBO_POSITIONS_NFT }
}

fn ekubo_positions_clear() -> IClearDispatcher {
    IClearDispatcher { contract_address: mainnet::EKUBO_POSITIONS }
}

fn ekubo_router() -> IRouterDispatcher {
    IRouterDispatcher { contract_address: mainnet::EKUBO_ROUTER }
}

const CASH_EKUBO_TWAMM_POOL_KEY: PoolKey = PoolKey {
    token0: mainnet::SHRINE,
    token1: mainnet::EKUBO,
    fee: 1020847100762815411640772995208708096, // 0.3%
    tick_spacing: 354892,
    extension: mainnet::EKUBO_TWAMM_EXTENSION,
};

const TWAMM_BOUNDS: Bounds = Bounds {
    lower: i129 { mag: 88368108, sign: true }, upper: i129 { mag: 88368108, sign: false },
};

fn setup_cash_ekubo_lp() -> (Seed, u128) {
    let user = mainnet::MULTISIG;

    cheat_caller_address(yin().contract_address, user, CheatSpan::TargetCalls(1));
    yin().transfer(mainnet::EKUBO_POSITIONS, INITIAL_CASH_LP_AMT.into());

    cheat_caller_address(ekubo_token().contract_address, user, CheatSpan::TargetCalls(1));
    ekubo_token().transfer(mainnet::EKUBO_POSITIONS, INITIAL_EKUBO_LP_AMT.into());

    cheat_caller_address(ekubo_positions().contract_address, user, CheatSpan::TargetCalls(1));
    let (token_id, liquidity) = ekubo_positions()
        .mint_and_deposit(CASH_EKUBO_TWAMM_POOL_KEY, TWAMM_BOUNDS, 1);

    cheat_caller_address(ekubo_positions().contract_address, user, CheatSpan::TargetCalls(2));
    ekubo_positions_clear().clear(EkuboERC20Dispatcher { contract_address: mainnet::SHRINE });
    ekubo_positions_clear().clear(EkuboERC20Dispatcher { contract_address: mainnet::EKUBO });

    (Seed { token_id, pool_key: CASH_EKUBO_TWAMM_POOL_KEY, bounds: TWAMM_BOUNDS }, liquidity)
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivator_setup() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);

    assert!(cultivator.get_assets() == array![].span(), "should be no assets");
}

//
// Plant
//

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_plant() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    let mut spy = spy_events();

    let (ekubo_seed, _) = setup_cash_ekubo_lp();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.plant(mainnet::EKUBO, ekubo_seed);

    assert_eq!(cultivator.get_assets(), array![mainnet::EKUBO].span(), "wrong assets");
    assert!(cultivator.get_seed(mainnet::EKUBO).unwrap() == ekubo_seed, "wrong seed");
    assert_eq!(
        ekubo_positions_nft().owner_of(ekubo_seed.token_id.into()),
        cultivator.contract_address,
        "wrong owner",
    );

    let expected_events = array![
        (
            cultivator.contract_address,
            cultivator_contract::Event::Plant(
                cultivator_contract::Plant { asset: mainnet::EKUBO, seed: ekubo_seed },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: 'Caller missing role')]
fn test_plant_unauthorized() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);

    cheat_caller_address(cultivator.contract_address, BAD_GUY, CheatSpan::TargetCalls(1));

    let (ekubo_seed, _) = setup_cash_ekubo_lp();

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Not owner")]
fn test_plant_not_owner() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;
    let another: ContractAddress = 'another'.try_into().unwrap();

    let (ekubo_seed, _) = setup_cash_ekubo_lp();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().transfer_from(user, another, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Pool key assets mismatch")]
fn test_plant_pool_key_assets_mismatch() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    // Get a valid seed
    let (mut ekubo_seed, _) = setup_cash_ekubo_lp();

    // Modify the seed's pool key to have mismatched assets
    ekubo_seed.pool_key.token0 = 'different_asset'.try_into().unwrap();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: No liquidity found")]
fn test_plant_pool_no_liquidity() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    let other_asset = mainnet::ETH;

    // Get a valid seed
    let (ekubo_seed, ekubo_seed_liquidity) = setup_cash_ekubo_lp();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

    // Withdraw all liquidity
    cheat_caller_address(mainnet::EKUBO_POSITIONS, user, CheatSpan::TargetCalls(1));
    ekubo_positions()
        .withdraw_v2(
            ekubo_seed.token_id, ekubo_seed.pool_key, ekubo_seed.bounds, ekubo_seed_liquidity, 1, 1,
        );

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Position exist")]
fn test_plant_existing_position() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    let (ekubo_seed, _) = setup_cash_ekubo_lp();

    // First plant - should succeed
    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.plant(mainnet::EKUBO, ekubo_seed);

    // Create another seed for the same asset - could be a different position token
    let (another_ekubo_seed, _) = setup_cash_ekubo_lp();

    // Try to plant again for the same asset
    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().approve(cultivator.contract_address, another_ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, another_ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Token not approved")]
fn test_plant_token_not_approved() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    let (ekubo_seed, _) = setup_cash_ekubo_lp();

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

//
// Prune
//

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_prune() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    let mut spy = spy_events();

    let (ekubo_seed, _) = setup_cash_ekubo_lp();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(2));
    cultivator.plant(mainnet::EKUBO, ekubo_seed);
    cultivator.prune(mainnet::EKUBO);

    assert_eq!(cultivator.get_assets(), array![].span(), "wrong assets");
    assert!(cultivator.get_seed(mainnet::EKUBO).is_none(), "wrong seed");

    assert!(ekubo_positions_nft().owner_of(ekubo_seed.token_id.into()) == user, "wrong nft owner");

    let expected_events = array![
        (
            cultivator.contract_address,
            cultivator_contract::Event::Prune(
                cultivator_contract::Prune { asset: mainnet::EKUBO, seed: ekubo_seed },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: 'Caller missing role')]
fn test_prune_unauthorized() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    let (ekubo_seed, _) = setup_cash_ekubo_lp();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.plant(mainnet::EKUBO, ekubo_seed);

    cheat_caller_address(cultivator.contract_address, BAD_GUY, CheatSpan::TargetCalls(1));
    cultivator.prune(mainnet::EKUBO);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: No seed for asset")]
fn test_prune_no_existing_position() {
    let CultivatorTestConfig { cultivator } = setup(Option::None);
    let user = mainnet::MULTISIG;

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.prune(mainnet::EKUBO);
}

//
// Cultivate
//

// Returns the LP position after swaps
fn generate_ekubo_lp_fees(seed: Seed) -> GetPositionWithFeesResult {
    let user = mainnet::MULTISIG;

    let pool_price = ekubo_core().get_pool_price(seed.pool_key);

    let position_key = PositionKey {
        salt: seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: seed.bounds,
    };
    let before_position_with_fees: GetPositionWithFeesResult = ekubo_core()
        .get_position_with_fees(seed.pool_key, position_key);

    cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
    yin().transfer(mainnet::EKUBO_ROUTER, CASH_SWAP_AMT.into());

    cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
    let delta: Delta = ekubo_router()
        .swap(
            node: RouteNode {
                pool_key: seed
                    .pool_key, // Selling token0 will increase the token0 balance of the pool, so sqrt ratio will
                // decrease
                sqrt_ratio_limit: pool_price.sqrt_ratio / 2,
                skip_ahead: 0,
            },
            token_amount: TokenAmount { token: mainnet::SHRINE, amount: CASH_SWAP_AMT.into() },
        );

    cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
    ekubo_router()
        .swap(
            node: RouteNode {
                pool_key: seed
                    .pool_key, // Selling token1 will increase the token1 balance of the pool, so sqrt ratio will
                // inccrease
                sqrt_ratio_limit: pool_price.sqrt_ratio * 2,
                skip_ahead: 0,
            },
            token_amount: TokenAmount { token: mainnet::EKUBO, amount: -(delta.amount1) },
        );

    let after_position_with_fees: GetPositionWithFeesResult = ekubo_core()
        .get_position_with_fees(seed.pool_key, position_key);

    assert!(
        before_position_with_fees.fees0 < after_position_with_fees.fees0,
        "t0 fees did not increase after swap",
    );
    assert!(
        before_position_with_fees.fees1 < after_position_with_fees.fees1,
        "t1 fees did not increase after swap",
    );

    after_position_with_fees
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_single_asset_without_existing_twamm_order() {
    for create_twap_order in BOOL_PARAMETRIZED.span() {
        let CultivatorTestConfig { cultivator } = setup(Option::None);
        let user = mainnet::MULTISIG;

        let mut spy = spy_events();

        let (ekubo_seed, _) = setup_cash_ekubo_lp();

        cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
        ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        cultivator.plant(mainnet::EKUBO, ekubo_seed);

        let before_position_with_fees: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            ekubo_seed,
        );

        let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;
        if *create_twap_order {
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin().transfer(cultivator.contract_address, excess_yin.into());
        }

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let liquidity_delta: u128 = cultivator.cultivate(Option::Some(mainnet::EKUBO));

        let position_key = PositionKey {
            salt: ekubo_seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: ekubo_seed.bounds,
        };
        let after_position_with_fees: GetPositionWithFeesResult = ekubo_core()
            .get_position_with_fees(ekubo_seed.pool_key, position_key);
        assert!(after_position_with_fees.fees0.is_zero(), "fees not zeroed #1");
        assert!(after_position_with_fees.fees1.is_zero(), "fees not zeroed #2");

        let mut expected_events = array![
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate { asset: mainnet::EKUBO, seed: ekubo_seed, liquidity_delta },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset: mainnet::EKUBO,
                        assets: array![
                            AssetBalance {
                                address: ekubo_seed.pool_key.token0,
                                amount: before_position_with_fees.fees0,
                            },
                            AssetBalance {
                                address: ekubo_seed.pool_key.token1,
                                amount: before_position_with_fees.fees1,
                            },
                        ]
                            .span(),
                    },
                ),
            ),
        ];

        let order: Option<Order> = cultivator.get_order(mainnet::EKUBO);
        if *create_twap_order {
            assert!(order.is_some(), "order not created");
            let order: Order = order.unwrap();
            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::OrderPlaced(
                            cultivator_contract::OrderPlaced {
                                asset: mainnet::EKUBO,
                                order_id: ekubo_seed.token_id,
                                fee: ekubo_seed.pool_key.fee,
                                end_time: order.end_time,
                            },
                        ),
                    ),
                );
        } else {
            assert!(order.is_none(), "order created");
        }

        spy.assert_emitted(@expected_events);
    }
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_single_asset_with_existing_incomplete_twamm_order() {
    for create_excess_yin in BOOL_PARAMETRIZED.span() {
        let CultivatorTestConfig { cultivator } = setup(Option::None);
        let user = mainnet::MULTISIG;

        let mut spy = spy_events();

        let (ekubo_seed, _) = setup_cash_ekubo_lp();

        cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
        ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        cultivator.plant(mainnet::EKUBO, ekubo_seed);

        let position_before_first_cultivate: GetPositionWithFeesResult =generate_ekubo_lp_fees(
            ekubo_seed,
        );

        let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;
        
        // Create the first TWAP order
        cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
        yin().transfer(cultivator.contract_address, excess_yin.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let first_liquidity_delta: u128 = cultivator.cultivate(Option::Some(mainnet::EKUBO));

        let next_ts: u64 = get_block_timestamp() + cultivator_contract::TWAMM_ORDER_PERIOD / 2;
        start_cheat_block_timestamp_global(next_ts);

        let position_before_second_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            ekubo_seed,
        );

        if *create_excess_yin {
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin().transfer(cultivator.contract_address, excess_yin.into());
        };

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let second_liquidity_delta: u128 = cultivator.cultivate(Option::Some(mainnet::EKUBO));        

        let position_key = PositionKey {
            salt: ekubo_seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: ekubo_seed.bounds,
        };
        let after_position_with_fees: GetPositionWithFeesResult = ekubo_core()
            .get_position_with_fees(ekubo_seed.pool_key, position_key);
        assert!(after_position_with_fees.fees0.is_zero(), "fees not zeroed #1");
        assert!(after_position_with_fees.fees1.is_zero(), "fees not zeroed #2");

        // Excess yin should remain unused since there is an existing incomplete order
        if *create_excess_yin {
            let yin_balance: u256 = yin().balance_of(cultivator.contract_address);
            assert!(yin_balance.is_non_zero(), "excess yin should be unused"); 
        }

        let order: Option<Order> = cultivator.get_order(mainnet::EKUBO);
        assert!(order.is_some(), "order not created");
        let order: Order = order.unwrap();

        let mut expected_events = array![
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate { asset: mainnet::EKUBO, seed: ekubo_seed, liquidity_delta: first_liquidity_delta },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate { asset: mainnet::EKUBO, seed: ekubo_seed, liquidity_delta: second_liquidity_delta },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset: mainnet::EKUBO,
                        assets: array![
                            AssetBalance {
                                address: ekubo_seed.pool_key.token0,
                                amount: position_before_first_cultivate.fees0,
                            },
                            AssetBalance {
                                address: ekubo_seed.pool_key.token1,
                                amount: position_before_first_cultivate.fees1,
                            },
                        ]
                            .span(),
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset: mainnet::EKUBO,
                        assets: array![
                            AssetBalance {
                                address: ekubo_seed.pool_key.token0,
                                amount: position_before_second_cultivate.fees0,
                            },
                            AssetBalance {
                                address: ekubo_seed.pool_key.token1,
                                amount: position_before_second_cultivate.fees1,
                            },
                        ]
                            .span(),
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::OrderPlaced(
                    cultivator_contract::OrderPlaced {
                        asset: mainnet::EKUBO,
                        order_id: ekubo_seed.token_id,
                        fee: ekubo_seed.pool_key.fee,
                        end_time: order.end_time,
                    },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_single_asset_with_existing_completed_twamm_order() {
    for create_second_order in BOOL_PARAMETRIZED.span() {
        let CultivatorTestConfig { cultivator } = setup(Option::None);
        let user = mainnet::MULTISIG;

        let mut spy = spy_events();

        let (ekubo_seed, _) = setup_cash_ekubo_lp();

        cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
        ekubo_positions_nft().approve(cultivator.contract_address, ekubo_seed.token_id.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        cultivator.plant(mainnet::EKUBO, ekubo_seed);

        let position_before_first_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            ekubo_seed,
        );
        
        // Create the first TWAP order
        cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
        let first_excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;
        yin().transfer(cultivator.contract_address, first_excess_yin.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let first_liquidity_delta: u128 = cultivator.cultivate(Option::Some(mainnet::EKUBO));

        let first_order: Option<Order> = cultivator.get_order(mainnet::EKUBO);
        assert!(first_order.is_some(), "first order not created");
        let first_order: Order = first_order.unwrap();

        let next_ts: u64 = get_block_timestamp() + cultivator_contract::TWAMM_ORDER_PERIOD + 1;
        start_cheat_block_timestamp_global(next_ts);

        let position_before_second_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            ekubo_seed,
        );

        if *create_second_order {
            let second_excess_yin: u128 = first_excess_yin * 2;
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin().transfer(cultivator.contract_address, second_excess_yin.into());
        };

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let second_liquidity_delta: u128 = cultivator.cultivate(Option::Some(mainnet::EKUBO));        

        let position_key = PositionKey {
            salt: ekubo_seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: ekubo_seed.bounds,
        };
        let after_position_with_fees: GetPositionWithFeesResult = ekubo_core()
            .get_position_with_fees(ekubo_seed.pool_key, position_key);
        assert!(after_position_with_fees.fees0.is_zero(), "fees not zeroed #1");
        assert!(after_position_with_fees.fees1.is_zero(), "fees not zeroed #2");

        let mut expected_events = array![
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate { asset: mainnet::EKUBO, seed: ekubo_seed, liquidity_delta: first_liquidity_delta },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate { asset: mainnet::EKUBO, seed: ekubo_seed, liquidity_delta: second_liquidity_delta },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset: mainnet::EKUBO,
                        assets: array![
                            AssetBalance {
                                address: ekubo_seed.pool_key.token0,
                                amount: position_before_first_cultivate.fees0,
                            },
                            AssetBalance {
                                address: ekubo_seed.pool_key.token1,
                                amount: position_before_first_cultivate.fees1,
                            },
                        ]
                            .span(),
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset: mainnet::EKUBO,
                        assets: array![
                            AssetBalance {
                                address: ekubo_seed.pool_key.token0,
                                amount: position_before_second_cultivate.fees0,
                            },
                            AssetBalance {
                                address: ekubo_seed.pool_key.token1,
                                amount: position_before_second_cultivate.fees1,
                            },
                        ]
                            .span(),
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::OrderPlaced(
                    cultivator_contract::OrderPlaced {
                        asset: mainnet::EKUBO,
                        order_id: ekubo_seed.token_id,
                        fee: ekubo_seed.pool_key.fee,
                        end_time: first_order.end_time,
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::OrderClosed(
                    cultivator_contract::OrderClosed {
                        asset: mainnet::EKUBO,
                        order_id: ekubo_seed.token_id,
                        fee: ekubo_seed.pool_key.fee,
                        end_time: first_order.end_time,
                    },
                ),
            ),
        ];

        let second_order: Option<Order> = cultivator.get_order(mainnet::EKUBO);
        if *create_second_order {
            assert!(second_order.is_some(), "second order not created");
            let second_order: Order = second_order.unwrap();
            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::OrderPlaced(
                            cultivator_contract::OrderPlaced {
                                asset: mainnet::EKUBO,
                                order_id: ekubo_seed.token_id,
                                fee: ekubo_seed.pool_key.fee,
                                end_time: second_order.end_time,
                            },
                        ),
                    ),
                );
        } else {
            assert!(second_order.is_none(), "second order created");
        }

        spy.assert_emitted(@expected_events);
    }
}