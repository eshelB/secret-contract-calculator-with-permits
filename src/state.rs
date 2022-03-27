use cosmwasm_std::{HumanAddr, ReadonlyStorage, StdError, StdResult, Storage, Uint128};
use cosmwasm_storage::{PrefixedStorage, ReadonlyPrefixedStorage};
use schemars::JsonSchema;
use secret_toolkit::serialization::{Bincode2, Serde};
use secret_toolkit::storage::{AppendStore, AppendStoreMut};
use serde::{Deserialize, Serialize};

pub static PREFIX_CALCULATIONS: &[u8] = b"calcs";
pub const KEY_CONSTANTS: &[u8] = b"constants";

#[derive(Serialize, Debug, Deserialize, Clone, PartialEq, JsonSchema)]
pub struct Constants {
    pub contract_address: HumanAddr,
}

pub fn set_constants<S: Storage>(storage: &mut S, value: &Constants) -> StdResult<()> {
    storage.set(KEY_CONSTANTS, &Bincode2::serialize(value)?);
    Ok(())
}

pub fn get_constants<S: ReadonlyStorage>(storage: &S) -> StdResult<Constants> {
    match storage.get(KEY_CONSTANTS) {
        Some(value) => Bincode2::deserialize(&value),
        None => Err(StdError::NotFound {
            kind: "Error getting constants".to_string(),
            backtrace: None,
        }),
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub struct StoredCalculation {
    pub left_operand: Uint128,
    pub right_operand: Option<Uint128>,
    pub operation: String,
    pub result: Uint128,
}

pub fn append_calculation<S: Storage>(
    store: &mut S,
    calculation: &StoredCalculation,
    for_address: &HumanAddr,
) -> StdResult<()> {
    let mut store = PrefixedStorage::multilevel(
        &[PREFIX_CALCULATIONS, for_address.as_str().as_bytes()],
        store,
    );
    let mut store = AppendStoreMut::attach_or_create(&mut store)?;
    store.push(calculation)
}

pub fn get_calculations<S: ReadonlyStorage>(
    storage: &S,
    for_address: &HumanAddr,
    page: Uint128,
    page_size: Uint128,
) -> StdResult<(Vec<StoredCalculation>, Uint128)> {
    let store = ReadonlyPrefixedStorage::multilevel(
        &[PREFIX_CALCULATIONS, for_address.as_str().as_bytes()],
        storage,
    );

    // Try to access the storage of calculations for the account.
    // If it doesn't exist yet, return an empty list of calculations.
    let store = AppendStore::<StoredCalculation, _, _>::attach(&store);
    let store = match store {
        Some(result) => result?,
        None => return Ok((vec![], Uint128::zero())),
    };

    // Take `page_size` txs starting from the latest tx, potentially skipping `page * page_size`
    // txs from the start.
    let calculations_iter = store
        .iter()
        .rev()
        .skip((page.u128() * page_size.u128()) as _)
        .take(page_size.u128() as _);

    let calculations: StdResult<Vec<StoredCalculation>> = calculations_iter.collect();

    calculations.map(|txs| (txs, Uint128::from(store.len() as u128)))
}
