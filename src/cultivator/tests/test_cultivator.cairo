use ekubo::components::clear::{IClearDispatcher, IClearDispatcherTrait};
use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use opus_compose::addresses::mainnet;
use opus_compose::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use wadray::WAD_ONE;

const INITIAL_CASH_LP_AMT: u256 = 50 * WAD_ONE;
const INITIAL_EKUBO_LP_AMT: u256 = 10 * WAD_ONE;

fn yin() -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: mainnet::shrine()
}

fn ekubo_token() -> IERC20Dispatcher {
    IERC20Dispatcher { contract_address: mainnet::ekubo()
}

fn ekubo_positions() -> IPositionsDispatcher {
    IPositionsDispatcher { contract_address: mainnet::ekubo_positions()
}

fn ekubo_positions_clear() -> IClearDispatcher {
    IClearDispatcher { contract_address: mainnet::ekubo_positions()
}

fn CASH_EKUBO_TWAMM_POOL_KEY() -> PoolKey {
    PoolKey {
        token0: mainnet::shrine(),
        token1: mainnet::ekubo(),
        fee: 1020847100762815411640772995208708096, // 0.3%
        tick_spacing: 354892,
        extension: mainnet::ekubo_twamm_extension(),
    }
}

fn TWAMM_BOUNDS() -> Bounds {
    Bounds {
        lower: i129 {
            mag: 88368108,
            sign: true,
        },
        upper: i129 {
            mag: 88368108,
            sign: false,
        }
    }
}

fn setup_cash_ekubo_lp() {
    let user = addresses::mainnet::multisig();

    yin().transfer(ekubo_positions.contract_address, INITIAL_CASH_LP_AMT);
    asset_erc20
        .transfer(mainnet::ekubo_positions(), INITIAL_EKUBO_LP_AMT);

    let (token_id, _) = ekubo_positions().mint_and_deposit(
        CASH_EKUBO_TWAMM_POOL_KEY, TWAMM_BOUNDS, 1
    );

    ekubo_positions_clear
        .clear(EkuboERC20Dispatcher { contract_address: yin.contract_address });
    ekubo_positions_clear
        .clear(EkuboERC20Dispatcher { contract_address: asset_erc20.contract_address });

}