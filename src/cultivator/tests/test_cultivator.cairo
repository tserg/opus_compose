use core::num::traits::Zero;
use ekubo::interfaces::core::{GetPositionWithFeesResult, ICoreDispatcherTrait};
use ekubo::interfaces::erc721::IERC721DispatcherTrait;
use ekubo::interfaces::positions::IPositionsDispatcherTrait;
use ekubo::types::keys::PositionKey;
use opus::types::AssetBalance;
use opus_compose::addresses::mainnet;
use opus_compose::cultivator::contracts::cultivator::cultivator as cultivator_contract;
use opus_compose::cultivator::interfaces::cultivator::ICultivatorDispatcherTrait;
use opus_compose::cultivator::tests::utils::cultivator_utils::{
    BAD_GUY, CultivatorTestConfig, check_existing_order_completion, create_cash_ekubo_lp,
    generate_ekubo_lp_fees, setup,
};
use opus_compose::cultivator::types::{Order, Seed};
use opus_compose::interfaces::erc20::IERC20DispatcherTrait;
use snforge_std::{
    CheatSpan, EventSpyAssertionsTrait, cheat_caller_address, spy_events,
    start_cheat_block_timestamp_global,
};
use starknet::{ContractAddress, get_block_timestamp};


const BOOL_PARAMETRIZED: [bool; 2] = [true, false];

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivator_setup() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, .. } = test_config;

    assert!(cultivator.get_assets() == array![].span(), "should be no assets");
}

//
// Plant
//

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_plant() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    let mut spy = spy_events();

    let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.plant(asset, ekubo_seed);

    assert_eq!(cultivator.get_assets(), array![asset].span(), "wrong assets");
    assert!(cultivator.get_seed(asset).unwrap() == ekubo_seed, "wrong seed");
    assert_eq!(
        ekubo_positions_nft.owner_of(ekubo_seed.token_id.into()),
        cultivator.contract_address,
        "wrong owner",
    );

    let expected_events = array![
        (
            cultivator.contract_address,
            cultivator_contract::Event::Plant(
                cultivator_contract::Plant { asset, seed: ekubo_seed },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: 'Caller missing role')]
fn test_plant_unauthorized() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, .. } = test_config;

    cheat_caller_address(cultivator.contract_address, BAD_GUY, CheatSpan::TargetCalls(1));

    let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Not owner")]
fn test_plant_not_owner() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let another: ContractAddress = 'another'.try_into().unwrap();

    let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.transfer_from(user, another, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Pool key assets mismatch")]
fn test_plant_pool_key_assets_mismatch() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;

    // Get a valid seed
    let (mut ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    // Modify the seed's pool key to have mismatched assets
    ekubo_seed.pool_key.token0 = 'different_asset'.try_into().unwrap();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: No liquidity found")]
fn test_plant_pool_no_liquidity() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;

    // Get a valid seed
    let (ekubo_seed, ekubo_seed_liquidity) = create_cash_ekubo_lp(test_config);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    // Withdraw all liquidity
    cheat_caller_address(mainnet::EKUBO_POSITIONS, user, CheatSpan::TargetCalls(1));
    ekubo_positions
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
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    // First plant - should succeed
    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.plant(asset, ekubo_seed);

    // Create another seed for the same asset - could be a different position token
    let (another_ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    // Try to plant again for the same asset
    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, another_ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(asset, another_ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Token not approved")]
fn test_plant_token_not_approved() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, .. } = test_config;
    let user = mainnet::MULTISIG;

    let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(mainnet::EKUBO, ekubo_seed);
}

//
// Prune
//

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_prune() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    let mut spy = spy_events();

    let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(2));
    cultivator.plant(asset, ekubo_seed);
    cultivator.prune(asset);

    assert_eq!(cultivator.get_assets(), array![].span(), "wrong assets");
    assert!(cultivator.get_seed(asset).is_none(), "wrong seed");

    assert!(ekubo_positions_nft.owner_of(ekubo_seed.token_id.into()) == user, "wrong nft owner");

    let expected_events = array![
        (
            cultivator.contract_address,
            cultivator_contract::Event::Prune(
                cultivator_contract::Prune { asset, seed: ekubo_seed },
            ),
        ),
    ];
    spy.assert_emitted(@expected_events);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: 'Caller missing role')]
