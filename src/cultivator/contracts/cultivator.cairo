#[starknet::contract]
pub mod cultivator {
    use access_control::access_control_component;
    use core::cmp::minmax;
    use core::num::traits::Zero;
    use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as EkuboERC20Dispatcher;
    use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use ekubo::interfaces::extensions::twamm::OrderKey;
    use ekubo::interfaces::positions::{
        GetTokenInfoResult, IPositionsDispatcher, IPositionsDispatcherTrait,
    };
    use opus::types::AssetBalance;
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

    const LOOP_START: u64 = 1;

    pub const TWAMM_ORDER_STEP_SIZE: u64 = 65536;
    pub const TWAMM_ORDER_PERIOD: u64 = 131072; // ~18 to 36 hours
    pub const MINIMUM_YIN_TO_CREATE_ORDER: u128 = 10 * WAD_ONE;

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
        ekubo_positions: IPositionsDispatcher,
        ekubo_positions_nft: IERC721Dispatcher,
        // Number of assets planted; used internally only.
        // Note that this is not decremented when assets are pruned.
        assets_count: u64,
        // Mapping of assets to asset IDs; used internally only.
        asset_ids: Map<ContractAddress, u64>,
        // Mapping of asset IDs to Seed structs (LP details)
        // Starts from index 1
        seeds: Map<u64, StorageSeed>,
        // Mapping of asset IDs to TWAMM Order structs
        // Starts from index 1
        orders: Map<u64, Order>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        Collect: Collect,
        Extract: Extract,
        OrderPlaced: OrderPlaced,
        OrderClosed: OrderClosed,
        Plant: Plant,
        Prune: Prune,
        Supply: Supply,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Collect {
        #[key]
        pub asset: ContractAddress,
        pub fees: Span<AssetBalance>,
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

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct Supply {
        #[key]
        pub asset: ContractAddress,
        pub seed: Seed,
        pub deposited: Span<AssetBalance>,
        pub liquidity_delta: u128,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        yin: ContractAddress,
        ekubo_positions: ContractAddress,
        ekubo_positions_nft: ContractAddress,
    ) {
        self.access_control.initializer(admin, Option::Some(cultivator_roles::ADMIN));

        self.yin.write(IERC20Dispatcher { contract_address: yin });
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
            let mut idx: u64 = LOOP_START;
            let loop_end: u64 = self.assets_count.read() + LOOP_START;
            let mut assets: Array<ContractAddress> = Default::default();
            while idx != loop_end {
                if let Some(seed) = self.get_seed_helper(idx) {
                    assets.append(self.get_asset_from_seed(seed));
                }
                idx += 1;
            }
            assets.span()
        }

        fn get_order(self: @ContractState, asset: ContractAddress) -> Option<Order> {
            self.get_order_helper(self.asset_ids.read(asset))
        }

        fn get_seed(self: @ContractState, asset: ContractAddress) -> Option<Seed> {
            self.get_seed_helper(self.asset_ids.read(asset))
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
                asset_id = self.assets_count.read() + 1;
                self.assets_count.write(asset_id);
                self.asset_ids.write(asset, asset_id);
            } else {
                assert!(self.get_seed_helper(asset_id).is_none(), "CUL: Position exist");
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

            let (asset_id, seed) = self.get_valid_asset_id_and_seed(asset);

            self.withdraw_proceeds_and_close_twamm_order(asset, asset_id, seed, true);

            // Reset current Seed to default
            let zero_seed: Seed = Default::default();
            self.seeds.write(asset_id, zero_seed.into());

            // Transfer NFT to user
            self
                .ekubo_positions_nft
                .read()
                .transfer_from(get_contract_address(), get_caller_address(), seed.token_id.into());

            self.emit(Prune { asset, seed });
        }

        // Grows a LP position by performing three distinct actions:
        // 1. Collect accrued fees from the LP position
        // 2. Adding liquidity to the LP position
        // 3. Creating a TWAMM order for excess yin
        // Returns a tuple of:
        // - An array of assets added as liquidity to the LP
        // - Liquidity added to the LP
        // An empty array and zero value is returned if:
        // - the asset is not specified and no assets were planted; or
        // - the contract's yin balance is zero after collecting LP fees.
        fn cultivate(
            ref self: ContractState, asset: Option<ContractAddress>,
        ) -> (Span<AssetBalance>, u128) {
            self.access_control.assert_has_role(cultivator_roles::CULTIVATE);

            let (asset_id, asset, seed) = if asset.is_some() {
                let asset = asset.unwrap();
                let (asset_id, seed) = self.get_valid_asset_id_and_seed(asset);
                (asset_id, asset, seed)
            } else {
                self.pick_asset_to_cultivate()
            };

            let mut deposited: Span<AssetBalance> = array![].span();
            let mut liquidity_delta: u128 = Zero::zero();

            if asset.is_zero() {
                return (deposited, liquidity_delta);
            }

            let cultivator = get_contract_address();
            let yin = self.yin.read();

            // Collect accrued LP fees
            self.collect_fees_helper(seed);

            // Withdraw proceeds if there is an existing TWAMM order
            let can_create_new_order: bool = self
                .withdraw_proceeds_and_close_twamm_order(asset, asset_id, seed, false);

            // Early return if there is no yin because we can neither provide liquidity
            // or create a TWAMM order
            let mut yin_balance = yin.balance_of(cultivator);
            if yin_balance.is_zero() {
                return (deposited, liquidity_delta);
            }

            let ekubo_positions = self.ekubo_positions.read();

            // Auto-compound LP position if there is some asset and yin
            let asset_erc20 = IERC20Dispatcher { contract_address: asset };
            let asset_balance = asset_erc20.balance_of(cultivator);
            if asset_balance.is_non_zero() {
                yin.transfer(ekubo_positions.contract_address, yin_balance);
                asset_erc20.transfer(ekubo_positions.contract_address, asset_balance);

                liquidity_delta = ekubo_positions
                    .deposit(seed.token_id, seed.pool_key, seed.bounds, 1);

                let ekubo_positions_clear = IClearDispatcher {
                    contract_address: ekubo_positions.contract_address,
                };
                let refunded_yin: u256 = ekubo_positions_clear
                    .clear(EkuboERC20Dispatcher { contract_address: yin.contract_address });
                let refunded_asset: u256 = ekubo_positions_clear
                    .clear(EkuboERC20Dispatcher { contract_address: asset });

                deposited =
                    array![
                        AssetBalance {
                            address: yin.contract_address,
                            amount: (yin_balance - refunded_yin).try_into().unwrap(),
                        },
                        AssetBalance {
                            address: asset,
                            amount: (asset_balance - refunded_asset).try_into().unwrap(),
                        },
                    ]
                    .span();
                self.emit(Supply { asset, seed, deposited, liquidity_delta });

                yin_balance = refunded_yin;
            }

            // Create a TWAMM order for yin remaining in the contract if there is no existing TWAMM
            // order
            if yin_balance > MINIMUM_YIN_TO_CREATE_ORDER.into() && can_create_new_order {
                yin.transfer(ekubo_positions.contract_address, yin_balance);

                let ts: u64 = get_block_timestamp();
                let end_time: u64 = ts + TWAMM_ORDER_PERIOD - ts % TWAMM_ORDER_STEP_SIZE;

                // Reuse the LP position NFT for the TWAMM order
                let sale_rate: u128 = ekubo_positions
                    .increase_sell_amount(
                        seed.token_id,
                        self.construct_twamm_order_key(asset, seed.pool_key.fee, end_time),
                        yin_balance.try_into().unwrap(),
                    );

                self.orders.write(asset_id, Order { sale_rate, end_time });

                self
                    .emit(
                        OrderPlaced {
                            asset, order_id: seed.token_id, fee: seed.pool_key.fee, end_time,
                        },
                    );
            }

            (deposited, liquidity_delta)
        }

        // Withdraw all LP fees to this contract
        fn collect(ref self: ContractState) {
            let mut idx: u64 = LOOP_START;
            let loop_end: u64 = self.assets_count.read() + LOOP_START;
            while idx != loop_end {
                if let Some(seed) = self.get_seed_helper(idx) {
                    self.collect_fees_helper(seed);
                }
                idx += 1;
            }
        }

        // Transfer the contract's balance for a specific asset to the caller
        fn extract(ref self: ContractState, asset: ContractAddress) -> u256 {
            self.access_control.assert_has_role(cultivator_roles::EXTRACT);

            let asset_erc20 = IERC20Dispatcher { contract_address: asset };
            let amount: u256 = asset_erc20.balance_of(get_contract_address());
            if amount.is_zero() {
                return 0;
            }

            let caller: ContractAddress = get_caller_address();
            asset_erc20.transfer(caller, amount);

            self.emit(Extract { caller, asset, amount });

            amount
        }
    }

