use opus_compose::cultivator::types::{Order, Seed};
use starknet::ContractAddress;

#[starknet::interface]
pub trait ICultivator<TContractState> {
    //
    // Getters
    //

    // Returns a list of assets with active positions
    fn get_assets(self: @TContractState) -> Span<ContractAddress>;
    fn get_order(self: @TContractState, asset: ContractAddress) -> Option<Order>;
    fn get_seed(self: @TContractState, asset: ContractAddress) -> Option<Seed>;

    //
    // External functions
    //

    // Add an asset
    fn plant(ref self: TContractState, asset: ContractAddress, seed: Seed);

    // Remove an asset
    fn prune(ref self: TContractState, asset: ContractAddress);

    // Compound a LP position
    // Returns the liquidity provided
    fn cultivate(ref self: TContractState, asset: Option<ContractAddress>) -> u128;

    // Withdraw all LP fees to the contract
    fn collect(ref self: TContractState);

    // Transfer the contract's balance for a specific asset to the caller
    fn extract(ref self: TContractState, asset: ContractAddress);
}

