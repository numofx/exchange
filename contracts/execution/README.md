# RFQ

This repository contains a set of smart contracts designed to enable sequential matching by our back-end on the core. The contracts facilitate the execution of transactions based on a trusted keeper (`trade-executor`), while giving user full custody of funds.


## Main components:

`Matching`: Process signed actions and additional "actionData" from the orderbook, ensuring whitelisted modules can execute actions within specified rules. Inherits `ActionVerifier` and `SubAccountManager`

Other Modules: contract that take ownership of user's subAccounts from the matching contract, and then execute accordingly base on what users signed.

For detailed information about the contracts, modules, and installation instructions, refer to your internal project documentation.

## Installation:

```shell
git submodule update --init --recursive --force
```

## Building and Testing:

```shell
forge build
```

Run tests

```shell
forge test
```
