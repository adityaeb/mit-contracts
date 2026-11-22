# Contracts reference

Robinhood Chain, chain ID 4663. Solidity 0.8.26, optimizer on (200 runs), no metadata hash in the bytecode. Not audited.

| Contract | Address | EVM version | Deployed in |
|---|---|---|---|
| `TokenLocker` | `0x4213382292ba3bdccddfdbc8e0fbc9ffc31974c6` | cancun | [`0xf4729fd7…3b22`](https://robinhoodchain.blockscout.com/tx/0xf4729fd7c3128faaac967088d2a04e66e08cc54397d97b382865db9035333b22) |
| `KolStake` | `0xa8f2e7e31f54c6dddef7e9cbdd58689a85186a04` | shanghai | see the address page on the [explorer](https://robinhoodchain.blockscout.com/address/0xa8f2e7e31f54c6dddef7e9cbdd58689a85186a04) |

The exact compiler inputs are in `locker/verify/` and `kolstake/verify/`.

## TokenLocker

Public time locks for any ERC-20 token: a project's own tokens, a developer's buy, or a V2-style liquidity (LP) token.

### Rules that cannot change

- No owner, no admin, no upgrade path, no pause, no migrate function, no fee.
- The only address that can receive a lock's tokens is that lock's owner, and only what the schedule has released.
- Every lock keeps its own numbers (`total`, `claimed`). Nothing is pooled between locks.
- Handing a lock over takes two steps, `proposeOwner` then `acceptOwner`, so it cannot be sent to a wrong address by mistake.

### Functions

| Function | Who | What it does |
|---|---|---|
| `lock(token, amount, owner, unlockAt, vestEnd, title)` | anyone | Pulls `amount` of `token` from the caller and locks it for `owner`. `vestEnd == unlockAt` releases everything at once; a later `vestEnd` releases evenly between the two dates. `title` is a short public note. Returns the lock's id. |
| `increase(id, amount)` | lock owner | Adds tokens to a lock. |
| `extend(id, unlockAt, vestEnd)` | lock owner | Moves the dates later. Never earlier. |
| `makePermanent(id)` | lock owner | The tokens can never be withdrawn. Cannot be undone. |
| `withdraw(id)` | lock owner | Sends the owner what the schedule has released and not yet claimed. |
| `proposeOwner(id, newOwner)` / `acceptOwner(id)` | lock owner / proposed owner | Two-step hand-over. |
| `getLock(id)`, `claimable(id)`, `released(id)` | anyone (read) | A lock's data, what can be withdrawn now, what the schedule has released so far. |
| `lockCount()`, `tokenLockCount(token)`, `ownerLockCount(wallet)` | anyone (read) | Counts. |
| `locksOfToken(token, start, count)`, `locksOfOwner(wallet, start, count)` | anyone (read) | Lock ids, in pages. |

### Events

`Locked`, `Increased`, `Extended`, `Withdrawn`, `OwnerProposed`, `OwnerChanged`, `MadePermanent`. The public board at
[cryptoledgersociety.com/platform](https://cryptoledgersociety.com/platform/#lock) is built only from these events and the read functions.

### Known limits

- Tokens whose balances change by themselves (rebasing) are not supported.
- Tokens that take a fee on transfer are credited with what actually arrived.
- Tokens sent to the contract without `lock()` belong to no lock and cannot be recovered by anyone.
- Uniswap V3 and V4 liquidity positions (NFTs) cannot be locked here.

## KolStake

A time-locked stake of $MIT that qualifies a wallet for the MIT KOL (partner) program.

Fixed at deployment and readable on-chain: `token` (the $MIT contract), `amount` (10,000,000 $MIT) and `lockSeconds` (2,592,000 = 30 days).

### Rules that cannot change

- No owner, no admin, no upgrade path.
- No function can move a staker's tokens to anyone but that staker.
- The MIT server only reads this contract (the `Staked` event and `stakes(wallet)`) to switch a KOL code on or off. It cannot write to it.

### Functions

| Function | Who | What it does |
|---|---|---|
| `stake(ref)` | anyone | Pulls exactly `amount` tokens from the caller and locks them for `lockSeconds`. One stake per wallet. `ref` is a free 32-byte reference that is only emitted. Refuses a token that delivers less than `amount` (a fee on transfer). |
| `unstake()` | the staker | After the cooldown, returns the same tokens to the staker. |
| `stakes(wallet)`, `cooldownLeft(wallet)`, `totalStaked()`, `stakers()` | anyone (read) | A wallet's stake, seconds left before it can unstake, totals. |

### Events

`Staked(staker, ref, amount, unlockAt)`, `Unstaked(staker, amount)`.

## Reproducing the build

`python3 scripts/check_bytecode.py` builds both contracts and compares them with the chain. To submit a contract for explorer verification
yourself, use its file in `verify/` with compiler `v0.8.26+commit.8a97fa7a` as "Standard JSON input".
