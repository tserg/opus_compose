pub mod cultivator_utils {
    use core::cmp::minmax;
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::core::{GetPositionWithFeesResult, ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use ekubo::interfaces::extensions::twamm::{OrderInfo, OrderKey};
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::interfaces::router::{
        IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount,
    };
    use ekubo::types::bounds::Bounds;
    use ekubo::types::delta::Delta;
    use ekubo::types::i129::i129;
    use ekubo::types::keys::{PoolKey, PositionKey};
    use opus_compose::addresses::mainnet;
    use opus_compose::cultivator::interfaces::cultivator::{
        ICultivatorDispatcher, ICultivatorDispatcherTrait,
    };
    use opus_compose::cultivator::types::{Order, Seed};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use snforge_std::{
        CheatSpan, ContractClass, ContractClassTrait, DeclareResultTrait, cheat_caller_address,
        declare,
    };
    use starknet::ContractAddress;
    use wadray::WAD_ONE;

    // Custom test types

    #[derive(Copy, Drop)]
    pub struct CultivatorTestConfig {
        pub cultivator: ICultivatorDispatcher,
        pub yin: IERC20Dispatcher,
        pub ekubo_core: ICoreDispatcher,
        pub ekubo_positions: IPositionsDispatcher,
        pub ekubo_positions_nft: IERC721Dispatcher,
    }

    // Constants
    const TWAMM_BOUNDS: Bounds = Bounds {
        lower: i129 { mag: 88368108, sign: true }, upper: i129 { mag: 88368108, sign: false },
    };

    const INITIAL_CASH_LP_AMT: u128 = 50 * WAD_ONE;
    const INITIAL_EKUBO_LP_AMT: u128 = 5 * WAD_ONE;
    const INITIAL_STRK_LP_AMT: u128 = 500 * WAD_ONE;
    const INITIAL_LORDS_LP_AMT: u128 = 2000 * WAD_ONE;

    const CASH_SWAP_AMT: u128 = WAD_ONE;

    pub const BAD_GUY: ContractAddress = 'bad guy'.try_into().unwrap();

    pub const ASSETS: [ContractAddress; 3] = [mainnet::EKUBO, mainnet::LORDS, mainnet::STRK];

    //
    // Test setup helpers
    //

    // Assume that the TWAMM pools use the same configuration of 0.3% fee
    fn construct_pool_key(asset: ContractAddress) -> PoolKey {
        let (token0, token1) = minmax(mainnet::SHRINE, asset);

        let fee = if asset == mainnet::LORDS {
            3402823669209384634633746074317682114 // 1%
        } else {
            1020847100762815411640772995208708096 // 0.3%
        };

        PoolKey {
            token0, token1, fee, tick_spacing: 354892, extension: mainnet::EKUBO_TWAMM_EXTENSION,
        }
    }

    pub fn setup(cultivator_class: Option<ContractClass>) -> CultivatorTestConfig {
        let cultivator_class = match cultivator_class {
            Option::Some(class) => class,
            Option::None => *(declare("cultivator").unwrap().contract_class()),
        };

        let mut calldata: Array<felt252> = array![
            mainnet::MULTISIG.into(),
            mainnet::SHRINE.into(),
            mainnet::EKUBO_POSITIONS.into(),
            mainnet::EKUBO_POSITIONS_NFT.into(),
        ];
        let (cultivator_addr, _) = cultivator_class.deploy(@calldata).unwrap();

        // Seed multisig with some STRK and LORDS
        cheat_caller_address(mainnet::LORDS, mainnet::LORDS_WHALE, CheatSpan::TargetCalls(1));
        IERC20Dispatcher { contract_address: mainnet::LORDS }
            .transfer(mainnet::MULTISIG, (10000 * WAD_ONE).into());

        cheat_caller_address(mainnet::STRK, mainnet::WHALE, CheatSpan::TargetCalls(1));
        IERC20Dispatcher { contract_address: mainnet::STRK }
            .transfer(mainnet::MULTISIG, (1000 * WAD_ONE).into());

        CultivatorTestConfig {
            cultivator: ICultivatorDispatcher { contract_address: cultivator_addr },
            yin: IERC20Dispatcher { contract_address: mainnet::SHRINE },
            ekubo_core: ICoreDispatcher { contract_address: mainnet::EKUBO_CORE },
            ekubo_positions: IPositionsDispatcher { contract_address: mainnet::EKUBO_POSITIONS },
            ekubo_positions_nft: IERC721Dispatcher {
                contract_address: mainnet::EKUBO_POSITIONS_NFT,
            },
        }
    }

    //
    // Simulation helpers
    //

    pub fn create_lp_for_asset(
        test_config: CultivatorTestConfig, user: ContractAddress, asset: ContractAddress,
    ) -> (Seed, u128) {
        let pool_key = construct_pool_key(asset);

        cheat_caller_address(test_config.yin.contract_address, user, CheatSpan::TargetCalls(1));
        test_config.yin.transfer(mainnet::EKUBO_POSITIONS, INITIAL_CASH_LP_AMT.into());

        cheat_caller_address(asset, user, CheatSpan::TargetCalls(1));
        let asset_amt = if asset == mainnet::LORDS {
            INITIAL_LORDS_LP_AMT
        } else if asset == mainnet::STRK {
            INITIAL_STRK_LP_AMT
        } else {
            INITIAL_EKUBO_LP_AMT
        };
        IERC20Dispatcher { contract_address: asset }
            .transfer(mainnet::EKUBO_POSITIONS, asset_amt.into());

        cheat_caller_address(
            test_config.ekubo_positions.contract_address, user, CheatSpan::TargetCalls(1),
        );
        let (token_id, liquidity) = test_config
            .ekubo_positions
            .mint_and_deposit(pool_key, TWAMM_BOUNDS, 1);

        cheat_caller_address(
            test_config.ekubo_positions.contract_address, user, CheatSpan::TargetCalls(2),
        );
        let ekubo_positions_clear = IClearDispatcher { contract_address: mainnet::EKUBO_POSITIONS };
        ekubo_positions_clear.clear(EkuboERC20Dispatcher { contract_address: mainnet::SHRINE });
        ekubo_positions_clear.clear(EkuboERC20Dispatcher { contract_address: asset });

        (Seed { token_id, pool_key, bounds: TWAMM_BOUNDS }, liquidity)
    }

    pub fn create_lp_and_plant_assets(test_config: CultivatorTestConfig, user: ContractAddress, assets: Span<ContractAddress>) -> Span<Seed> {
        let mut seeds: Array<Seed> = Default::default();

        for asset in assets {
            let (seed, _) = create_lp_for_asset(test_config, user, *asset);
            seeds.append(seed);

            cheat_caller_address(mainnet::EKUBO_POSITIONS_NFT, user, CheatSpan::TargetCalls(1));
            test_config.ekubo_positions_nft.approve(test_config.cultivator.contract_address, seed.token_id.into());

            cheat_caller_address(test_config.cultivator.contract_address, user, CheatSpan::TargetCalls(1));
            test_config.cultivator.plant(*asset, seed);
        }

        seeds.span()
    }

    // Returns the LP position after swaps
    pub fn generate_ekubo_lp_fees(
        test_config: CultivatorTestConfig, seed: Seed,
    ) -> GetPositionWithFeesResult {
        let user = mainnet::MULTISIG;

        let pool_price = test_config.ekubo_core.get_pool_price(seed.pool_key);

        let position_key = PositionKey {
            salt: seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: seed.bounds,
        };
        let before: GetPositionWithFeesResult = test_config
            .ekubo_core
            .get_position_with_fees(seed.pool_key, position_key);

        cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
        test_config.yin.transfer(mainnet::EKUBO_ROUTER, CASH_SWAP_AMT.into());

        let ekubo_router = IRouterDispatcher { contract_address: mainnet::EKUBO_ROUTER };

        // yin is token0
        if seed.pool_key.token0 == mainnet::SHRINE {
            let asset = seed.pool_key.token1;

            cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
            let delta: Delta = ekubo_router
                .swap(
                    node: RouteNode {
                        pool_key: seed
                            .pool_key, // Selling token0 will increase the token0 balance of the pool, so sqrt ratio will
                        // decrease
                        sqrt_ratio_limit: pool_price.sqrt_ratio / 2,
                        skip_ahead: 0,
                    },
                    token_amount: TokenAmount {
                        token: mainnet::SHRINE, amount: CASH_SWAP_AMT.into(),
                    },
                );

            cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
            ekubo_router
                .swap(
                    node: RouteNode {
                        pool_key: seed
                            .pool_key, // Selling token1 will increase the token1 balance of the pool, so sqrt ratio will
                        // increase
                        sqrt_ratio_limit: pool_price.sqrt_ratio * 2,
                        skip_ahead: 0,
                    },
                    token_amount: TokenAmount { token: asset, amount: -(delta.amount1) },
                );
        } else {
            let asset = seed.pool_key.token0;

            cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
            let delta: Delta = ekubo_router
                .swap(
                    node: RouteNode {
                        pool_key: seed
                            .pool_key, // Selling token1 will increase the token1 balance of the pool, so sqrt ratio will
                        // increase
                        sqrt_ratio_limit: pool_price.sqrt_ratio * 2,
                        skip_ahead: 0,
                    },
                    token_amount: TokenAmount {
                        token: mainnet::SHRINE, amount: CASH_SWAP_AMT.into(),
                    },
                );

            cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
            ekubo_router
                .swap(
                    node: RouteNode {
                        pool_key: seed
                            .pool_key, // Selling token0 will increase the token0 balance of the pool, so sqrt ratio will
                        // decrease
                        sqrt_ratio_limit: pool_price.sqrt_ratio / 2,
                        skip_ahead: 0,
                    },
                    token_amount: TokenAmount { token: asset, amount: -(delta.amount0) },
                );
        }

        let after: GetPositionWithFeesResult = test_config
            .ekubo_core
            .get_position_with_fees(seed.pool_key, position_key);

        assert!(before.fees0 < after.fees0, "t0 fees did not increase after swap");
        assert!(before.fees1 < after.fees1, "t1 fees did not increase after swap");

        after
    }

    //
    // Assertion helpers
    //

    pub fn check_existing_order_completion(
        test_config: CultivatorTestConfig,
        asset: ContractAddress,
        seed: Seed,
        should_be_completed: bool,
    ) {
        let order: Option<Order> = test_config.cultivator.get_order(asset);
        let order = order.expect('no order found');
        let order_key = OrderKey {
            sell_token: test_config.yin.contract_address,
            buy_token: asset,
            fee: seed.pool_key.fee,
            start_time: 0,
            end_time: order.end_time,
        };
        let order_info: OrderInfo = test_config
            .ekubo_positions
            .get_order_info(seed.token_id, order_key);
        if should_be_completed {
            assert!(order_info.remaining_sell_amount.is_zero(), "order not completed");
        } else if !should_be_completed {
            assert!(order_info.remaining_sell_amount.is_non_zero(), "order completed");
        }
    }

    pub fn assert_pool_fees_collected(test_config: CultivatorTestConfig, seed: Seed) {
        let position_key = PositionKey {
            salt: seed.token_id, owner: mainnet::EKUBO_POSITIONS, bounds: seed.bounds,
        };
        let position_with_fees: GetPositionWithFeesResult = test_config
            .ekubo_core
            .get_position_with_fees(seed.pool_key, position_key);
        assert!(position_with_fees.fees0.is_zero(), "fees not zeroed #1");
        assert!(position_with_fees.fees1.is_zero(), "fees not zeroed #2");
    }
}