    #[generate_trait]
    impl CultivatorHelpers of CultivatorHelpersTrait {
        fn get_order_helper(self: @ContractState, asset_id: u64) -> Option<Order> {
            let order: Order = self.orders.read(asset_id);
            match order.end_time {
                0 => Option::None,
                _ => Option::Some(order),
            }
        }

        fn get_seed_helper(self: @ContractState, asset_id: u64) -> Option<Seed> {
            let seed: Seed = self.seeds.read(asset_id).into();
            match seed.token_id {
                0 => Option::None,
                _ => Option::Some(seed),
            }
        }

        fn get_asset_from_seed(self: @ContractState, seed: Seed) -> ContractAddress {
            let yin: ContractAddress = self.yin.read().contract_address;
            if seed.pool_key.token0 == yin {
                seed.pool_key.token1
            } else {
                seed.pool_key.token0
            }
        }

        fn get_valid_asset_id_and_seed(
            self: @ContractState, asset: ContractAddress,
        ) -> (u64, Seed) {
            let asset_id = self.asset_ids.read(asset);
            let seed = self.get_seed_helper(asset_id);
            assert!(seed.is_some(), "CUL: No seed for asset");
            (asset_id, seed.unwrap())
        }

        fn pick_asset_to_cultivate(self: @ContractState) -> (u64, ContractAddress, Seed) {
            let ts: u64 = get_block_timestamp();

            let mut divisor: u64 = self.assets_count.read().into();
            while divisor != 0 {
                // Asset ID starts from 1
                let id: u64 = (ts % divisor) + 1;

                if let Some(seed) = self.get_seed_helper(id) {
                    return (id, self.get_asset_from_seed(seed), seed);
                }

                divisor -= 1;
            }

            (Zero::zero(), Zero::zero(), Default::default())
        }

