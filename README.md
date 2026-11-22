# MIT contracts

The smart contracts MIT runs on Robinhood Chain (chain ID 4663), with their tests and everything needed to check that the code on-chain
is the code you are reading.

[App](https://cryptoledgersociety.com/platform/) · [Docs](https://cryptoledgersociety.com/docs/) · [Contracts](docs/CONTRACTS.md) · [Security](.github/SECURITY.md)

## Contracts

Solidity 0.8.26, no external libraries. **Not audited.** Reviewed and tested in-house only.

| Contract | Status | Address | What it guarantees |
|---|---|---|---|
| `TokenLocker` | **Live** | [`0x4213382292ba3bdccddfdbc8e0fbc9ffc31974c6`](https://robinhoodchain.blockscout.com/address/0x4213382292ba3bdccddfdbc8e0fbc9ffc31974c6?tab=contract) | Anyone can lock any ERC-20 token until a date, released at once or evenly over time. A lock can be made longer or larger, never shorter or smaller. No owner, no admin, no upgrade, no pause, no fee. Only the lock's owner can withdraw, and only what the schedule has released. |
| `KolStake` | **Live** | [`0xa8f2e7e31f54c6dddef7e9cbdd58689a85186a04`](https://robinhoodchain.blockscout.com/address/0xa8f2e7e31f54c6dddef7e9cbdd58689a85186a04) | A wallet stakes exactly 10,000,000 $MIT and can take the same tokens back after 30 days. No owner, no admin, no upgrade. No function can send a staker's tokens to anyone but that staker. |

Source verification on the explorer:

- `TokenLocker`: verified on Blockscout and Sourcify. Blockscout shows it as a *partial match* because the build leaves out the metadata hash; the running code itself matches byte for byte.
- `KolStake`: not verified on the explorer yet. You can check it yourself with the script below.

The $MIT token ([`0x219a665fcb5beec566052972926b723ad458b43c`](https://robinhoodchain.blockscout.com/token/0x219a665fcb5beec566052972926b723ad458b43c)) was created by the Pons launchpad. Its contract is Pons's code, not ours, so it is not in this repository.

## Check it yourself

You do not have to trust the explorer or us. This builds both contracts on your machine and compares them with the code at the addresses above:

```bash
git clone --depth 1 --branch v1.17.0 https://github.com/foundry-rs/forge-std lib/forge-std
python3 scripts/check_bytecode.py
```

```text
TokenLocker  0x4213382292ba3bdccddfdbc8e0fbc9ffc31974c6  MATCH  (6710 bytes)
KolStake     0xa8f2e7e31f54c6dddef7e9cbdd58689a85186a04  MATCH  (2429 bytes)
```

It needs [Foundry](https://book.getfoundry.sh/getting-started/installation) and Python 3, and reads the chain through the public RPC. Set `RPC_URL` to use another one.

## Run the tests

```bash
git clone --depth 1 --branch v1.17.0 https://github.com/foundry-rs/forge-std lib/forge-std   # once

cd locker && forge test          # 23 tests, including fuzz
cd ../kolstake && forge test     # 19 tests, including fuzz
```

The fork tests run against the real tokens on a copy of Robinhood Chain and are skipped unless you pass a fork:

```bash
cd locker && forge test --match-contract ForkTest --fork-url https://rpc.mainnet.chain.robinhood.com
```

## Who can do what

**TokenLocker**

| | The lock's owner | Anyone else | MIT |
|---|---|---|---|
| Lock tokens | yes | yes, for themselves or for another wallet | same as anyone |
| Withdraw before the date | no | no | no |
| Withdraw what the schedule has released | yes | no | no |
| Make a lock longer, larger or permanent | yes | no | no |
| Make a lock shorter or smaller | no | no | no |
| Hand a lock to another wallet | yes, and the other wallet must accept | no | no |
| Pause, upgrade or change the contract | no | no | no |

**KolStake**

| | The staker | Anyone else | MIT |
|---|---|---|---|
| Stake | yes | yes, for themselves | same as anyone |
| Unstake before 30 days | no | no | no |
| Unstake after 30 days | yes, the same tokens | no | no |
| Move a staker's tokens | no one else can | no | no |
| Pause, upgrade or change the contract | no | no | no |

## What to know before you use them

- **Not audited.** No third party has reviewed these contracts. Use amounts you are comfortable with.
- **Tokens sent straight to a contract address are lost.** Only tokens passed through `lock()` or `stake()` belong to someone.
- **A permanent lock cannot be undone.** That is the point of it.
- **Rebasing tokens are not supported** in `TokenLocker`. Tokens that take a fee on transfer are credited with what actually arrived; `KolStake` refuses them.
- **One sequencer runs Robinhood Chain.** If it stops, transactions stop with it.
- The contracts were deployed from a single wallet. That wallet has no power over either contract after deployment: there is no owner role to hold.

## What is not here

The MIT app, its server and its data are not open source. This repository holds only the contracts, because those are the parts that hold other people's tokens.

## Layout

```
locker/      TokenLocker: source, tests, and the exact compiler input used to verify it
kolstake/    KolStake: source, tests, and its compiler input
scripts/     check_bytecode.py: compares the deployed code with a fresh build
docs/        CONTRACTS.md: every function, event and rule
```

## Security

Report a problem privately: see [SECURITY.md](.github/SECURITY.md).

## License

[MIT](LICENSE)
