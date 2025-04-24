use ekubo::types::bounds::Bounds;
use ekubo::types::keys::PoolKey;
use opus_compose::types::{StorageBounds, StoragePoolKey};

#[derive(Copy, Drop, Serde, Debug, PartialEq)]
pub struct Seed {
    token_id: u64,
    pool_key: PoolKey,
    bounds: Bounds,
}

#[derive(Copy, Drop, Serde, Debug, PartialEq, starknet::Store)]
pub struct StorageSeed {
    token_id: u64,
    pool_key: StoragePoolKey,
    bounds: StorageBounds,
}