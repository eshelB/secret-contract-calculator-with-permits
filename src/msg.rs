use cosmwasm_std::Uint128;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::state::StoredCalculation;
use secret_toolkit::permit::Permit;

#[derive(Deserialize, Clone, Debug, PartialEq, JsonSchema)]
// nothing to initialize in this contract
pub struct InitMsg {}

#[derive(Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum HandleMsg {
    Add(BinaryOp),
    Sub(BinaryOp),
    Mul(BinaryOp),
    Div(BinaryOp),
    Sqrt(UnaryOp),
}

#[derive(Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub struct UnaryOp(pub Uint128);

#[derive(Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub struct BinaryOp(pub Uint128, pub Uint128);

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum CalculatorPermission {
    CalculationHistory,
}

#[derive(Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum QueryMsg {
    WithPermit {
        permit: Permit<CalculatorPermission>,
        query: QueryWithPermit,
    },
}

#[derive(Deserialize, Clone, Debug, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum QueryWithPermit {
    CalculationHistory {
        page: Option<Uint128>,
        page_size: Uint128,
    },
}

#[derive(Serialize, Clone, Debug, PartialEq, JsonSchema)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "snake_case")]
pub enum QueryAnswer {
    CalculationHistory {
        calcs: Vec<StoredCalculation>,
        total: Option<Uint128>,
    },
}

#[derive(Serialize, Clone, Debug, PartialEq, JsonSchema)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "snake_case")]
pub struct HandleAnswer(pub Uint128);
