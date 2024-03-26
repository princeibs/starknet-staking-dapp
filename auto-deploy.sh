#!/bin/bash
# source ./.env

export STARKNET_KEYSTORE=./account/sn_ks.json
export STARKNET_ACCOUNT=./account/sn_acc.json
export KEYSTORE_ACCESS=12345678

SIERRA_FILE=./target/dev/basic_staking_dapp_BWCStakingContract.contract_class.json
TOKEN_1=0x3ae4482d3273f1e8117335b2985154c4b014e28028c2427ba67452756b61b85
TOKEN_2=0x132088afa8dba7ad8f0bcc9368f762b6cf270e201645115e64bbeda112bd628
TOKEN_3=0x6cbc1299cd8f2c07956d99189d3d4be9326cc11bacc69ec76eac675e2ed930b

# build the solution
build_contract() {
    echo "Running build command..."
    output=$(scarb build 2>&1)

    if [[ $output == *"Error"* ]]; then
        echo "Error: $output"
        exit 1
    fi
}

# declare the contract
declare_contract() {
    build_contract

    echo "Running declare command..."
    output=$(starkli declare $SIERRA_FILE --keystore-password $KEYSTORE_ACCESS --watch 2>&1)

    if [[ $output == *"Error"* ]]; then
        echo "Error: $output"
        exit 1
    fi

    address=$(echo "$output" | grep -oE '0x[0-9a-fA-F]+')
    echo $address
}

deploy_contract() {
    class_hash=$(declare_contract | tail -n 1)

    sleep 5

    echo "Running deploy command..."
    output=$(starkli deploy $class_hash "$TOKEN_1" "$TOKEN_2" "$TOKEN_3" --keystore-password $KEYSTORE_ACCESS --watch 2>&1)

    echo $output
    if [[ $output == *"Error"* ]]; then
        echo "Error: $output"
        exit 1
    fi

    address=$(echo "$output" | grep -oE '0x[0-9a-fA-F]+' | tail -n 1) 
    echo $address
}

declare_contract