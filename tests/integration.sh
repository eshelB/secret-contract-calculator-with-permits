#!/bin/bash

set -eu
set -o pipefail # If anything in a pipeline fails, the pipe's exit status is a failure
#set -x # Print all commands for debugging

# This means we don't need to configure the cli since it uses the preconfigured cli in the docker.
# We define this as a function rather than as an alias because it has more flexible expansion behavior.
# In particular, it's not possible to dynamically expand aliases, but `tx_of` dynamically executes whatever
# we specify in its arguments.
function secretcli() {
    set -e
    if [[ -z "${IS_GITHUB_ACTIONS+x}" ]]; then
      docker exec secretdev /usr/bin/secretd "$@"
    else
      /usr/local/bin/secretcli "$@"
    fi
}

# Just like `echo`, but prints to stderr
function log() {
    echo "$@" >&2
}

# suppress all output to stdout for the command described in the arguments
function quiet() {
    "$@" >/dev/null
}

# suppress all output to stdout and stderr for the command described in the arguments
function silent() {
    "$@" >/dev/null 2>&1
}

function assert_eq() {
    set -e
    local left="$1"
    local right="$2"
    local message

    if [[ "$left" != "$right" ]]; then
        if [ -z ${3+x} ]; then
            local lineno="${BASH_LINENO[0]}"
            log "assertion failed on line $lineno - both sides differ."
            log "left:"
            log "${left@Q}"
            log
            log "right:"
            log "${right@Q}"
        else
            message="$3"
            log "$message"
        fi
        return 1
    fi

    return 0
}

# Keep polling the blockchain until the tx completes.
# The first argument is the tx hash.
# The second argument is a message that will be logged after every failed attempt.
# The tx information will be returned.
function wait_for_tx() {
    local tx_hash="$1"
    local message="$2"

    local result

    log "waiting on tx: $tx_hash"
    # secretcli will only print to stdout when it succeeds
    until result="$(secretcli query tx "$tx_hash" 2>/dev/null)"; do
        log "$message"
        sleep 1
    done

    log "init complete"

    # log out-of-gas events
    if quiet jq -e '.raw_log | startswith("execute contract failed: Out of gas: ") or startswith("out of gas:")' <<<"$result"; then
        log "$(jq -r '.raw_log' <<<"$result")"
    fi

    log "finish wait"

    echo "$result"
}

# This is a wrapper around `wait_for_tx` that also decrypts the response,
# and returns a nonzero status code if the tx failed
function wait_for_compute_tx() {
    local tx_hash="$1"
    local message="$2"
    local return_value=0
    local result
    local decrypted

    result="$(wait_for_tx "$tx_hash" "$message")"
    # log "$result"
    if quiet jq -e '.logs == null' <<<"$result"; then
        return_value=1
    fi
    decrypted="$(secretcli query compute tx "$tx_hash")" || return
    log "$decrypted"
    echo "$decrypted"

    return "$return_value"
}

# If the tx failed, return a nonzero status code.
# The decrypted error or message will be echoed
function check_tx() {
    local tx_hash="$1"
    local result
    local return_value=0

    result="$(secretcli query tx "$tx_hash")"
    if quiet jq -e '.logs == null' <<<"$result"; then
        return_value=1
    fi
    decrypted="$(secretcli query compute tx "$tx_hash")" || return
    log "$decrypted"
    echo "$decrypted"

    return "$return_value"
}

# Extract the tx_hash from the output of the command
function tx_of() {
    "$@" | jq -r '.txhash'
}

# Extract the output_data_as_string from the output of the command
function data_of() {
    "$@" | jq -r '.output_data_as_string'
}

function get_generic_err() {
    jq -r '.output_error.generic_err.msg' <<<"$1"
}

# Send a compute transaction and return the tx hash.
# All arguments to this function are passed directly to `secretcli tx compute execute`.
function compute_execute() {
    tx_of secretcli tx compute execute "$@"
}

# Send a query to the contract.
# All arguments to this function are passed directly to `secretcli query compute query`.
function compute_query() {
    secretcli query compute query "$@"
}

function upload_code() {
    set -e
    local directory="$1"
    local tx_hash
    local code_id

    log uploading code from dir "$directory"

    tx_hash="$(tx_of secretcli tx compute store "$directory/contract.wasm.gz" --from a --keyring-backend test -y --gas 10000000)"
    log "uploaded contract with tx hash $tx_hash"
    code_id="$(
        wait_for_tx "$tx_hash" 'waiting for contract upload' |
            jq -r '.logs[0].events[0].attributes[] | select(.key == "code_id") | .value'
    )"

    log "uploaded contract #$code_id"

    echo "$code_id"
}

