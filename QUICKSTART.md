# Quick Start

[中文版](QUICKSTART.zh-CN.md)

BondDEX RFQ is a compliant bond protocol for HashKey Chain, covering issuance approval, primary subscription, secondary RFQ settlement, and maturity redemption. See `README.md` for details.

This quickstart guide aims to get you through 4 things in the shortest path:

- Confirm the repository compiles successfully
- Run through `US1 / US2 / US3` — the 3 core business workflows
- Verify the one-stop deployment script on local Anvil
- Export ABI artifacts for frontend, backend, or indexer consumption

## Prerequisites

- Foundry installed: `forge`, `cast`, `anvil`
- `jq` installed (Makefile uses it to extract RPC URLs from `config/*.json`)
- `make` installed

If `contracts/lib/` already exists in the repository, you can skip dependency installation. If dependencies are missing, run in the `contracts/` directory:

```bash
cd contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts OpenZeppelin/openzeppelin-contracts-upgradeable
```

## Configuration Files

Role addresses and policy configurations are centralized in the `config/` directory; the deployer private key is passed via the `DEPLOYER_PRIVATE_KEY` environment variable — **never stored in config files**. Each role and settlement token policy can be independently configured.

```
config/
├── anvil.json      ← Local Anvil (uses Anvil preset accounts, zero-address token auto-deploys MockERC20)
├── testnet.json    ← Testnet (must fill in all real values before deployment)
└── mainnet.json    ← Mainnet (must fill in all real values before deployment)
```

### Full Configuration Format

```json
{
  "rpcUrl": "https://testnet.hsk.xyz",

  "platformAdmin": "0xInitialAdminForNewComplianceModule(typicallySafeMultisig)",

  "roles": {
    "bondFactory": {
      "admin":            "0xFactoryDEFAULT_ADMIN_ROLE_holder",
      "issuanceApprover": "0xISSUANCE_APPROVER_ROLE_holder",
      "complianceAdmin":  "0xCOMPLIANCE_ADMIN_ROLE_holder",
      "pauser":           "0xPAUSER_ROLE_holder"
    },
    "bondIssuance": {
      "admin":            "0xPrimaryMarketDEFAULT_ADMIN_ROLE_holder",
      "issuanceApprover": "0xISSUANCE_APPROVER_ROLE_holder",
      "settlementAdmin":  "0xSETTLEMENT_ADMIN_ROLE_holder",
      "pauser":           "0xPAUSER_ROLE_holder",
      "upgrader":         "0xUUPS_UPGRADER_ROLE_holder"
    },
    "rfqSettlement": {
      "admin":            "0xSecondaryMarketDEFAULT_ADMIN_ROLE_holder",
      "settlementAdmin":  "0xSETTLEMENT_ADMIN_ROLE_holder",
      "pauser":           "0xPAUSER_ROLE_holder",
      "upgrader":         "0xUUPS_UPGRADER_ROLE_holder"
    }
  },

  "settlementTokens": [
    {
      "token": "0xSettlementTokenAddress(e.g.USDC)",
      "bondIssuancePolicy": {
        "issuanceEnabled": true,
        "redemptionEnabled": true
      },
      "rfqSettlementEnabled": true
    }
  ],

  "feeConfig": {
    "feeRecipient": "0xFeeRecipientAddress",
    "currentFeeBps": 30,
    "maxFeeBps": 1000
  },

  "revokeDeployer": true
}
```

### Configuration Reference

