# BondDEX RFQ Smart Contracts

[中文版](README.zh-CN.md)

`BondDEX RFQ Smart Contracts` is a contracts-first bond protocol repository targeting HashKey Chain. It covers compliant bond creation and issuance approval, primary market subscription, secondary market RFQ settlement, and post-maturity redemption fund injection with holder claims.

This repository aims to deliver not just the Solidity contracts themselves, but the complete delivery pipeline:

- Develop contracts, scripts, and tests in `contracts/`
- Maintain chain-level deployment manifests in `deployments/`
- Export ABIs, addresses, and event interface documentation in `abi-export/` for consumption by frontend, Go backend, and indexers

## Business Scope

The core capabilities of this repository can be understood through 3 main workflows:

- **US1 – Launch and Subscribe**: Platform approves issuance; issuer creates a bond (with full attributes including issueDate, dayCountConvention, couponFrequency, bondCategory, ISIN, etc.); compliance modules are configured; admin approves subscription window; market makers or qualified participants complete primary subscription
- **US2 – RFQ Settlement**: Market makers or investors sign EIP-712 orders (with accruedInterest field); counterparties fill orders; the contract verifies accrued interest reasonableness onchain; supports batch fills, order cancellation, nonce management, and fee collection (based on dirty amount). Trading direction is restricted to market maker ↔ investor and market maker ↔ market maker; investor ↔ investor is prohibited. Fees are always borne by the market maker side; market maker-to-market maker trades are fee-exempt
- **US3 – Redemption and Claims**: After maturity, the issuer injects redemption funds (calculated by annualized rate × date proration; the platform's off-chain process mandates full deposit). Holders claim directly or via delegate (holder must remain whitelisted). Excess redemption funds are **atomically refunded to the issuer** once all holders claim, or by the admin via `releaseExcessRedemption`. Sanctioned/blacklisted holders are handled by the admin path `forceRedeem` (burns the bond and routes the proceeds to a designated custody address). `rescueTokens` is reserved for tokens accidentally transferred into the contract, never for routing redemption surplus.

These 3 workflows are covered by integration tests in `contracts/test/integration/US1_LaunchAndSubscribe.t.sol`, `contracts/test/integration/US2_RfqSettlement.t.sol`, and `contracts/test/integration/US3_RedemptionAndClaims.t.sol`, and are chained into a full lifecycle by `contracts/test/integration/BondLifecycleE2E.t.sol`.

## Core Modules

| Module | Purpose |
| --- | --- |
| `BondFactory` | Handles issuance approval, compliance implementation registration, and creation of `BondToken` and per-bond `ComplianceModule` instances; `createBond` accepts a `BondConfig` struct with full bond attributes (issueDate, dayCountConvention, couponFrequency, bondCategory, isin) |
| `BondToken` | Bond ERC-20 asset entity recording issuer, face value, annualized coupon rate, issue date, day count convention, maturity, and settlement token; constructor uses `ConstructorParams` struct; transfer restrictions are delegated to the compliance module |
| `ComplianceModule` | Manages whitelist, role matrix, authorized transfer operators, policy metadata, and domain-level pause control; restricts bond transfer directions (investor ↔ investor prohibited) and participant identity; enforces all user-to-user transfers through authorized operators (e.g., RFQSettlement) |
| `BondIssuance` | Handles primary market subscription approval, subscription window management, redemption fund injection (interest calculated by annualized rate × date proration), direct and delegated claims (with holder whitelist verification), automatic refund of redemption surplus to the issuer (`releaseExcessRedemption` + auto-release on full claim), forced redemption of sanctioned holders (`forceRedeem`), errant-token rescue (`rescueTokens`), and settlement token policy queries (`getSettlementTokenPolicy`) |
| `RFQSettlement` | Handles secondary market RFQ order EIP-712 signature verification, onchain accrued interest verification using high-precision `BondToken.accruedInterestFor` with configurable tolerance (`setAiToleranceSeconds`), `order.quoteToken` is forced to equal `bondToken.settlementToken()`, order filling, batch fills, cancellation, nonce floor, fee policy (based on dirty amount), `quoteFee` queries, and post-upgrade EIP-712 cache refresh (`refreshDomainSeparator`) |
| `BondMath` | Basis point calculation and precision scaling utility library for fee computation and amount conversion |

## Fee Model

RFQ secondary market trading fees are always borne by the market maker side; investors are unaffected. Fees are **calculated based on the dirty amount (quoteAmount + accruedInterest)**:

| Scenario | Fund flow (example at 30 bps, with accrued interest of 500 USDC) |
| --- | --- |
| Market maker sells bond / investor buys | Investor pays 10,500 USDC → market maker receives 10,468.5 → platform receives 31.5 |
| Market maker buys bond / investor sells | Market maker pays 10,531.5 USDC → investor receives 10,500 → platform receives 31.5 |
| Market maker-to-market maker trade | Market maker B pays 10,500 USDC → market maker A receives 10,500 → platform receives 0 |

`quoteFee(bondToken, partyA, partyB, dirtyAmount)` provides onchain fee estimation; market makers can call it before constructing orders off-chain (passing dirty amount). Each order includes a `maxFeeBps` field that locks the maker's maximum acceptable fee rate at signing time, preventing unexpected overcharges from post-signature fee changes.

## Protocol Features

- Targets HashKey Chain with built-in deployment configurations for testnet `133` and mainnet `177`
- Critical control plane uses `AccessControl` + role governance with support for post-deployment handoff to Safe
- `BondIssuance`, `RFQSettlement`, and per-bond `ComplianceModule` use UUPS proxy deployment pattern
- `BondToken` externalizes compliance restrictions to `ComplianceModule` for per-bond whitelist, role, and authorized operator configuration; constructor uses `ConstructorParams` struct with full bond attributes
- `ComplianceModule`'s authorized operator mechanism enforces all user-to-user bond transfers through platform contracts (RFQSettlement), preventing direct transfers that bypass fees and accrued interest verification
- Secondary settlement uses EIP-712 typed data; order struct includes `accruedInterest` field with strict order hash, signature, and nonce verification
- `BondToken` supports full bond attributes: `issueDate`, `dayCountConvention` (ACT_365 / ACT_360), `couponFrequency` (BULLET / ANNUAL), `bondCategory` (CORPORATE / GOVERNMENT / CONVERTIBLE / ABS), `isin` (bytes12)
- Redemption interest uses annualized rate + date proration (ACT_365 / ACT_360 day count conventions); `couponRateBps` semantics are annualized rate
- RFQ accrued interest onchain verification with configurable tolerance via `setAiToleranceSeconds`, preventing manipulation while tolerating reasonable time delays
- Fee routing automatically determined by participant roles; market maker-to-market maker trades are fee-exempt; fees computed on dirty amount (including accrued interest)
- `BondFactory.createBond` emits split events: `BondCreated` (with issueDate) + `BondMetadata` (day count convention, coupon frequency, bond category, ISIN)
- ABI and event interfaces follow an additive-first release convention for easy synchronization with frontend, `abigen`, and Subgraph upgrades

## Repository Structure

```text
.
├── README.md
├── QUICKSTART.md
├── Makefile
├── config/
│   ├── anvil.json      ← Local Anvil (Anvil preset accounts + MockERC20, revokeDeployer enabled by default)
│   ├── testnet.json    ← Testnet (fill in role addresses, tokens, fees, etc.)
│   └── mainnet.json    ← Mainnet (fill in role addresses, tokens, fees, etc.)
├── abi-export/
│   ├── abi/                 # Exported ABI JSON
│   ├── addresses/           # Chain-level address manifests
│   └── metadata/            # Version, event interfaces, release metadata
├── contracts/
│   ├── src/                 # Core contracts
│   │   ├── BondFactory.sol
│   │   ├── BondToken.sol
│   │   ├── BondIssuance.sol
│   │   ├── RFQSettlement.sol
│   │   ├── compliance/ComplianceModule.sol
│   │   ├── abstracts/       # DomainPausable, RoleManaged
│   │   ├── interfaces/      # IBondFactory, IBondToken, IBondIssuance, IComplianceModule, IRFQSettlement
│   │   ├── libraries/       # BondErrors, BondMath, SettlementOrderEIP712
│   │   └── types/BondTypes.sol
│   ├── script/              # FullDeploy deployment, AnvilDemo E2E demo, Operations modular ops, ABI export
│   ├── test/                # unit / fuzz / invariant / integration / fork
│   ├── foundry.toml
│   └── remappings.txt
└── deployments/             # Per-chain deployment records and handoff status
```

## Development and Delivery Workflow

Recommended order for understanding and using this repository:

1. Compile, run unit tests and integration tests in `contracts/`
2. Edit `config/{env}.json` to configure role addresses, settlement token policies, fees, and handoff strategies for each contract
3. Use `make deploy-anvil` to verify the one-stop deployment on a local chain
4. Use `make deploy-testnet` or `make deploy-mainnet` for one-stop deployment → configuration → role grants → permission handoff
5. Use `make export-abi` to export ABIs and release metadata to `abi-export/`
6. Use `make demo-anvil` to run a full lifecycle demo on local Anvil with real-time progression (9 participants, day-by-day accrued interest advancement, covering subscription / RFQ with AI and fees / redemption / compliance rejection scenarios)
7. Use `ENV=testnet make ops-*` or `ENV=mainnet make ops-*` to execute modular operations on testnet/mainnet

The one-stop deployment script `FullDeploy.s.sol` completes all operations in a single broadcast (deploy, register compliance template, configure settlement token policies and fees, per-role authorization, selective deployer revocation). Anvil / Testnet / Mainnet follow the exact same deployment pipeline; results are written to `deployments/{chainId}.json`.

`Operations.s.sol` provides modular operation scripts, with each function corresponding to a single onchain operation (approval, compliance, subscription, RFQ, redemption, queries, etc.), switchable between Anvil / testnet / mainnet via the `ENV` environment variable.

## Test Layers

Tests are organized following standard Foundry layering:

- `unit/`: Focused on individual module behavior, e.g., issuance approval, order filling, compliance module management, fee model
- `fuzz/`: Focused on math and boundary inputs, e.g., subscription and settlement pricing logic
- `invariant/`: Focused on protocol invariants, e.g., primary market accounting and RFQ settlement state consistency
- `integration/`: User story validation for `US1`, `US2`, `US3`, and full lifecycle
- `fork/`: Validates domain separation, deployment, and Safe handoff behavior on HashKey testnet fork

## ABI and Event Interfaces

`abi-export/metadata/README.md` and `abi-export/metadata/event-interface.md` define the ABI release and event change policies:

- `contracts/out/` is the canonical source of truth for build artifacts
- `abi-export/abi/*.abi.json` is the exported ABI for downstream consumption
- `abi-export/metadata/event-interface.md` describes the event surface for `BondFactory`, `ComplianceModule`, `BondIssuance`, `RFQSettlement`, `BondToken`
- Adding new events or non-indexed fields is considered a `MINOR` change
- Removing events, modifying indexed topics, or reordering fields is considered a `MAJOR` change

## Documentation Sources

This README is compiled from the following sources of truth:

- `abi-export/metadata/README.md`
- `abi-export/metadata/event-interface.md`
- `contracts/script/*.s.sol`
- `contracts/test/integration/US1_LaunchAndSubscribe.t.sol`
- `contracts/test/integration/US2_RfqSettlement.t.sol`
- `contracts/test/integration/US3_RedemptionAndClaims.t.sol`
- `contracts/test/integration/BondLifecycleE2E.t.sol`

## Quick Start

For local setup, core commands, minimum verification path, and testnet/mainnet environment variable instructions, see `QUICKSTART.md` in the project root.
