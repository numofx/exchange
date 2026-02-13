# Options Core

[![foundry-rs - foundry](https://img.shields.io/static/v1?label=foundry-rs&message=foundry&color=blue&logo=github)](https://github.com/foundry-rs/foundry "Go to GitHub repo")
[![CI](https://github.com/numofx/options-core/actions/workflows/ci.yml/badge.svg)](https://github.com/numofx/options-core/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/numofx/options-core/branch/master/graph/badge.svg?token=43B951MYIN)](https://codecov.io/gh/numofx/options-core)

<div align="center">
  <p align='center'>
    <br>
    <br>
    <img src='./docs/imgs/overall/numo.svg' alt='numo' width="300" />
  </p>
  <h5 align="center"> Options Exchange for Frontier FX </h5>
</div>


## Build

```shell
# installs git dependencies pinned in foundry.toml (into ./lib)
# (this repo does not use git submodules)
forge install

forge build
```

## Tests

```
forge test
```
Go to [test](./test/) folder for more details on how to run different tests.

## Documentation

Go to [docs](./docs) to understand the high-level design, transaction flow, and how different **Numo Options components** work together.

## Static Analysis - [Slither](https://github.com/crytic/slither)


Please go to the link above for detail to install. To run the analysis:

```shell
slither src
```

## Deployment

Got to [scripts](./scripts) to understand how to deploy **Numo Options** to different networks.