| Field | Description |
| --- | --- |
| `DEPLOYER_PRIVATE_KEY` (env var) | Deployer private key, passed via environment variable; all roles can be auto-revoked after testnet/mainnet deployment |
| `platformAdmin` | Initial admin for new ComplianceModule proxies; receives DEFAULT_ADMIN / COMPLIANCE_ADMIN / PAUSER / UPGRADER on that module |
| **roles.bondFactory** | |
| `.admin` | BondFactory DEFAULT_ADMIN_ROLE — can manage all role grants/revocations |
| `.issuanceApprover` | ISSUANCE_APPROVER_ROLE — approve/revoke issuance applications |
| `.complianceAdmin` | COMPLIANCE_ADMIN_ROLE — register/disable compliance implementation templates |
| `.pauser` | PAUSER_ROLE — pause/unpause Factory domains |
| **roles.bondIssuance** | |
| `.admin` | BondIssuance DEFAULT_ADMIN_ROLE — manage all roles |
| `.issuanceApprover` | ISSUANCE_APPROVER_ROLE — approve/revoke subscription applications |
| `.settlementAdmin` | SETTLEMENT_ADMIN_ROLE — configure settlement token policies |
| `.pauser` | PAUSER_ROLE — pause/unpause subscription, redemption, etc. |
| `.upgrader` | UPGRADER_ROLE — execute UUPS proxy upgrades |
| **roles.rfqSettlement** | |
| `.admin` | RFQSettlement DEFAULT_ADMIN_ROLE — manage all roles |
| `.settlementAdmin` | SETTLEMENT_ADMIN_ROLE — configure settlement token policies + fees |
| `.pauser` | PAUSER_ROLE — pause/unpause settlement domains |
| `.upgrader` | UPGRADER_ROLE — execute UUPS proxy upgrades |
| **settlementTokens[]** | Settlement token array, supporting multiple currencies |
| `.token` | ERC20 token address (`0x0` auto-deploys MockERC20, local testing only) |
| `.bondIssuancePolicy` | BondIssuance two-dimensional policy: `issuanceEnabled` (primary subscription) / `redemptionEnabled` (claim payouts). RFQ secondary trading is controlled by the separate `rfqSettlementEnabled` flag |
| `.rfqSettlementEnabled` | Whether this token is enabled for RFQSettlement secondary trading |
| **feeConfig** | |
| `.feeRecipient` | RFQ secondary market fee recipient address |
| `.currentFeeBps` | Current fee rate (basis points, 30 = 0.30%) |
| `.maxFeeBps` | Fee rate ceiling (basis points, 1000 = 10%) |
| `revokeDeployer` | Whether to revoke all deployer roles after configuration (selective revocation: only roles already handed off to others are revoked; roles still held solely by deployer are retained with a warning) |

> **Security Note**: The deployer private key has been removed from config files and is only passed via the `DEPLOYER_PRIVATE_KEY` environment variable to prevent accidental Git commits.
>
> **Unified Deployment Pipeline**: Anvil / Testnet / Mainnet follow the exact same deployment pipeline. Local Anvil defaults to Anvil account #1 for role addresses and enables `revokeDeployer` to realistically test the permission handoff flow.

## 1. Compile Contracts

```bash
make build
```

## 2. Run Minimum Verification Path

```bash
make test-us1   # Issuance approval + primary subscription
make test-us2   # RFQ secondary trading, batch fills, fees, accrued interest verification
make test-us3   # Redemption fund injection + holder claims
make test-e2e   # Full lifecycle E2E
make test        # Full regression suite
```

## 3. Verify One-Stop Deployment on Local Anvil

```bash
# Terminal 1: Start local chain
anvil

# Terminal 2: One-stop deployment (Anvil default private key)
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 make deploy-anvil
```

**A single command automatically completes** (Anvil / Testnet / Mainnet run the same pipeline):

