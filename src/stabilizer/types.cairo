#[derive(Copy, Drop, Serde, Debug, PartialEq, starknet::Store)]
pub struct Stake {
    // A 128-bit value from Ekubo representing amount of liquidity
    // provided by a position. This value should remain unchanged
    // while a position NFT is staked.
    pub liquidity: u128,
    // Snapshot of the accumulator value for yield at the time the
    // user last took an action
    pub yin_per_liquidity_snapshot: u256,
}

#[derive(Copy, Drop, Serde, Debug, PartialEq, starknet::Store)]
pub struct YieldState {
    // Yin balance of this contract at the time that
    // this contract was last called
    pub yin_balance_snapshot: u256,
    // Accumulator value for amount of yield (yin) per unit of liquidity
    // This value is obtained by scaling yin (wad precision) up by 2 ** 128
    // before dividing by total liquidity. Since total liquidity could be a
    // small `u128` value, 256 bits are used to prevent overflows.
    pub yin_per_liquidity: u256,
}

//
// Frontend Data Provider
//

#[derive(Copy, Drop, Serde)]
pub struct PoolInfo {
    pub liquidity: u128,
    pub sqrt_ratio: u256,
    pub token0_amount: u256,
    pub token1_amount: u256,
}
