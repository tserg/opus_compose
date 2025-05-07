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
    ASSETS, BAD_GUY, CultivatorTestConfig, assert_pool_fees_collected, check_existing_order_completion,
    create_lp_for_asset, create_lp_for_assets, generate_ekubo_lp_fees, setup,
};
use opus_compose::cultivator::types::{Order, Seed};
use opus_compose::interfaces::erc20::IERC20DispatcherTrait;
use snforge_std::{
    CheatSpan, EventsFilterTrait, EventSpyAssertionsTrait, EventSpyTrait, cheat_caller_address, spy_events,
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

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

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
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    cheat_caller_address(cultivator.contract_address, BAD_GUY, CheatSpan::TargetCalls(1));

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    cultivator.plant(asset, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Not owner")]
fn test_plant_not_owner() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let another: ContractAddress = 'another'.try_into().unwrap();
    let asset = mainnet::EKUBO;

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.transfer_from(user, another, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(asset, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Pool key assets mismatch")]
fn test_plant_pool_key_assets_mismatch() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    // Get a valid seed
    let (mut ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    // Modify the seed's pool key to have mismatched assets
    ekubo_seed.pool_key.token0 = 'different_asset'.try_into().unwrap();

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(asset, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: No liquidity found")]
fn test_plant_pool_no_liquidity() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    // Get a valid seed
    let (ekubo_seed, ekubo_seed_liquidity) = create_lp_for_asset(test_config, user, asset);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    // Withdraw all liquidity
    cheat_caller_address(mainnet::EKUBO_POSITIONS, user, CheatSpan::TargetCalls(1));
    ekubo_positions
        .withdraw_v2(
            ekubo_seed.token_id, ekubo_seed.pool_key, ekubo_seed.bounds, ekubo_seed_liquidity, 1, 1,
        );

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(asset, ekubo_seed);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: Position exist")]
fn test_plant_existing_position() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    // First plant - should succeed
    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.plant(asset, ekubo_seed);

    // Create another seed for the same asset - could be a different position token
    let (another_ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

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
    let asset = mainnet::EKUBO;

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.plant(asset, ekubo_seed);
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

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

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

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

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
    let asset = mainnet::EKUBO;

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));

    cultivator.prune(asset);
}

//
// Cultivate
//

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_no_asset() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    assert!(cultivator.cultivate(Option::None).is_zero(), "should be zero liquidity delta");
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_single_asset_without_existing_twamm_order() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;
    let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    for specify_asset in BOOL_PARAMETRIZED.span() {
        for create_twap_order in BOOL_PARAMETRIZED.span() {
            let mut spy = spy_events();

            cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
            ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            cultivator.plant(asset, ekubo_seed);

            let before_position_with_fees: GetPositionWithFeesResult = generate_ekubo_lp_fees(
                test_config, ekubo_seed,
            );

            if *create_twap_order {
                cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
                yin.transfer(cultivator.contract_address, excess_yin.into());
            }

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            let liquidity_delta: u128 = if *specify_asset {
                cultivator.cultivate(Option::Some(asset))
            } else {
                cultivator.cultivate(Option::None)
            };
            assert!(liquidity_delta.is_non_zero(), "no liquidity added");

            assert_pool_fees_collected(test_config, ekubo_seed);

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
                            fees: array![
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
                expected_events
                    .append(
                        // Construct the event for forced closure of the order
                        // when pruning the asset below
                        (
                            cultivator.contract_address,
                            cultivator_contract::Event::OrderClosed(
                                cultivator_contract::OrderClosed {
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

            // Reset the state in Cultivator
            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(2));
            cultivator.prune(asset);
            let extracted_yin_amt: u256 = cultivator.extract(mainnet::SHRINE);

            assert_eq!(
                ekubo_positions_nft.owner_of(ekubo_seed.token_id.into()), user, "wrong owner",
            );
            let order: Option<Order> = cultivator.get_order(asset);
            assert!(order.is_none(), "order is not pruned");

            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::Prune(
                            cultivator_contract::Prune { asset, seed: ekubo_seed },
                        ),
                    ),
                );
            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::Extract(
                            cultivator_contract::Extract {
                                caller: user, asset: mainnet::SHRINE, amount: extracted_yin_amt,
                            },
                        ),
                    ),
                );

            spy.assert_emitted(@expected_events);
        }
    }
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_single_asset_with_existing_incomplete_twamm_order() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;
    let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 3;

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    for specify_asset in BOOL_PARAMETRIZED.span() {
        for create_excess_yin in BOOL_PARAMETRIZED.span() {
            let mut spy = spy_events();

            cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
            ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            cultivator.plant(asset, ekubo_seed);

            let position_before_first_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
                test_config, ekubo_seed,
            );

            // Create the first TWAP order
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin.transfer(cultivator.contract_address, excess_yin.into());

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            let first_liquidity_delta: u128 = if *specify_asset {
                cultivator.cultivate(Option::Some(asset))
            } else {
                cultivator.cultivate(Option::None)
            };
            assert!(first_liquidity_delta.is_non_zero(), "no liquidity added #1");

            let next_ts: u64 = get_block_timestamp() + cultivator_contract::TWAMM_ORDER_PERIOD / 2;
            start_cheat_block_timestamp_global(next_ts);

            // Sanity check that first order has not completed
            check_existing_order_completion(test_config, asset, ekubo_seed, false);

            let position_before_second_cultivate: GetPositionWithFeesResult =
                generate_ekubo_lp_fees(
                test_config, ekubo_seed,
            );

            if *create_excess_yin {
                cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
                yin.transfer(cultivator.contract_address, excess_yin.into());
            }

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            let second_liquidity_delta: u128 = if *specify_asset {
                cultivator.cultivate(Option::Some(asset))
            } else {
                cultivator.cultivate(Option::None)
            };
            assert!(second_liquidity_delta.is_non_zero(), "no liquidity added #2");

            assert_pool_fees_collected(test_config, ekubo_seed);

            // Excess yin should remain unused since there is an existing incomplete order
            if *create_excess_yin {
                let yin_balance: u256 = yin.balance_of(cultivator.contract_address);
                assert!(yin_balance.is_non_zero(), "excess yin should be unused");
            }

            let order: Option<Order> = cultivator.get_order(asset);
            assert!(order.is_some(), "order not created");
            let order: Order = order.unwrap();

            // Reset the state in Cultivator
            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(2));
            cultivator.prune(asset);
            let extracted_yin_amt: u256 = cultivator.extract(mainnet::SHRINE);

            assert_eq!(
                ekubo_positions_nft.owner_of(ekubo_seed.token_id.into()), user, "wrong owner",
            );
            assert!(cultivator.get_order(asset).is_none(), "order is not pruned");

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
                            fees: array![
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
                            fees: array![
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
                // Construct the event for forced closure of the order
                // when pruning the asset below
                (
                    cultivator.contract_address,
                    cultivator_contract::Event::OrderClosed(
                        cultivator_contract::OrderClosed {
                            asset,
                            order_id: ekubo_seed.token_id,
                            fee: ekubo_seed.pool_key.fee,
                            end_time: order.end_time,
                        },
                    ),
                ),
                (
                    cultivator.contract_address,
                    cultivator_contract::Event::Prune(
                        cultivator_contract::Prune { asset, seed: ekubo_seed },
                    ),
                ),
                (
                    cultivator.contract_address,
                    cultivator_contract::Event::Extract(
                        cultivator_contract::Extract {
                            caller: user, asset: mainnet::SHRINE, amount: extracted_yin_amt,
                        },
                    ),
                ),
            ];

            spy.assert_emitted(@expected_events);
        }
    }
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_single_asset_with_existing_completed_twamm_order() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    let mut first_excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 3;

    for specify_asset in BOOL_PARAMETRIZED.span() {
        for create_second_order in BOOL_PARAMETRIZED.span() {
            let mut spy = spy_events();

            cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
            ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            cultivator.plant(asset, ekubo_seed);

            let position_before_first_cultivate: GetPositionWithFeesResult = generate_ekubo_lp_fees(
                test_config, ekubo_seed,
            );

            // Create the first TWAP order
            cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
            yin.transfer(cultivator.contract_address, first_excess_yin.into());

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            let first_liquidity_delta: u128 = if *specify_asset {
                cultivator.cultivate(Option::Some(asset))
            } else {
                cultivator.cultivate(Option::None)
            };
            assert!(first_liquidity_delta.is_non_zero(), "no liquidity added #1");

            let first_order: Option<Order> = cultivator.get_order(asset);
            assert!(first_order.is_some(), "first order not created");
            let first_order: Order = first_order.unwrap();

            let next_ts: u64 = get_block_timestamp() + cultivator_contract::TWAMM_ORDER_PERIOD + 1;
            start_cheat_block_timestamp_global(next_ts);

            // Sanity check that first order has completed
            check_existing_order_completion(test_config, asset, ekubo_seed, true);

            let position_before_second_cultivate: GetPositionWithFeesResult =
                generate_ekubo_lp_fees(
                test_config, ekubo_seed,
            );

            if *create_second_order {
                let second_excess_yin: u128 = first_excess_yin * 2;
                cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
                yin.transfer(cultivator.contract_address, second_excess_yin.into());
            }

            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            let second_liquidity_delta: u128 = if *specify_asset {
                cultivator.cultivate(Option::Some(asset))
            } else {
                cultivator.cultivate(Option::None)
            };
            assert!(second_liquidity_delta.is_non_zero(), "no liquidity added #2");

            assert_pool_fees_collected(test_config, ekubo_seed);

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
                            fees: array![
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
                            fees: array![
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
                (
                    cultivator.contract_address,
                    cultivator_contract::Event::OrderClosed(
                        cultivator_contract::OrderClosed {
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
                expected_events
                    .append(
                        // Construct the event for forced closure of the order
                        // when pruning the asset below
                        (
                            cultivator.contract_address,
                            cultivator_contract::Event::OrderClosed(
                                cultivator_contract::OrderClosed {
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

            // Reset the state in Cultivator
            cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(2));
            cultivator.prune(asset);
            let extracted_yin_amt: u256 = cultivator.extract(mainnet::SHRINE);

            assert_eq!(
                ekubo_positions_nft.owner_of(ekubo_seed.token_id.into()), user, "wrong owner",
            );
            let order: Option<Order> = cultivator.get_order(asset);
            assert!(order.is_none(), "order is not pruned");

            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::Prune(
                            cultivator_contract::Prune { asset, seed: ekubo_seed },
                        ),
                    ),
                );
            expected_events
                .append(
                    (
                        cultivator.contract_address,
                        cultivator_contract::Event::Extract(
                            cultivator_contract::Extract {
                                caller: user, asset: mainnet::SHRINE, amount: extracted_yin_amt,
                            },
                        ),
                    ),
                );

            spy.assert_emitted(@expected_events);

            // Increase the amount of excess yin because as the TWAP orders are completed,
            // more yin is required to autocompound the LPs during `cultivate`.
            first_excess_yin *= 2;
        }
    }
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_cultivate_multiple_asset() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let assets = ASSETS.span();

    let seeds = create_lp_for_assets(test_config, user, assets);

    // Block timestamp is 1745907410
    // Expected modulo order: 2, 0, 1
    // Expected asset ids: 3, 1, 2

    let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;

    let mut expected_asset_ids: Span<usize> = array![3, 1, 2].span();
    let ts: u64 = get_block_timestamp();
    for number in 0..2_usize {
        let mut spy = spy_events();

        start_cheat_block_timestamp_global(ts + number.into());

        let expected_idx = *expected_asset_ids.pop_front().unwrap() - 1;
        let asset = *(assets[expected_idx]);
        let seed = *(seeds[expected_idx]);
        // Sanity check
        assert!(seed.pool_key.token0 == asset || seed.pool_key.token1 == asset, "wrong seed");

        let before_position_with_fees: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            test_config, seed,
        );

        // Create the first TWAP order
        cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
        yin.transfer(cultivator.contract_address, excess_yin.into());

        cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
        let liquidity_delta: u128 = cultivator.cultivate(Option::None);

        assert!(liquidity_delta.is_non_zero(), "no liquidity added");

        assert_pool_fees_collected(test_config, seed);

        let order: Option<Order> = cultivator.get_order(asset);
        assert!(order.is_some(), "order not created");
        let order: Order = order.unwrap();

        let mut expected_events = array![
            (
                cultivator.contract_address,
                cultivator_contract::Event::Cultivate(
                    cultivator_contract::Cultivate { asset, seed, liquidity_delta },
                ),
            ),
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset,
                        fees: array![
                            AssetBalance {
                                address: seed.pool_key.token0,
                                amount: before_position_with_fees.fees0,
                            },
                            AssetBalance {
                                address: seed.pool_key.token1,
                                amount: before_position_with_fees.fees1,
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
                        order_id: seed.token_id,
                        fee: seed.pool_key.fee,
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
#[should_panic(expected: 'Caller missing role')]
fn test_cultivate_unauthorized() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, .. } = test_config;

    cheat_caller_address(cultivator.contract_address, BAD_GUY, CheatSpan::TargetCalls(1));
    cultivator.cultivate(Option::None);
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
#[should_panic(expected: "CUL: No seed for asset")]
fn test_cultivate_unplanted_asset() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.cultivate(Option::Some(asset));
}

//
// Collect
//

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_collect_no_assets() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;

    let mut spy = spy_events();

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(1));
    cultivator.collect();

    let events = spy.get_events();
    assert!(events.events.len().is_zero(), "should be zero events");
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_collect_single_asset_without_fees() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let asset = mainnet::EKUBO;
    let excess_yin: u128 = cultivator_contract::YIN_CULTIVATE_THRESHOLD * 2;

    let (ekubo_seed, _) = create_lp_for_asset(test_config, user, asset);

    cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
    ekubo_positions_nft.approve(cultivator.contract_address, ekubo_seed.token_id.into());

    cheat_caller_address(cultivator.contract_address, user, CheatSpan::TargetCalls(2));
    cultivator.plant(asset, ekubo_seed);

    let mut spy = spy_events();

    cultivator.collect();

    let cultivator_events = spy.get_events().emitted_by(cultivator.contract_address);
    assert!(cultivator_events.events.len().is_zero(), "should be zero events");
}

#[test]
#[fork("MAINNET_CULTIVATOR")]
fn test_collect_multiple_assets_with_fees() {
    let test_config = setup(Option::None);
    let CultivatorTestConfig { cultivator, yin, ekubo_core, ekubo_positions_nft, .. } = test_config;
    let user = mainnet::MULTISIG;
    let assets = ASSETS.span();

    let seeds = create_lp_for_assets(test_config, user, assets);

    let mut expected_events: Array<(ContractAddress, cultivator_contract::Event)> = Default::default();

    let mut spy = spy_events();
    let mut assets_copy = assets;
    for seed in seeds {
        let before: GetPositionWithFeesResult = generate_ekubo_lp_fees(
            test_config, *seed,
        );

        let asset = *assets_copy.pop_front().unwrap();
        expected_events.append(
            (
                cultivator.contract_address,
                cultivator_contract::Event::Collect(
                    cultivator_contract::Collect {
                        asset,
                        fees: array![
                            AssetBalance {
                                address: *seed.pool_key.token0,
                                amount: before.fees0,
                            },
                            AssetBalance {
                                address: *seed.pool_key.token1,
                                amount: before.fees1,
                            },
                        ]
                            .span(),
                    },
                ),
            ),
        );
    }    
    
    cultivator.collect();

    for seed in seeds {
        assert_pool_fees_collected(test_config, *seed);
    }

    spy.assert_emitted(@expected_events);
}
