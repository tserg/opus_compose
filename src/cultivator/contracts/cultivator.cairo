#[starknet::contract]
pub mod cultivator {
    use access_control::access_control_component;
    use core::cmp::minmax;
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use ekubo::interfaces::extensions::twamm::{OrderInfo, OrderKey};
    use ekubo::interfaces::positions::{
        GetTokenInfoResult, IPositionsDispatcher, IPositionsDispatcherTrait,
    };
    use ekubo::types::delta::Delta;
    use opus_compose::cultivator::interfaces::cultivator::ICultivator;
    use opus_compose::cultivator::roles::cultivator_roles;
    use opus_compose::cultivator::types::{Order, Seed, StorageSeed};
    use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use wadray::WAD_ONE;

    //
    // Constants
    ///

    pub const TWAP_ORDER_PERIOD: u64 = 24 * 60 * 60; // 24 hours
    pub const YIN_CULTIVATE_THRESHOLD: u128 = 10 * WAD_ONE;

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic =
        access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;


    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        yin: IERC20Dispatcher,
        ekubo_core: ICoreDispatcher,
        ekubo_positions: IPositionsDispatcher,
        ekubo_positions_nft: IERC721Dispatcher,
        assets_count: u64,
        // Mapping of assets to asset IDs
        asset_ids: Map<ContractAddress, u64>,
        // Mapping of asset IDs to Seed structs (LP details)
        seeds: Map<u64, StorageSeed>,
        // Mapping of asset IDs to TWAMM Order structs
        twamm_orders: Map<u64, Order>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        Collect: Collect,
        Cultivate: Cultivate,
        Extract: Extract,
        OrderPlaced: OrderPlaced,
        OrderClosed: OrderClosed,
        Plant: Plant,
        Prune: Prune,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Cultivate {
        #[key]
        pub asset: ContractAddress,
        pub seed: Seed,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Collect {
        #[key]
        pub asset: ContractAddress,
        pub delta: Delta,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Extract {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub asset: ContractAddress,
        pub amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct OrderPlaced {
        #[key]
        pub asset: ContractAddress,
        pub order_id: u64,
        pub fee: u128,
        pub end_time: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct OrderClosed {
        #[key]
        pub asset: ContractAddress,
        pub order_id: u64,
        pub fee: u128,
        pub end_time: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Plant {
        #[key]
        pub asset: ContractAddress,
        pub seed: Seed,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Prune {
        #[key]
        pub asset: ContractAddress,
        pub seed: Seed,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        yin: ContractAddress,
        ekubo_core: ContractAddress,
        ekubo_positions: ContractAddress,
        ekubo_positions_nft: ContractAddress,
    ) {
        self.access_control.initializer(admin, Option::Some(cultivator_roles::ADMIN));

        self.yin.write(IERC20Dispatcher { contract_address: yin });
        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.ekubo_positions.write(IPositionsDispatcher { contract_address: ekubo_positions });
        self.ekubo_positions_nft.write(IERC721Dispatcher { contract_address: ekubo_positions_nft });
    }

    //
    // External Cultivator functions
    //

    #[abi(embed_v0)]
    impl ICultivatorImpl of ICultivator<ContractState> {
        // Returns a list of assets with active positions
        fn get_assets(self: @ContractState) -> Span<ContractAddress> {
            let mut idx: u64 = self.assets_count.read();
            let mut assets: Array<ContractAddress> = Default::default();
            while idx != 0 {
                let seed: Seed = self.seeds.read(idx).into();
                if seed.token_id.is_non_zero() {
                    assets.append(self.get_asset_from_seed(seed));
                }
                idx -= 1;
            }
            assets.span()
        }

        fn get_seed(self: @ContractState, asset: ContractAddress) -> Seed {
            let asset_id: u64 = self.asset_ids.read(asset);
            self.seeds.read(asset_id).into()
        }

        //
        // External functions
        //

        fn plant(ref self: ContractState, asset: ContractAddress, seed: Seed) {
            self.access_control.assert_has_role(cultivator_roles::PLANT);
            let caller = get_caller_address();

            // Assert caller is owner of position NFT
            let ekubo_positions_nft = self.ekubo_positions_nft.read();
            assert!(ekubo_positions_nft.owner_of(seed.token_id.into()) == caller, "CUL: Not owner");

            // Assert pool key is for yin and asset
            assert!(
                minmax(
                    asset, self.yin.read().contract_address,
                ) == minmax(seed.pool_key.token0, seed.pool_key.token1),
                "CUL: Pool key assets mismatch",
            );

            // Assert position has liquidity
            let position: GetTokenInfoResult = self
                .ekubo_positions
                .read()
                .get_token_info(seed.token_id.into(), seed.pool_key, seed.bounds);
            assert!(position.liquidity.is_non_zero(), "CUL: No liquidity found");

            // If asset has not been added, update the count of assets.
            // Otherwise, if asset has been added, assert no existing position for asset.
            let mut asset_id: u64 = self.asset_ids.read(asset);
            if asset_id == 0 {
                let updated_assets_count = self.assets_count.read() + 1;
                self.assets_count.write(updated_assets_count);

                asset_id = updated_assets_count;
                self.asset_ids.write(asset, asset_id);
            } else {
                let current_seed: Seed = self.seeds.read(asset_id).into();
                assert!(current_seed == Default::default(), "CUL: Position exist");
            }

            // Update storage
            self.seeds.write(asset_id, seed.into());

            // Transfer position NFT
            let cultivator = get_contract_address();
            assert!(
                ekubo_positions_nft.get_approved(seed.token_id.into()) == cultivator,
                "CUL: Token not approved",
            );
            ekubo_positions_nft.transfer_from(caller, cultivator, seed.token_id.into());

            self.emit(Plant { asset, seed });
        }

        fn prune(ref self: ContractState, asset: ContractAddress) {
            self.access_control.assert_has_role(cultivator_roles::PRUNE);
            let caller = get_caller_address();

            let asset_id: u64 = self.asset_ids.read(asset);
            let seed: Seed = self.seeds.read(asset_id).into();

            let zero_seed: Seed = Default::default();
            assert!(seed.token_id.is_non_zero(), "CUL: No seed for asset");

            // Update storage
            self.seeds.write(asset_id, zero_seed.into());

            // Transfer NFT to user
            self
                .ekubo_positions_nft
                .read()
                .transfer_from(get_contract_address(), caller, seed.token_id.into());

            self.emit(Prune { asset, seed });
        }

        fn cultivate(ref self: ContractState, asset: Option<ContractAddress>) {
            self.access_control.assert_has_role(cultivator_roles::CULTIVATE);

            let ts: u64 = get_block_timestamp();

            let (asset_id, asset, seed) = if asset.is_some() {
                let asset = asset.unwrap();
                let asset_id = self.asset_ids.read(asset);
                let seed: Seed = self.seeds.read(asset_id).into();
                assert!(seed.token_id.is_non_zero(), "CUL: No seed for asset");
                (asset_id, asset, seed)
            } else {
                let mut asset_id: u64 = Zero::zero();
                let mut asset: ContractAddress = Zero::zero();
                let mut seed: Seed = Default::default();
                let mut divisor: u64 = self.assets_count.read().into();
                while divisor != 0 {
                    let id: u64 = ts % divisor;

                    let seed: Seed = self.seeds.read(id).into();
                    if seed.token_id.is_non_zero() {
                        asset_id = id;
                        asset = self.get_asset_from_seed(seed);
                        break;
                    }

                    divisor -= 1;
                }

                (Zero::zero(), Zero::zero(), seed)
            };

            if asset.is_zero() {
                return;
            }

            let cultivator = get_contract_address();
            let yin = self.yin.read();
            let asset_erc20 = IERC20Dispatcher { contract_address: asset };
            let ekubo_positions = self.ekubo_positions.read();

            // Collect accrued LP fees
            self.collect_fees_helper(seed);
            
            // Withdraw any existing TWAP orders
            let mut can_create_new_order: bool = true;
            let existing_order: Order = self.twamm_orders.read(asset_id);
            if existing_order.order_id.is_non_zero() {
                let existing_order_key = OrderKey {
                    sell_token: yin.contract_address,
                    buy_token: asset,
                    fee: seed.pool_key.fee,
                    start_time: 0,
                    end_time: existing_order.end_time,
                };

                ekubo_positions
                    .withdraw_proceeds_from_sale_to_self(
                        existing_order.order_id, existing_order_key,
                    );

                // Reset the order if it is completed
                let order_info: OrderInfo = ekubo_positions
                    .get_order_info(existing_order.order_id, existing_order_key);
                if order_info.remaining_sell_amount == 0 {
                    self.twamm_orders.write(asset_id, Default::default());
                    self
                        .emit(
                            OrderClosed {
                                asset,
                                order_id: existing_order.order_id,
                                fee: existing_order_key.fee,
                                end_time: existing_order_key.end_time,
                            },
                        );
                } else {
                    can_create_new_order = false;
                }
            }

            // Provide liquidity
            yin.transfer(ekubo_positions.contract_address, yin.balance_of(cultivator));
            asset_erc20
                .transfer(ekubo_positions.contract_address, asset_erc20.balance_of(cultivator));

            ekubo_positions.deposit(seed.token_id, seed.pool_key, seed.bounds, 1);
            let ekubo_positions_clear = IClearDispatcher {
                contract_address: ekubo_positions.contract_address,
            };

            ekubo_positions_clear
                .clear(EkuboERC20Dispatcher { contract_address: yin.contract_address });
            ekubo_positions_clear
                .clear(EkuboERC20Dispatcher { contract_address: asset_erc20.contract_address });

            // Create a TWAP order for leftover yin if there is no existing TWAP order
            let yin_balance = yin.balance_of(cultivator);
            if yin_balance > YIN_CULTIVATE_THRESHOLD.into() && can_create_new_order {
                yin.transfer(ekubo_positions.contract_address, yin_balance);
                let end_time: u64 = ts + TWAP_ORDER_PERIOD;
                let (order_id, sale_rate) = ekubo_positions
                    .mint_and_increase_sell_amount(
                        OrderKey {
                            sell_token: yin.contract_address,
                            buy_token: asset,
                            fee: seed.pool_key.fee,
                            start_time: 0,
                            end_time,
                        },
                        yin_balance.try_into().unwrap(),
                    );

                self.twamm_orders.write(asset_id, Order { order_id, sale_rate, end_time });

                self.emit(OrderPlaced { asset, order_id, fee: seed.pool_key.fee, end_time });
            }

            self.emit(Cultivate { asset, seed });
        }

        // Withdraw all LP fees to this contract
        fn collect(ref self: ContractState) {
            let mut idx: u64 = self.assets_count.read();
            while idx != 0 {
                let seed: Seed = self.seeds.read(idx).into();
                if seed.token_id.is_non_zero() {
                    self.collect_fees_helper(seed);
                }
                idx -= 1;
            }
        }

        // Transfer the contract's balance for a specific asset to the caller
        fn extract(ref self: ContractState, asset: ContractAddress) {
            self.access_control.assert_has_role(cultivator_roles::EXTRACT);

            let asset_erc20 = IERC20Dispatcher { contract_address: asset };
            let caller: ContractAddress = get_caller_address();

            let amount: u256 = asset_erc20.balance_of(get_contract_address());
            asset_erc20.transfer(caller, amount);

            self.emit(Extract { caller, asset, amount });
        }
    }

    #[generate_trait]
    impl CultivatorHelpers of CultivatorHelpersTrait {
        fn get_asset_from_seed(self: @ContractState, seed: Seed) -> ContractAddress {
            let yin: ContractAddress = self.yin.read().contract_address;
            if seed.pool_key.token0 == yin {
                seed.pool_key.token1
            } else {
                seed.pool_key.token0
            }
        }

        fn collect_fees_helper(ref self: ContractState, seed: Seed) {
            let delta: Delta = self.ekubo_core.read().collect_fees(seed.pool_key, seed.token_id.into(), seed.bounds);
            self.emit(Collect { asset: self.get_asset_from_seed(seed), delta });
        }
    }
}
