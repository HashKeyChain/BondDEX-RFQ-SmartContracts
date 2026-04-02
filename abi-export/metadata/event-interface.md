# BondDEX Event Interface Notes

## Version

- ABI/Event package version: `0.1.0-draft`
- Change type: additive draft baseline for contracts-first BondDEX V2

## Contract Event Coverage

### BondFactory

- `IssuanceApproved`
- `IssuanceRevoked`
- `ComplianceImplementationRegistered`
- `BondCreated`

### ComplianceModule

- `WhitelistUpdated`
- `RoleUpdated`
- `PolicyMetadataUpdated`
- `PauseDomainUpdated`

### BondIssuance

- `SettlementTokenPolicyUpdated`
- `SubscriptionCreated`
- `SubscriptionUpdated`
- `Subscribed`
- `RedemptionDeposited`
- `RedemptionClaimed`
- `ClaimDelegateSet`
- `PauseDomainUpdated`

### RFQSettlement

- `FeeConfigUpdated`
- `SettlementTokenPolicyUpdated`
- `OrderFilled`
- `OrderCancelled`
- `NonceIncremented`
- `PauseDomainUpdated`

### BondToken

- Standard ERC-20 `Transfer`

## Consumer Notes

- Frontend consumers use these events for live lifecycle refresh and transaction
  confirmation UX.
- Go backend consumers use them for order, subscription, and redemption
  projection tables.
- Subgraph consumers use them as the canonical history surface for lifecycle
  reconstruction.

## Breaking-Change Policy

- Additive events or additive non-indexed fields are MINOR changes.
- Removed or renamed events, changed indexed topics, or field-order changes are
  MAJOR changes.
- Release notes must call out any downstream regeneration steps for wagmi,
  `abigen`, or Subgraph mappings.