# Generate a label for a contract with a given code id
# This just adds "contract_" before the code id.
function label_by_id() {
    local id="$1"
    echo "contract_$id"
}

function instantiate() {
    set -e
    local code_id="$1"
    local init_msg="$2"

    log 'sending init message:'
    log "${init_msg}"

    local tx_hash
    tx_hash="$(tx_of secretcli tx compute instantiate "$code_id" "$init_msg" --label "$(label_by_id "$code_id")" --from a --keyring-backend test --gas "10000000" -y)"
    wait_for_tx "$tx_hash" 'waiting for init to complete'
    log "instantiation completed"
}

# This function uploads and instantiates a contract, and returns the new contract's address
function create_contract() {
    set -e
    local dir="$1"
    local init_msg="$2"

    local code_id
    code_id="$(upload_code "$dir")"

    local init_result
    init_result="$(instantiate "$code_id" "$init_msg")"

    if quiet jq -e '.logs == null' <<<"$init_result"; then
        local tx_hash
        tx_hash=$(jq -r '.txhash' <<<"$init_result")
        log "$(secretcli query compute tx "$tx_hash")"
        return 1
    fi

    result=$(jq -r '.logs[0].events[0].attributes[] | select(.key == "contract_address") | .value' <<<"$init_result")

    log "contract address is $result"
    echo "$result"
}

function log_test_header() {
    log " ########### Starting ${FUNCNAME[1]} ###############################################################################################################################################"
}

function sign_permit() {
    set -e
    local permit="$1"
    local key="$2"

    local sig
    if [[ -z "${IS_GITHUB_ACTIONS+x}" ]]; then
      sig=$(docker exec secretdev bash -c "/usr/bin/secretd tx sign-doc <(echo '"$permit"') --from '$key'")
    else
      sig=$(secretcli tx sign-doc <(echo "$permit") --from "$key")
    fi

    echo "$sig"
}

function test_query_with_permit_after() {
    set -e
    local contract_addr="$1"

    log_test_header

    # common variables
    local result
    local tx_hash

    local permit
    local permit_query
    local expected_output
    local sig
    permit='{"account_number":"0","sequence":"0","chain_id":"blabla","msgs":[{"type":"query_permit","value":{"permit_name":"test","allowed_tokens":["'"$contract_addr"'"],"permissions":["calculation_history"]}}],"fee":{"amount":[{"denom":"uscrt","amount":"0"}],"gas":"1"},"memo":""}'

    key=a
    expected_output='{"calculation_history":{"calcs":[{"left_operand":"23","right_operand":null,"operation":"Sqrt","result":"4"},{"left_operand":"23","right_operand":"3","operation":"Div","result":"7"},{"left_operand":"23","right_operand":"3","operation":"Mul","result":"69"}],"total":"5"}}'

    sig=$(sign_permit "$permit" "$key")
    permit_query='{"with_permit":{"query":{"calculation_history":{"page_size":"3"}},"permit":{"params":{"permit_name":"test","chain_id":"blabla","allowed_tokens":["'"$contract_addr"'"],"permissions":["calculation_history"]},"signature":'"$sig"'}}}'
    result="$(compute_query "$contract_addr" "$permit_query" 2>&1 || true )"
    result_comparable=$(echo $result | sed 's/ Usage:.*//')
    assert_eq "$result_comparable" "$expected_output"
    log "query result populated history: ASSERTION_SUCCESS"

    key=b
    expected_output='{"calculation_history":{"calcs":[],"total":"0"}}'

    sig=$(sign_permit "$permit" "$key")
    permit_query='{"with_permit":{"query":{"calculation_history":{"page_size":"3"}},"permit":{"params":{"permit_name":"test","chain_id":"blabla","allowed_tokens":["'"$contract_addr"'"],"permissions":["calculation_history"]},"signature":'"$sig"'}}}'
    result="$(compute_query "$contract_addr" "$permit_query" 2>&1 || true )"
    result_comparable=$(echo $result | sed 's/ Usage:.*//')
    assert_eq "$result_comparable" "$expected_output"
    log "query result for empty history: ASSERTION_SUCCESS"
}

