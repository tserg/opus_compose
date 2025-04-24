use ekubo::types::bounds::Bounds;
use ekubo::types::keys::PoolKey;
use opus_compose::cultivator::types::Seed;
use starknet::ContractAddress;

#[starknet::interface]
pub trait ICultivator<TContractState> {
    //
    // Getters
    //

    fn get_assets(self: @TContractState) -> Span<ContractAddress>;
    fn get_seed(self: @TContractState, asset: ContractAddress) -> Seed;

    //
    // External functions
    //

    fn plant(ref self: TContractState, asset: ContractAddress, seed: Seed);
    fn prune(ref self: TContractState, asset: ContractAddress);

    // TODO: should there be an option to choose a specific pool to compound?
    fn cultivate(ref self: TContractState, asset: Option<ContractAddress>);

    // Withdraw LP fees for all LPs
    fn withdraw_lp_fees(ref self: TContractState);
    // Transfer a specific asset
    fn extract(ref self: TContractState, asset: ContractAddress);
}