        fn construct_twamm_order_key(
            self: @ContractState, asset: ContractAddress, fee: u128, end_time: u64,
        ) -> OrderKey {
            OrderKey {
                sell_token: self.yin.read().contract_address,
                buy_token: asset,
                fee,
                start_time: 0,
                end_time,
            }
        }

        fn collect_fees_helper(ref self: ContractState, seed: Seed) {
            let (fees0, fees1) = self
                .ekubo_positions
                .read()
                .collect_fees(seed.token_id.into(), seed.pool_key, seed.bounds);

            if fees0.is_zero() && fees1.is_zero() {
                return;
            }

            self
                .emit(
                    Collect {
                        asset: self.get_asset_from_seed(seed),
                        fees: array![
                            AssetBalance { address: seed.pool_key.token0, amount: fees0 },
                            AssetBalance { address: seed.pool_key.token1, amount: fees1 },
                        ]
                            .span(),
                    },
                );
        }

        // Withdraws proceeds from an existing TWAMM order.
        // Checks if a TWAMM order exists and closes it if certain conditions are met.
        // Returns a boolean of whether the TWAMM order for the asset was closed.
        fn withdraw_proceeds_and_close_twamm_order(
            ref self: ContractState,
            asset: ContractAddress,
            asset_id: u64,
            seed: Seed,
            force_closure: bool,
        ) -> bool {
            let ekubo_positions = self.ekubo_positions.read();

            let order: Option<Order> = self.get_order_helper(asset_id);

            // Early return for completed orders, whether a forced closure or not
            if order.is_none() {
                return true;
            }

            let order: Order = order.unwrap();
            let order_key: OrderKey = self
                .construct_twamm_order_key(asset, seed.pool_key.fee, order.end_time);

            ekubo_positions.withdraw_proceeds_from_sale_to_self(seed.token_id, order_key);

            let order_is_completed: bool = get_block_timestamp() > order.end_time;
            if !order_is_completed {
                if force_closure {
                    ekubo_positions
                        .decrease_sale_rate_to_self(seed.token_id, order_key, order.sale_rate);
                } else {
                    // Early return for ongoing orders without forced closure
                    return false;
                }
            }

            self.orders.write(asset_id, Default::default());

            self
                .emit(
                    OrderClosed {
                        asset,
                        order_id: seed.token_id,
                        fee: seed.pool_key.fee,
                        end_time: order.end_time,
                    },
                );

            true
        }
    }
}
