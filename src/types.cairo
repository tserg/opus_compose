use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;

// A wrapper of Ekubo's PoolKey struct to enable storage
#[derive(Copy, Drop, Serde, PartialEq, Hash, starknet::Store)]
pub struct StoragePoolKey {
    pub token0: ContractAddress,
    pub token1: ContractAddress,
    pub fee: u128,
    pub tick_spacing: u128,
    pub extension: ContractAddress,
}

pub impl StoragePoolKeyIntoPoolKey of Into<StoragePoolKey, PoolKey> {
    fn into(self: StoragePoolKey) -> PoolKey {
        PoolKey {
            token0: self.token0,
            token1: self.token1,
            fee: self.fee,
            tick_spacing: self.tick_spacing,
            extension: self.extension,
        }
    }
}

pub impl PoolKeyIntoStoragePoolKey of Into<PoolKey, StoragePoolKey> {
    fn into(self: PoolKey) -> StoragePoolKey {
        StoragePoolKey {
            token0: self.token0,
            token1: self.token1,
            fee: self.fee,
            tick_spacing: self.tick_spacing,
            extension: self.extension,
        }
    }
}

// A wrapper of Ekubo's Bounds struct to enable storage
#[derive(Copy, Drop, Serde, PartialEq, Hash, starknet::Store)]
pub struct StorageBounds {
    pub lower: i129,
    pub upper: i129,
}

pub impl StorageBoundsIntoBounds of Into<StorageBounds, Bounds> {
    fn into(self: StorageBounds) -> Bounds {
        Bounds { lower: self.lower, upper: self.upper }
    }
}

pub impl BoundsIntoStorageBounds of Into<Bounds, StorageBounds> {
    fn into(self: Bounds) -> StorageBounds {
        StorageBounds { lower: self.lower, upper: self.upper }
    }
}
