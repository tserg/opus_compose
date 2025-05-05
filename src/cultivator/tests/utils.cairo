pub mod cultivator_utils {
    use opus_compose::addresses::mainnet;
    use opus_compose::cultivator::interfaces::cultivator::ICultivatorDispatcher;
    use snforge_std::{
        CheatSpan, ContractClass, ContractClassTrait, DeclareResultTrait, cheat_caller_address,
        declare, start_cheat_caller_address, stop_cheat_caller_address,
    };


    #[derive(Copy, Drop)]
    pub struct CultivatorTestConfig {
        pub cultivator: ICultivatorDispatcher,
    }

    //
    // Test setup helpers
    //

    pub fn setup(cultivator_class: Option<ContractClass>) -> CultivatorTestConfig {
        let cultivator_class = match cultivator_class {
            Option::Some(class) => class,
            Option::None => *(declare("cultivator").unwrap().contract_class()),
        };

        let mut calldata: Array<felt252> = array![
            mainnet::MULTISIG.into(),
            mainnet::SHRINE.into(),
            mainnet::EKUBO_POSITIONS.into(),
            mainnet::EKUBO_POSITIONS_NFT.into(),
        ];
        let (cultivator_addr, _) = cultivator_class.deploy(@calldata).unwrap();

        CultivatorTestConfig {
            cultivator: ICultivatorDispatcher { contract_address: cultivator_addr },
        }
    }
}
