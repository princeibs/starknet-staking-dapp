use starknet::ContractAddress;

#[starknet::interface]
trait IStake<TContractState> {
    fn stake(ref self: TContractState, amount: u256) -> bool;
    fn withdraw(ref self: TContractState, amount: u256) -> bool;
}

#[starknet::contract]
mod BWCStakingContract {
    /////////////////////////////
    //LIBRARY IMPORTS
    /////////////////////////////        
    use core::serde::Serde;
    use core::integer::u64;
    use core::zeroable::Zeroable;
    use basic_staking_dapp::bwc_staking_contract::IStake;
    use basic_staking_dapp::erc20_token::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};

    /////////////////////
    //STAKING DETAIL
    /////////////////////
    // #[derive(Drop)]
    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct StakeDetail {
        time_staked: u64,
        amount: u256,
        status: bool,
    }

    ////////////////////
    //STORAGE
    ////////////////////
    #[storage]
    struct Storage {
        staker: LegacyMap::<ContractAddress, StakeDetail>,
        bwcerc20_token_address: ContractAddress,
        receipt_token_address: ContractAddress,
        reward_token_address: ContractAddress
    }

    //////////////////
    // CONSTANTS
    //////////////////
    const MIN_STAKE_TIME: u64 =
        240000_u64; // Minimun time (in milliseconds) staked token can be withdrawn from pool. Equivalent to 5 minutes (TODO: Change to 1 hour)

    /////////////////
    //EVENTS
    /////////////////

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TokenStaked: TokenStaked,
        TokenWithdraw: TokenWithdraw
    }

    #[derive(Drop, starknet::Event)]
    struct TokenStaked {
        staker: ContractAddress,
        amount: u256,
        time: u64
    }

    #[derive(Drop, starknet::Event)]
    struct TokenWithdraw {
        staker: ContractAddress,
        amount: u256,
        time: u64
    }

    /////////////////
    //CUSTOM ERRORS
    /////////////////
    mod Errors {
        const INSUFFICIENT_FUND: felt252 = 'STAKE: Insufficient fund';
        const INSUFFICIENT_BALANCE: felt252 = 'STAKE: Insufficient balance';
        const ADDRESS_ZERO: felt252 = 'STAKE: Address zero';
        const NOT_TOKEN_ADDRESS: felt252 = 'STAKE: Not token address';
        const ZERO_AMOUNT: felt252 = 'STAKE: Zero amount';
        const INSUFFICIENT_FUNDS: felt252 = 'STAKE: Insufficient funds';
        const LOW_CBWCRT_BALANCE: felt252 = 'STAKE: Low balance';
        const NOT_WITHDRAW_TIME: felt252 = 'STAKE: Not yet withdraw time';
        const LOW_CONTRACT_BALANCE: felt252 = 'STAKE: Low contract balance';
        const AMOUNT_NOT_ALLOWED: felt252 = 'STAKE: Amount not allowed';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        bwcerc20_token_address: ContractAddress,
        receipt_token_address: ContractAddress,
        reward_token_address: ContractAddress,
    ) {
        self.bwcerc20_token_address.write(bwcerc20_token_address);
        self.reward_token_address.write(reward_token_address);
        self.receipt_token_address.write(receipt_token_address);
    }

    #[external(v0)]
    impl IStakeImpl of super::IStake<ContractState> {
        // Function allows caller to stake their token
        // @amount: Amount of token to stake
        // @BWCERC20TokenAddr: Contract address of token to stake
        // @receipt_token: Contract address of receipt token
        fn stake(ref self: ContractState, amount: u256) -> bool {
            // CHECK -> EFFECTS -> INTERACTION

            let caller: ContractAddress = get_caller_address(); // Caller address
            let address_this: ContractAddress = get_contract_address(); // Address of this contract
            let bwc_erc20_contract = IERC20Dispatcher {
                contract_address: self.bwcerc20_token_address.read()
            };
            let receipt_contract = IERC20Dispatcher {
                contract_address: self.receipt_token_address.read()
            };

            assert(!caller.is_zero(), Errors::ADDRESS_ZERO); // Caller cannot be address 0
            assert(
                amount <= bwc_erc20_contract.balance_of(caller), Errors::INSUFFICIENT_FUNDS
            ); // Caller cannot stake more than token balance
            assert(amount >= 0, Errors::ZERO_AMOUNT); // Cannot stake zero amount
            assert(
                receipt_contract.balance_of(address_this) >= amount, Errors::LOW_CBWCRT_BALANCE
            ); // Contract must have enough receipt token to transfer out

            // STEP 1: Staker must first allow this contract to spend `amount` of Stake Tokens from staker's account

            assert(
                bwc_erc20_contract.allowance(caller, address_this) >= amount,
                Errors::AMOUNT_NOT_ALLOWED
            ); // This contract should be allowed to spend `amount` stake tokens from staker account

            // set storage variable
            let mut stake: StakeDetail = self.staker.read(caller);
            let stake_time: u64 = get_block_timestamp();
            stake.time_staked = stake_time;
            stake.amount = stake.amount + amount; // Increase total amount staked (If staker has staked before)
            stake.status = true;

            // STEP 2
            // transfer stake token from caller to this contract
            bwc_erc20_contract.transfer_from(caller, address_this, amount);

            // STEP 3
            // transfer receipt token from this contract to staker account
            receipt_contract.transfer(caller, amount);

            // STEP 4
            //
            // Staker calls the approve function of receipt token contract and approves this contract to transfer out `amount` receipt from staker account
            // Reason for this is to allow this contract withdraw the receipt token before sending back stake tokens

            self.emit(Event::TokenStaked(TokenStaked { staker: caller, amount, time: stake_time }));
            true
        }

        // Function allows caller to withdraw their staked token and get rewarded
        // @amount: Amount of token to withdraw
        // @BWCERC20TokenAddr: Contract address of token to withdraw
        fn withdraw(ref self: ContractState, amount: u256) -> bool {
            // get address of caller
            let caller = get_caller_address();
            let address_this: ContractAddress = get_contract_address(); // Address of this contract
            let bwc_erc20_contract = IERC20Dispatcher {
                contract_address: self.bwcerc20_token_address.read()
            };
            let receipt_contract = IERC20Dispatcher {
                contract_address: self.receipt_token_address.read()
            };
            let reward_contract = IERC20Dispatcher {
                contract_address: self.reward_token_address.read()
            };

            // get stake details
            let mut stake: StakeDetail = self.staker.read(caller);
            // get amount caller has staked
            let stake_amount = stake.amount;
            // get last timestamp caller staked
            let stake_time = stake.time_staked;

            assert(
                amount <= stake_amount, Errors::AMOUNT_NOT_ALLOWED
            ); // Staker cannot withdraw more than staked amount
            assert(self.time_has_passed(stake_time), Errors::NOT_WITHDRAW_TIME);
            assert(
                reward_contract.balance_of(address_this) >= amount, Errors::LOW_CONTRACT_BALANCE
            ); // This contract must have enough reward token to transfer to Staker
            assert(
                bwc_erc20_contract.balance_of(address_this) >= amount, Errors::NOT_WITHDRAW_TIME
            ); // This contract must have enough stake token to transfer back to Staker
            assert(
                receipt_contract.allowance(address_this, caller) >= amount,
                Errors::AMOUNT_NOT_ALLOWED
            ); // Staker has approved this contract to withdraw receipt token from Staker's account

            // Subtract withdraw amount from stake balance
            stake.amount = stake_amount - amount;
            self.staker.write(caller, stake);

            // Withdraw receipt token from staker account
            receipt_contract.transfer_from(caller, address_this, amount);

            // Send Reward token to staker account
            reward_contract.transfer(caller, amount);

            // Send back stake token to caller account
            bwc_erc20_contract.transfer(caller, amount);

            self
                .emit(
                    Event::TokenWithdraw(TokenWithdraw { staker: caller, amount, time: stake_time })
                );
            true
        }
    }

    #[external(v0)]
    #[generate_trait]
    impl Utility of UtilityTrait {
        // fn calculate_reward(self: ContractState, account: ContractAddress) -> u256 {
        //     let caller = get_caller_address();
        //     let stake_status: bool = self.staker.read(caller).status;
        //     let stake_amount = self.staker.read(caller).amount;
        //     let stake_time: u64 = self.staker.read(caller).time_staked;
        //     if stake_status == false {
        //         return 0;
        //     }
        //     let reward_per_month = (stake_amount * 10);
        //     let time = get_block_timestamp() - stake_time;
        //     let reward = (reward_per_month * time.into() * 1000) / MIN_STAKE_TIME.into();
        //     return reward;
        // }

        fn get_user_stake_balance(self: @ContractState) -> u256 {
            let caller: ContractAddress = get_caller_address();
            self.staker.read(caller).amount
        }

        fn time_has_passed(self: @ContractState, time: u64) -> bool {
            let now = get_block_timestamp();

            if (time > now) {
                true
            } else {
                false
            }
        }

        fn get_receipt_token_balance(
            self: @ContractState, contract_address: ContractAddress, account: ContractAddress
        ) -> u256 {
            let receipt_contract = IERC20Dispatcher { contract_address };
            receipt_contract.balance_of(account)
        }

        fn get_reward_token_balance(
            self: @ContractState, contract_address: ContractAddress, account: ContractAddress
        ) -> u256 {
            let reward_contract = IERC20Dispatcher { contract_address };
            reward_contract.balance_of(account)
        }

        fn _get_reward_token_balance(
            self: @ContractState, contract_address: ContractAddress, account: ContractAddress
        ) -> u256 {
            let reward_contract = IERC20Dispatcher { contract_address };
            reward_contract.balance_of(account)
        }
    }
}