function test_permit() {
    set -e
    local contract_addr="$1"

    log_test_header

    # common variables
    local result
    local result_comparable
    local tx_hash
    local sig
    local expected_error
    local permit
    local permit_query

    # fail due to contract not in permit
    quiet secretcli keys delete banana -yf || true
    quiet secretcli keys add banana
    local wrong_contract
    wrong_contract=$(secretcli keys show -a banana)

    permit='{"account_number":"0","sequence":"0","chain_id":"blabla","msgs":[{"type":"query_permit","value":{"permit_name":"test","allowed_tokens":["'"$wrong_contract"'"],"permissions":["calculation_history"]}}],"fee":{"amount":[{"denom":"uscrt","amount":"0"}],"gas":"1"},"memo":""}'
    expected_error="Error: query result: encrypted: Permit doesn't apply to token \"$contract_addr\", allowed tokens: [\"$wrong_contract\"]"

    key=a

    log attempting to sign permit:
    log "$permit"
    log "from key $key"
    sig=$(sign_permit "$permit" "$key")
    log "signature: $sig"

    permit_query='{"with_permit":{"query":{"calculation_history":{"page_size":"3"}},"permit":{"params":{"permit_name":"test","chain_id":"blabla","allowed_tokens":["'"$wrong_contract"'"],"permissions":["calculation_history"]},"signature":'"$sig"'}}}'
    result="$(compute_query "$contract_addr" "$permit_query" 2>&1 || true )"
    result_comparable=$(echo $result | sed 's/Usage:.*//' | xargs -0)

    assert_eq "$result_comparable" "$expected_error"
    log "no contract in permit: ASSERTION_SUCCESS"

    # fail query due to incorrect permissions in permit
    permit='{"account_number":"0","sequence":"0","chain_id":"blabla","msgs":[{"type":"query_permit","value":{"permit_name":"test","allowed_tokens":["'"$contract_addr"'"],"permissions":["no_permissions"]}}],"fee":{"amount":[{"denom":"uscrt","amount":"0"}],"gas":"1"},"memo":""}'
    expected_error='Error: query result: parsing calculator::msg::QueryMsg: unknown variant `no_permissions`, expected `calculation_history`'

    sig=$(sign_permit "$permit" "$key")
    permit_query='{"with_permit":{"query":{"calculation_history":{"page_size":"3"}},"permit":{"params":{"permit_name":"test","chain_id":"blabla","allowed_tokens":["'"$contract_addr"'"],"permissions":["no_permissions"]},"signature":'"$sig"'}}}'
    result="$(compute_query "$contract_addr" "$permit_query" 2>&1 || true )"
    result_comparable=$(echo $result | sed 's/ Usage:.*//' | xargs -0)

    assert_eq "$result_comparable" "$expected_error"
    log "no permissions in permit: ASSERTION_SUCCESS"

    # fail query due to mismatching signature
    permit='{"account_number":"0","sequence":"0","chain_id":"blabla","msgs":[{"type":"query_permit","value":{"permit_name":"test","allowed_tokens":["'"$contract_addr"'"],"permissions":["calculation_history"]}}],"fee":{"amount":[{"denom":"uscrt","amount":"0"}],"gas":"1"},"memo":""}'
    expected_error='Error: query result: encrypted: Failed to verify signatures for the given permit: IncorrectSignature'

    sig=$(sign_permit "$permit" "$key")
    permit_query='{"with_permit":{"query":{"calculation_history":{"page_size":"3"}},"permit":{"params":{"permit_name":"test-2","chain_id":"blabla","allowed_tokens":["'"$contract_addr"'"],"permissions":["calculation_history"]},"signature":'"$sig"'}}}'
    result="$(compute_query "$contract_addr" "$permit_query" 2>&1 || true )"
    result_comparable=$(echo $result | sed 's/ Usage:.*//' | xargs -0)

    assert_eq "$result_comparable" "$expected_error"
    log "incorrect signature: ASSERTION_SUCCESS"

    # permit query success
    permit='{"account_number":"0","sequence":"0","chain_id":"blabla","msgs":[{"type":"query_permit","value":{"permit_name":"test","allowed_tokens":["'"$contract_addr"'"],"permissions":["calculation_history"]}}],"fee":{"amount":[{"denom":"uscrt","amount":"0"}],"gas":"1"},"memo":""}'
    expected_output='{"calculation_history":{"calcs":[],"total":"0"}}'

    sig=$(sign_permit "$permit" "$key")
    permit_query='{"with_permit":{"query":{"calculation_history":{"page_size":"3"}},"permit":{"params":{"permit_name":"test","chain_id":"blabla","allowed_tokens":["'"$contract_addr"'"],"permissions":["calculation_history"]},"signature":'"$sig"'}}}'
    result="$(compute_query "$contract_addr" "$permit_query" 2>&1 || true )"
    result_comparable=$(echo $result | sed 's/ Usage:.*//' | xargs -0)

    assert_eq "$result_comparable" "$expected_output"
    log "permit correct: ASSERTION_SUCCESS"
}

