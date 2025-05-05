pub mod cultivator_utils {
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::core::{GetPositionWithFeesResult, ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::erc721::IERC721Dispatcher;
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
        pub ekubo_token: IERC20Dispatcher,
        pub ekubo_core: ICoreDispatcher,
        pub ekubo_positions: IPositionsDispatcher,
        pub ekubo_positions_nft: IERC721Dispatcher,
    }

    // Constants

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

    const INITIAL_CASH_LP_AMT: u128 = 50 * WAD_ONE;
    const INITIAL_EKUBO_LP_AMT: u128 = 5 * WAD_ONE;

    const CASH_SWAP_AMT: u128 = WAD_ONE;

    pub const BAD_GUY: ContractAddress = 'bad guy'.try_into().unwrap();

    //
    // Test setup helpers
    //

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

        CultivatorTestConfig {
            cultivator: ICultivatorDispatcher { contract_address: cultivator_addr },
            yin: IERC20Dispatcher { contract_address: mainnet::SHRINE },
            ekubo_token: IERC20Dispatcher { contract_address: mainnet::EKUBO },
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

    pub fn create_cash_ekubo_lp(test_config: CultivatorTestConfig) -> (Seed, u128) {
        let user = mainnet::MULTISIG;

        cheat_caller_address(test_config.yin.contract_address, user, CheatSpan::TargetCalls(1));
        test_config.yin.transfer(mainnet::EKUBO_POSITIONS, INITIAL_CASH_LP_AMT.into());

        cheat_caller_address(
            test_config.ekubo_token.contract_address, user, CheatSpan::TargetCalls(1),
        );
        test_config.ekubo_token.transfer(mainnet::EKUBO_POSITIONS, INITIAL_EKUBO_LP_AMT.into());

        cheat_caller_address(
            test_config.ekubo_positions.contract_address, user, CheatSpan::TargetCalls(1),
        );
        let (token_id, liquidity) = test_config
            .ekubo_positions
            .mint_and_deposit(CASH_EKUBO_TWAMM_POOL_KEY, TWAMM_BOUNDS, 1);

        cheat_caller_address(
            test_config.ekubo_positions.contract_address, user, CheatSpan::TargetCalls(2),
        );
        let ekubo_positions_clear = IClearDispatcher { contract_address: mainnet::EKUBO_POSITIONS };
        ekubo_positions_clear.clear(EkuboERC20Dispatcher { contract_address: mainnet::SHRINE });
        ekubo_positions_clear.clear(EkuboERC20Dispatcher { contract_address: mainnet::EKUBO });

        (Seed { token_id, pool_key: CASH_EKUBO_TWAMM_POOL_KEY, bounds: TWAMM_BOUNDS }, liquidity)
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
        let before_position_with_fees: GetPositionWithFeesResult = test_config
            .ekubo_core
            .get_position_with_fees(seed.pool_key, position_key);

        cheat_caller_address(mainnet::SHRINE, user, CheatSpan::TargetCalls(1));
        test_config.yin.transfer(mainnet::EKUBO_ROUTER, CASH_SWAP_AMT.into());

        cheat_caller_address(mainnet::EKUBO_ROUTER, user, CheatSpan::TargetCalls(1));
        let ekubo_router = IRouterDispatcher { contract_address: mainnet::EKUBO_ROUTER };
        let delta: Delta = ekubo_router
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
        ekubo_router
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

        let after_position_with_fees: GetPositionWithFeesResult = test_config
            .ekubo_core
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
        } else {
            assert!(order_info.remaining_sell_amount.is_non_zero(), "order completed");
        }
    }
}