fn test_prune_unauthorized() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.plant(asset, ekubo_seed);

    cheat_caller_address(cultivator.contract_address, BAD_GUY, CheatSpan::TargetCalls(1));
    cultivator.prune(asset);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: No seed for asset")]
fn test_prune_no_existing_position() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, .. } = test_config;
    let user = mainnet::MULTISIG;

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.prune(mainnet::EKUBO);
}

//
// Cultivate
//

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_single_asset_without_existing_twamm_order() {
    for create_twap_order in BOOL_PARAMETRIZED.span() {
        let test_config = setup(Option::None);
        let CultivatorTestConfig {
            cultivator, yin, ekubo_core, ekubo_positions_nft, ..,
        } = test_config;
        let user = mainnet::MULTISIG;
        let asset = mainnet::EKUBO;

        let mut spy = spy_events();

        let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

        cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
        ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        cultivator.plant(asset, ekubo_seed);

        let before_position_with_fees: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            test_config, ekubo_seed,
        );

        let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;
        if *create_twap_order {
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin.transfer(cultivator.contract_address, excess_yin.into());
        }

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let liquidity_delta: u128 = cultivator.cultivate(Option::Some(asset));
        assert!(liquidity_delta.is_non_zero(), "no liquidity added");

        let position_key = PositionKey {
            salt: ekubo_seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: ekubo_seed.bounds,
        };
        let after_position_with_fees: GetPositionWithFeesResult = ekubo_core
            .get_position_with_fees(ekubo_seed.pool_key, position_key);
        assert!(after_position_with_fees.fees0.is_zero(), "fees not zeroed #1");
        assert!(after_position_with_fees.fees1.is_zero(), "fees not zeroed #2");

        let mut expected_events = array![
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate { asset, seed: ekubo_seed, liquidity_delta },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset,
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

        let order: Option<Order> = cultivator.get_order(asset);
        if *create_twap_order {
            assert!(order.is_some(), "order not created");
            let order: Order = order.unwrap();
            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::OrderPlaced(
                            cultivator_contract::OrderPlaced {
                                asset,
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
        let test_config = setup(Option::None);
        let CultivatorTestConfig {
            cultivator, yin, ekubo_core, ekubo_positions_nft, ..,
        } = test_config;
        let user = mainnet::MULTISIG;
        let asset = mainnet::EKUBO;

        let mut spy = spy_events();

        let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

        cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
        ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        cultivator.plant(asset, ekubo_seed);

        let position_before_first_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            test_config, ekubo_seed,
        );

        let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;

        // Create the first TWAP order
        cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
        yin.transfer(cultivator.contract_address, excess_yin.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let first_liquidity_delta: u128 = cultivator.cultivate(Option::Some(asset));
        assert!(first_liquidity_delta.is_non_zero(), "no liquidity added #1");

        let next_ts: u64 = get_block_timestamp() + cultivator_contract::TWAMM_ORDER_PERIOD / 2;
        start_cheat_block_timestamp_global(next_ts);

        // Sanity check that first order has not completed
        check_existing_order_completion(test_config, asset, ekubo_seed, false);

        let position_before_second_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            test_config, ekubo_seed,
        );

        if *create_excess_yin {
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin.transfer(cultivator.contract_address, excess_yin.into());
        }

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let second_liquidity_delta: u128 = cultivator.cultivate(Option::Some(asset));
        assert!(second_liquidity_delta.is_non_zero(), "no liquidity added #2");

        let position_key = PositionKey {
            salt: ekubo_seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: ekubo_seed.bounds,
        };
        let after_position_with_fees: GetPositionWithFeesResult = ekubo_core
            .get_position_with_fees(ekubo_seed.pool_key, position_key);
        assert!(after_position_with_fees.fees0.is_zero(), "fees not zeroed #1");
        assert!(after_position_with_fees.fees1.is_zero(), "fees not zeroed #2");

        // Excess yin should remain unused since there is an existing incomplete order
        if *create_excess_yin {
            let yin_balance: u256 = yin.balance_of(cultivator.contract_address);
            assert!(yin_balance.is_non_zero(), "excess yin should be unused");
        }

        let order: Option<Order> = cultivator.get_order(asset);
        assert!(order.is_some(), "order not created");
        let order: Order = order.unwrap();

        let mut expected_events = array![
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate {
                        asset, seed: ekubo_seed, liquidity_delta: first_liquidity_delta,
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate {
                        asset, seed: ekubo_seed, liquidity_delta: second_liquidity_delta,
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset,
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
                        asset,
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
                        asset,
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
        let test_config = setup(Option::None);
        let CultivatorTestConfig {
            cultivator, yin, ekubo_core, ekubo_positions_nft, ..,
        } = test_config;
        let user = mainnet::MULTISIG;
        let asset = mainnet::EKUBO;

        let mut spy = spy_events();

        let (ekubo_seed, _) = create_cash_ekubo_lp(test_config);

        cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
        ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        cultivator.plant(asset, ekubo_seed);

        let position_before_first_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            test_config, ekubo_seed,
        );

        // Create the first TWAP order
        cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
        let first_excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;
        yin.transfer(cultivator.contract_address, first_excess_yin.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let first_liquidity_delta: u128 = cultivator.cultivate(Option::Some(asset));
        assert!(first_liquidity_delta.is_non_zero(), "no liquidity added #1");

        let first_order: Option<Order> = cultivator.get_order(asset);
        assert!(first_order.is_some(), "first order not created");
        let first_order: Order = first_order.unwrap();

        let next_ts: u64 = get_block_timestamp() + cultivator_contract::TWAMM_ORDER_PERIOD + 1;
        start_cheat_block_timestamp_global(next_ts);

        // Sanity check that first order has completed
        check_existing_order_completion(test_config, asset, ekubo_seed, true);

        let position_before_second_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            test_config, ekubo_seed,
        );

        if *create_second_order {
            let second_excess_yin: u128 = first_excess_yin * 2;
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin.transfer(cultivator.contract_address, second_excess_yin.into());
        }

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let second_liquidity_delta: u128 = cultivator.cultivate(Option::Some(asset));
        assert!(second_liquidity_delta.is_non_zero(), "no liquidity added #2");

        let position_key = PositionKey {
            salt: ekubo_seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: ekubo_seed.bounds,
        };
        let after_position_with_fees: GetPositionWithFeesResult = ekubo_core
            .get_position_with_fees(ekubo_seed.pool_key, position_key);
        assert!(after_position_with_fees.fees0.is_zero(), "fees not zeroed #1");
        assert!(after_position_with_fees.fees1.is_zero(), "fees not zeroed #2");

        let mut expected_events = array![
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate {
                        asset, seed: ekubo_seed, liquidity_delta: first_liquidity_delta,
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate {
                        asset, seed: ekubo_seed, liquidity_delta: second_liquidity_delta,
                    },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset,
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
                        asset,
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
                        asset,
                        order_id: ekubo_seed.token_id,
                        fee: ekubo_seed.pool_key.fee,
                        end_time: first_order.end_time,
                    },
                ),
            ),
        ];

        let second_order: Option<Order> = cultivator.get_order(asset);
        if *create_second_order {
            assert!(second_order.is_some(), "second order not created");
            let second_order: Order = second_order.unwrap();
            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::OrderPlaced(
                            cultivator_contract::OrderPlaced {
                                asset,
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