1. Deploy MockERC20 (triggered only when token is zero address, local testing only)
2. Validate configuration (all roles, tokens, fee addresses must be non-zero)
3. Deploy ComplianceModule implementation → BondIssuance proxy → RFQSettlement proxy → BondFactory
4. Register ComplianceModule implementation template
5. Configure all settlement token policies
6. Configure RFQ fees
7. Set platformAdmin
8. Per-role authorization (each contract's each role independently granted to configured addresses)
9. Selective deployer revocation (`revokeDeployer=true`: roles already handed off to others are auto-renounced)

Upon completion, the full manifest is written to `deployments/{chainId}.json`.

### 3.1 End-to-End Demo

Run a full lifecycle demo with one command (auto-starts Anvil → deploys → demos → shuts down Anvil):

```bash
make demo-anvil
```

This command automatically starts Anvil with a timestamp of 2025-12-31, deploys contracts, then executes in multiple phases along a real timeline: subscription window (2026-01-01) → 12 minutes after issue date → +2 days → monthly progression to +3 months → maturity date (2027-01-09). The Makefile advances Anvil time via `cast rpc`. Each RFQ trade includes accrued interest automatically calculated from onchain time. Anvil shuts down automatically after the demo.

The demo covers 9 participants (admin / issuer / makerA / makerB / makerC / investorA / investorB / investorC / delegate), including: over-subscription error, unauthorized subscription error, **direct transfer rejection (authorized operator mechanism)**, RFQ buy/sell with accrued interest and fees, market maker-to-market maker fee exemption with accrued interest, order cancellation, expired orders, investor-to-investor restriction, delegated claims, **automatic refund of redemption surplus to the issuer once all holders claim**, and more.

For simulation mode (no Anvil required, uses `vm.warp`, single-pass full lifecycle; requires existing `deployments/31337.json`):

```bash
make demo-anvil-sim
```

### 3.2 Modular Operations

Post-deployment daily operations (approval, compliance, subscription, RFQ, redemption, queries, etc.) are provided via `Operations.s.sol` as modular commands. Select network via `ENV` variable:

```bash
# Anvil (default)
make ops-query-fee-config

# Testnet
ENV=testnet make ops-query-fee-config
ENV=testnet DEPLOYER_PRIVATE_KEY=0x... make ops-set-whitelist ARGS="0xCMAddress 0xAccount true"

# Mainnet
ENV=mainnet DEPLOYER_PRIVATE_KEY=0x... make ops-set-whitelist ARGS="0xCMAddress 0xAccount true"
```

Query operations (`ops-query-*`) do not require a private key. See `docs/部署后操作手册.md` for details.

Accrued interest tolerance configuration (`setAiToleranceSeconds` / `aiToleranceSeconds`) can be invoked directly through `Operations.s.sol`. See `docs/部署后操作手册.md` for details.

## 4. Export ABI

```bash
make export-abi
```

Output: `abi-export/abi/*.abi.json` + `abi-export/metadata/metadata.json`

## 5. Deploy to Testnet

### 5.1 Edit `config/testnet.json`

Fill in all real addresses (each role can point to a different Safe multisig):

```json
{
  "rpcUrl": "https://testnet.hsk.xyz",
  "platformAdmin": "0xSafeAddressA",
  "roles": {
    "bondFactory": {
      "admin":            "0xSafeAddressA",
      "issuanceApprover": "0xSafeAddressA",
      "complianceAdmin":  "0xSafeAddressA",
      "pauser":           "0xSafeAddressB(OpsTeam)"
    },
    "bondIssuance": {
      "admin":            "0xSafeAddressA",
      "issuanceApprover": "0xSafeAddressA",
      "settlementAdmin":  "0xSafeAddressA",
      "pauser":           "0xSafeAddressB",
      "upgrader":         "0xSafeAddressC(TechTeam)"
    },
    "rfqSettlement": {
      "admin":            "0xSafeAddressA",
      "settlementAdmin":  "0xSafeAddressA",
      "pauser":           "0xSafeAddressB",
      "upgrader":         "0xSafeAddressC"
    }
  },
  "settlementTokens": [
    {
      "token": "0xTestnetUSDC",
      "bondIssuancePolicy": {
        "issuanceEnabled": true,
        "redemptionEnabled": true
      },
      "rfqSettlementEnabled": true
    }
  ],
  "feeConfig": {
    "feeRecipient": "0xTreasurySafe",
    "currentFeeBps": 30,
    "maxFeeBps": 1000
  },
  "revokeDeployer": true
}
```

### 5.2 One-Stop Deployment

```bash
DEPLOYER_PRIVATE_KEY=0xYourPrivateKey make deploy-testnet
```

On success, `deployments/133.json` is automatically updated (containing complete contract addresses, configuration parameters, role matrix, and handoff status).

## 6. Mainnet Deployment

Edit `config/mainnet.json` → `DEPLOYER_PRIVATE_KEY=0x... make deploy-mainnet` → outputs `deployments/177.json`.

## Deployment Output File

`deployments/{chainId}.json` contains:

| Field | Description |
| --- | --- |
| `deployer` / `platformAdmin` | Key account addresses |
| `contracts` | All contract addresses (proxy + implementation) |
| `configuration.settlementTokens[]` | Full policy for each token |
| `configuration.feeConfig` | Fee rate and recipient address |
| `configuration.aiToleranceSeconds` | Accrued interest verification tolerance (seconds), read from onchain |
| `roles.bondFactory` | BondFactory per-role holders |
| `roles.bondIssuance` | BondIssuance per-role holders |
| `roles.rfqSettlement` | RFQSettlement per-role holders |
| `handoff` | Deployer role revocation status |

## Command Reference

| Command | Description |
| --- | --- |
| `make build` | Compile contracts |
| `make test` | Full test suite |
| `make test-us1` / `test-us2` / `test-us3` | Individual workflow tests |
| `make test-e2e` | E2E lifecycle test |
| `DEPLOYER_PRIVATE_KEY=0x... make deploy-anvil` | Local Anvil one-stop deployment |
| `DEPLOYER_PRIVATE_KEY=0x... make deploy-testnet` | Testnet one-stop deployment + permission handoff |
| `DEPLOYER_PRIVATE_KEY=0x... make deploy-mainnet` | Mainnet one-stop deployment + permission handoff |
| `make ops-release-excess-redemption ARGS="<bondToken>"` | Manually release excess redemption funds (post-maturity); funds are **atomically refunded to the issuer** in the same tx (v0.3.0+) |
| `make demo-anvil` | Anvil E2E demo (multi-phase: real-timeline subscription → RFQ → redemption) |
| `make demo-anvil-sim` | Simulation demo (no broadcast, uses vm.warp, single-pass) |
| `make export-abi` | Export ABI |
| `ENV=testnet make ops-query-*` | Testnet queries (no private key required) |
| `ENV=testnet DEPLOYER_PRIVATE_KEY=0x... make ops-*` | Testnet write operations |

## BondConfig Field Reference

Full example of the `BondConfig` struct used by `createBond`:

```solidity
BondConfig({
    issuer:                   0xIssuerAddress,
    name:                     "HashKey Bond 2026-Q1",
    symbol:                   "HKB-Q1",
    decimals:                 0,
    faceValue:                1_000e6,           // 1,000 USDC
    couponRateBps:            500,               // 5% annualized (basis points)
    maturityTimestamp:        1767225600,         // 2026-01-01 maturity
    issueDate:                1704067200,         // 2024-01-01 issue date
    dayCountConvention:       DayCount.ACT_365,
    couponFrequency:          CouponFrequency.BULLET,
    bondCategory:             BondCategory.CORPORATE,
    isin:                     bytes12(0),         // or fill in 12-byte ISIN
    settlementToken:          0xUSDCAddress,
    settlementTokenDecimals:  6,
    complianceImplementation: 0xRegisteredComplianceTemplate,
    policyId:                 keccak256("policy-v1"),
    policyVersion:            1
})
```

**DayCountConvention Enum Values:**

| Enum | Value | Description |
| --- | --- | --- |
| `ACT_365` | 0 | Actual days / 365 |
| `ACT_360` | 1 | Actual days / 360 |

**CouponFrequency Enum Values:**

| Enum | Value | Description |
| --- | --- | --- |
| `BULLET` | 0 | Bullet payment at maturity (most common) |
| `ANNUAL` | 1 | Annual coupon |

> SEMI_ANNUAL / QUARTERLY frequencies are not supported by the platform.

**BondCategory Enum Values:**

| Enum | Value | Description |
| --- | --- | --- |
| `CORPORATE` | 0 | Corporate bond |
| `GOVERNMENT` | 1 | Government bond |
| `CONVERTIBLE` | 2 | Convertible bond |
| `ABS` | 3 | Asset-backed security |

## v0.3.0 Added / Changed API Reference

The external audit hardening batch (N1–N18) lands as the following interface changes. Integrators upgrading to v0.3.0 **must regenerate** wagmi typegen / abigen / Subgraph mappings.

### BondFactory (added)

```solidity
/// Computes the canonical hash of a BondConfig. Approver computes this off-chain before
/// approveIssuance; createBond verifies it. Any field mismatch reverts BondConfigHashMismatch.
function hashBondConfig(BondConfig calldata config) external pure returns (bytes32);
```

> **Constructor behaviour change (least-privilege initialization)**: now grants ONLY `DEFAULT_ADMIN_ROLE`; the other 4 governance roles are granted explicitly by deployer/admin via `grantRole`. `setPlatformAdmin` is purified to ONLY update the `platformAdmin` storage field (which seeds the initial admin of newly deployed ComplianceModule proxies); **it no longer touches any AccessControl roles**.

### BondToken (added)

```solidity
/// High-precision total accrued interest in settlement-token smallest units (deferred-division mulDiv).
function accruedInterestFor(uint256 bondAmount, uint256 timestamp) external view returns (uint256);

/// Principal of bondAmount in settlement-token smallest units.
function principalOf(uint256 bondAmount) external view returns (uint256);

/// Settlement token decimals captured + verified at construction.
function settlementTokenDecimals() external view returns (uint8);
```

> **Removed**: legacy `accruedInterestPerUnit(timestamp)` is gone — for the historical "per-unit" value, call `accruedInterestFor(10 ** decimals(), timestamp)` (mathematically equivalent, strictly higher precision).
>
> **Constructor params change**: `BondToken.ConstructorParams` adds a `uint8 settlementTokenDecimals` field; the constructor cross-checks it against `IERC20Metadata(settlementToken).decimals()` and reverts on mismatch.

### BondIssuance (added + changed)

```solidity
/// Force-redeem a sanctioned/permanently-blacklisted holder, routing the proceeds to a
/// regulator custody / issuer wallet. Bypasses the holder whitelist check.
function forceRedeem(address bondToken, address holder, address recipient) external;  // DEFAULT_ADMIN_ROLE

/// Signature change: v0.2.0 was (address, bool, bool, bool); v0.3.0 drops the middle settlementEnabled bool.
function setSettlementTokenPolicy(address token, bool enabledForIssuance, bool enabledForRedemption) external;
function getSettlementTokenPolicy(address token) external view returns (bool, bool);
```

> **Excess-redemption behaviour (N6)**: `releaseExcessRedemption` and the auto-release branch on full-claim now **atomically transfer the surplus back to the issuer** instead of "release-then-rescue". Listen to the new event `ExcessRedemptionRefunded(bondToken, settlementToken, issuer, excessAmount)` for accounting reconciliation. `rescueTokens` is now reserved for tokens accidentally transferred into the contract.
>
> **Redemption-channel close gating (N11)**: when `_totalRedemptionLiability[token] > 0`, you can no longer flip `enabledForRedemption` to false for that token — preventing admin policy changes from trapping issuer-deposited redemption funds.

### RFQSettlement (added + behaviour)

```solidity
/// Recompute the cached EIP-712 domain separator. Call after any UUPS upgrade that changed
/// SettlementOrderEIP712.NAME or VERSION; otherwise off-chain signatures will fail.
function refreshDomainSeparator() external;  // DEFAULT_ADMIN_ROLE
```

> **Onchain enforcement (N1)**: `order.quoteToken` must equal `bondToken.settlementToken()`. Frontends should auto-derive this field from the bond and not let users edit it.
>
> **Accrued-interest verification (N7 + N8)**: onchain validation now uses `BondToken.accruedInterestFor` (high precision). When `expectedAI == 0` (e.g. trades before issueDate), the strict invariant `order.accruedInterest == 0` is enforced **with no tolerance window**.

### New events

| Event | Source | Trigger |
| :-- | :-- | :-- |
| `ExcessRedemptionRefunded(bondToken, settlementToken, issuer, excessAmount)` | BondIssuance | Surplus actually transferred back to issuer (same tx as `ExcessRedemptionReleased`) |
| `ForceRedemption(bondToken, holder, recipient, bondAmount, payout, operator)` | BondIssuance | Admin invoked `forceRedeem` |
| `DomainSeparatorRefreshed(chainId, domainSeparator, operator)` | RFQSettlement | Admin invoked `refreshDomainSeparator` |

Full ABI + version notes: `abi-export/metadata/event-interface.md`.
