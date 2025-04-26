pub mod cultivator_roles {
    pub const CULTIVATE: u128 = 1;
    pub const EXTRACT: u128 = 2;
    pub const PLANT: u128 = 4;
    pub const PRUNE: u128 = 8;

    pub const ADMIN: u128 = CULTIVATE + EXTRACT + PLANT + PRUNE;
}
