use core::num::traits::Zero;
use ekubo::types::bounds::Bounds;
use ekubo::types::keys::PoolKey;
use opus_compose::types::{StorageBounds, StoragePoolKey};


#[derive(Copy, Drop, Serde, PartialEq)]
pub struct Seed {
    pub token_id: u64,
    pub pool_key: PoolKey,
    pub bounds: Bounds,
}

pub impl DefaultSeed of Default<Seed> {
    fn default() -> Seed {
        Seed {
            token_id: Zero::zero(),
            pool_key: PoolKey {
                token0: Zero::zero(),
                token1: Zero::zero(),
                fee: Zero::zero(),
                tick_spacing: Zero::zero(),
                extension: Zero::zero(),
            },
            bounds: Bounds { lower: Zero::zero(), upper: Zero::zero() },
        }
    }
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct StorageSeed {
    pub token_id: u64,
    pub pool_key: StoragePoolKey,
    pub bounds: StorageBounds,
}

pub impl StorageSeedIntoSeed of Into<StorageSeed, Seed> {
    fn into(self: StorageSeed) -> Seed {
        Seed { token_id: self.token_id, pool_key: self.pool_key.into(), bounds: self.bounds.into() }
    }
}

pub impl SeedIntoStorageSeed of Into<Seed, StorageSeed> {
    fn into(self: Seed) -> StorageSeed {
        StorageSeed {
            token_id: self.token_id, pool_key: self.pool_key.into(), bounds: self.bounds.into(),
        }
    }
}

#[derive(Copy, Drop, Default, Serde, PartialEq, starknet::Store)]
pub struct Order {
    pub order_id: u64,
    pub sale_rate: u128,
    pub end_time: u64,
}
