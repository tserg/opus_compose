pub mod cultivator {
    use access_control::access_control_component;
    use opus_compose::cultivator::interfaces::cultivator::ICultivator;
    use opus_compose::cultivator::types::{Seed, StorageSeed};
    use starknet::ContractAddress;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;


    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        seeds: Map<ContractAddress, StorageSeed>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct Plant {
        #[key]
        pub asset: ContractAddress,
        pub seed: Seed,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct Prune {
        #[key]
        pub asset: ContractAddress,
        pub seed: Seed,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState) {
    }

    //
    // External Cultivator functions
    //

    #[abi(embed_v0)]
    impl ICultivatorImpl of ICultivator<ContractState> {
        fn get_assets(self: @ContractState) -> Span<ContractAddress> {

        }
        fn get_seed(self: @ContractState, asset: ContractAddress) -> PoolKey {

        }

        //
        // External functions
        //

        fn plant(ref self: ContractState, asset: ContractAddress, seed: Seed) {

        }

        fn prune(ref self: ContractState, asset: ContractAddress) {

        }

        // TODO: should there be an option to choose a specific pool to compound?
        fn cultivate(ref self: ContractState, asset: Option<ContractAddress>) {

        }

        // Withdraw LP fees for all LPs
        fn withdraw_lp_fees(ref self: ContractState) {

        }
        // Transfer a specific asset
        fn extract(ref self: ContractState, asset: ContractAddress) {

        }
    }
}