#![cfg(test)]
use cosmwasm_std::testing::{MockApi, MockQuerier, MockStorage};
use cosmwasm_std::{Api, Binary, Extern, HumanAddr, StdResult};
use cosmwasm_std::{CanonicalAddr, Coin};

#[derive(Copy, Clone)]
pub struct MyMockApi {
    pub original_mock: MockApi,
}

impl MyMockApi {
    pub fn new() -> MyMockApi {
        MyMockApi {
            original_mock: MockApi::new(20),
        }
    }
}

impl Api for MyMockApi {
    fn canonical_address(&self, human: &HumanAddr) -> StdResult<CanonicalAddr> {
        self.original_mock.canonical_address(human)
    }

    fn human_address(&self, canonical: &CanonicalAddr) -> StdResult<HumanAddr> {
        // CanonicalAddr(Binary(hasher.finalize().to_vec()))
        let hashbytes = &canonical.0 .0;
        let mut stringbytes = base64::encode(hashbytes).as_bytes().to_vec();
        stringbytes.truncate(20);
        let canonical_string = CanonicalAddr(Binary(stringbytes));
        self.original_mock.human_address(&canonical_string)
    }
}

pub fn my_mock_dependencies(
    contract_balance: &[Coin],
) -> Extern<MockStorage, MyMockApi, MockQuerier> {
    let contract_addr = HumanAddr::from("cosmos2contract");
    Extern {
        storage: MockStorage::default(),
        api: MyMockApi::new(),
        querier: MockQuerier::new(&[(&contract_addr, contract_balance)]),
    }
}