function test_add() {
    set -e
    local contract_addr="$1"

    log_test_header

    local key="a"
    local tx_hash

    log "adding..."
    local add_message='{"add": ["23", "3"]}'
    tx_hash="$(compute_execute "$contract_addr" "$add_message" "--from" "$key" --gas "150000" "-y" --keyring-backend test)"
    echo "$tx_hash"

    local add_response
    add_response="$(data_of wait_for_compute_tx "$tx_hash" "waiting for add to \"$key\" to process")"
    log "$add_response"

    local expected_response
    expected_response='"26"'
    assert_eq "$add_response" "$expected_response"
}

function test_sub() {
    set -e
    local contract_addr="$1"

    log_test_header

    local key="a"
    local tx_hash

    log "subtracting..."
    local sub_message='{"sub": ["23", "3"]}'
    tx_hash="$(compute_execute "$contract_addr" "$sub_message" "--from" "$key" --keyring-backend test --gas "150000" "-y")"
    echo "$tx_hash"

    local sub_response
    sub_response="$(data_of wait_for_compute_tx "$tx_hash" "waiting for sub from \"$key\" to process")"
    log "$sub_response"

    local expected_response
    expected_response='"20"'
    assert_eq "$sub_response" "$expected_response"
}

function test_mul() {
    set -e
    local contract_addr="$1"

    log_test_header

    local key="a"
    local tx_hash

    log "multiplying..."
    local mul_message='{"mul": ["23", "3"]}'
    tx_hash="$(compute_execute "$contract_addr" "$mul_message" "--from" "$key" --keyring-backend test --gas "150000" "-y")"
    echo "$tx_hash"

    local mul_response
    mul_response="$(data_of wait_for_compute_tx "$tx_hash" "waiting for mul from \"$key\" to process")"
    log "$mul_response"

    local expected_response
    expected_response='"69"'
    assert_eq "$mul_response" "$expected_response"
}

function test_div() {
    set -e
    local contract_addr="$1"

    log_test_header

    local key="a"
    local tx_hash

    log "dividing..."
    local div_message='{"div": ["23", "3"]}'
    tx_hash="$(compute_execute "$contract_addr" "$div_message" "--from" "$key" --keyring-backend test --gas "150000" "-y")"
    echo "$tx_hash"

    local div_response
    div_response="$(data_of wait_for_compute_tx "$tx_hash" "waiting for div from \"$key\" to process")"
    log "$div_response"

    local expected_response
    expected_response='"7"'
    assert_eq "$div_response" "$expected_response"
}

function test_div_by_zero() {
    set -e
    local contract_addr="$1"

    log_test_header

    local key="a"
    local tx_hash

    log "dividing..."
    local div_message='{"div": ["23", "0"]}'

    tx_hash="$(compute_execute "$contract_addr" "$div_message" "--from" "$key" --keyring-backend test --gas "150000" "-y")"
    echo "$tx_hash"

    local div_response
    # Notice the `!` before the command - it is EXPECTED to fail.
    ! div_response="$(wait_for_compute_tx "$tx_hash" "waiting division by zero result")"
    local div_error
    div_error="$(get_generic_err "$div_response")"

    log "$div_error"

    local expected_error="Divisor can't be zero"
    assert_eq "$div_error" "$expected_error"
}

function test_sqrt() {
    set -e
    local contract_addr="$1"

    log_test_header

    local key="a"
    local tx_hash

    log "calculating square root..."
    local sqrt_message='{"sqrt": "23"}'
    tx_hash="$(compute_execute "$contract_addr" "$sqrt_message" "--from" "$key" --keyring-backend test --gas "150000" "-y")"
    echo "$tx_hash"

    local sqrt_response
    sqrt_response="$(data_of wait_for_compute_tx "$tx_hash" "waiting for sqrt from \"$key\" to process")"
    log "$sqrt_response"

    local expected_response
    expected_response='"4"'
    assert_eq "$sqrt_response" "$expected_response"
}

function main() {
    set -e
    log '              <####> Starting integration tests <####>'
    log "secretcli version in the docker image is: $(secretcli version)"

    local init_msg
    init_msg='{}'
    local dir

    set -e
    if [[ -z "${IS_GITHUB_ACTIONS+x}" ]]; then
        dir="."
    else
        dir="code"
    fi

    contract_addr="$(create_contract '.' "$init_msg")"

    test_permit "$contract_addr"
    test_add "$contract_addr"
    test_sub "$contract_addr"
    test_mul "$contract_addr"
    test_div "$contract_addr"
    test_div_by_zero "$contract_addr"
    test_sqrt "$contract_addr"
    test_query_with_permit_after "$contract_addr"

    log 'Tests completed successfully'

    return 0
}

main "$@"
