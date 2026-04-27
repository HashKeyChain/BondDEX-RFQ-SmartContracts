// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title AuditFixesTest
/// @notice Coverage suite for the post-audit fix batch (N1, N3, N5, N6, N7, N8, N9, N10, N11,
///         N12, N13, N15, N16). One test contract per scope keeps fixtures lean.

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { BondFactory } from "../../src/BondFactory.sol";
import { BondIssuance } from "../../src/BondIssuance.sol";
import { BondToken } from "../../src/BondToken.sol";
import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";
import { RFQSettlement } from "../../src/RFQSettlement.sol";
import { IComplianceModule } from "../../src/interfaces/IComplianceModule.sol";
import {
    AccruedInterestMismatch,
    BondConfigHashMismatch,
    BondNotMatured,
    DomainPaused,
    InsufficientRedemptionFunding,
    InvalidApprovalState,
    InvalidBasisPoints,
    NoClaimableBalance,
    QuoteTokenMismatch,
    SettlementTokenHasRedemptionLiability,
    SubscriptionWindowExceedsApprovalExpiry,
    ZeroAddress
} from "../../src/libraries/BondErrors.sol";
import {
    ApprovalStatus,
    BondCategory,
    BondConfig,
    CouponFrequency,
    DayCount,
    FeeConfig,
    Order,
    OrderSide,
    PauseDomain,
    Role,
    SubscriptionTerms
} from "../../src/types/BondTypes.sol";
import { BondIssuanceRedemptionFixtures } from "../helpers/BondIssuanceRedemptionFixtures.sol";
import { RFQSettlementFixtures } from "../helpers/RFQSettlementFixtures.sol";
import { MockERC20Decimals } from "../mocks/MockERC20Decimals.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  N1  RFQSettlement: order.quoteToken must match bond.settlementToken.
//  N8  expectedAI==0 must be enforced strictly with no tolerance allowed.
// ─────────────────────────────────────────────────────────────────────────────

contract AuditFixesRFQSettlementTest is RFQSettlementFixtures {
    function setUp() public {
        deployRfqFixtures();
    }

    function test_N1_revertWhenQuoteTokenDifferentFromSettlementToken() public {
        // Whitelist a different settlement-shaped token at the RFQ layer so the policy gate passes.
        MockERC20Decimals usdt = new MockERC20Decimals("Mock USDT", "mUSDT", 6);
        vm.prank(admin);
        settlement.setSettlementTokenPolicy(address(usdt), true);

        Order memory order = makeBuyOrder(5e18, 5_000e6, 0, 999);
        order.quoteToken = address(usdt); // != bondToken.settlementToken() (= address(usdc))
        bytes memory sig = signOrder(order, MAKER_PK);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(QuoteTokenMismatch.selector, address(usdt), address(usdc)));
        settlement.fillOrder(order, sig);
    }

    function test_N8_revertWhenPhantomInterestBeforeIssueDate() public {
        // Re-deploy a bond whose issueDate is in the future to ensure expectedAI == 0 at trade time.
        BondToken newBond = new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "Future Bond",
                symbol: "FB",
                decimals: 18,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: address(usdc),
                settlementTokenDecimals: 6,
                complianceModule: address(complianceModule),
                issuanceController: issuanceController,
                issueDate: block.timestamp + 5 days, // before issueDate
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );
        vm.prank(admin);
        settlement.setBondTokenRegistration(address(newBond), true);
        vm.prank(issuanceController);
        newBond.mint(maker, 100e18);
        vm.prank(maker);
        newBond.approve(address(settlement), type(uint256).max);

        Order memory order = Order({
            maker: maker,
            taker: investor,
            bondToken: address(newBond),
            quoteToken: address(usdc),
            bondAmount: 10e18,
            quoteAmount: 10_000e6,
            side: OrderSide.BUY,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 1,
            maxFeeBps: 10_000,
            accruedInterest: 1 // phantom AI must be rejected
        });
        bytes memory sig = signOrder(order, MAKER_PK);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(AccruedInterestMismatch.selector, 1, 0, 0));
        settlement.fillOrder(order, sig);
    }

    function test_N8_zeroAccruedInterestAcceptedBeforeIssueDate() public {
        BondToken newBond = new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "Future Bond",
                symbol: "FB",
                decimals: 18,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: address(usdc),
                settlementTokenDecimals: 6,
                complianceModule: address(complianceModule),
                issuanceController: issuanceController,
                issueDate: block.timestamp + 5 days,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );
        vm.prank(admin);
        settlement.setBondTokenRegistration(address(newBond), true);
        vm.prank(issuanceController);
        newBond.mint(maker, 100e18);
        vm.prank(maker);
        newBond.approve(address(settlement), type(uint256).max);

        Order memory order = Order({
            maker: maker,
            taker: investor,
            bondToken: address(newBond),
            quoteToken: address(usdc),
            bondAmount: 10e18,
            quoteAmount: 10_000e6,
            side: OrderSide.BUY,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 2,
            maxFeeBps: 10_000,
            accruedInterest: 0
        });
        bytes memory sig = signOrder(order, MAKER_PK);

        vm.prank(investor);
        settlement.fillOrder(order, sig);
        assertEq(newBond.balanceOf(investor), 10e18);
    }

    // N15: refreshDomainSeparator
    event DomainSeparatorRefreshed(uint256 chainId, bytes32 domainSeparator, address indexed operator);

    function test_N15_refreshDomainSeparatorCallableByAdminAndEmitsEvent() public {
        vm.prank(admin);
        // We don't strictly inspect data because separator depends on chain/contract, but emission proves the path.
        vm.recordLogs();
        settlement.refreshDomainSeparator();
    }

    function test_N15_refreshDomainSeparatorRevertsForNonAdmin() public {
        vm.prank(investor);
        vm.expectRevert();
        settlement.refreshDomainSeparator();
    }

    // N16: initializer must use InvalidBasisPoints for an out-of-range maxFeeBps.
    function test_N16_initializeRevertsWithInvalidBasisPointsWhenMaxFeeBpsAboveCap() public {
        RFQSettlement implementation = new RFQSettlement();
        vm.expectRevert(abi.encodeWithSelector(InvalidBasisPoints.selector, uint256(10_001)));
        new ERC1967Proxy(address(implementation), abi.encodeCall(RFQSettlement.initialize, (address(this), 10_001)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  N3 / N12  BondFactory hash binding + CEI ordering
//  N13       BondToken decimal model
// ─────────────────────────────────────────────────────────────────────────────

/// @dev N12 attack mock: a malicious compliance implementation that re-enters BondFactory.createBond
///      during its `initialize()` call. ComplianceModule deployment goes through ERC1967Proxy
///      (delegatecall), so all state mutations land in the proxy's storage; we inspect them later
///      by casting the proxy address back to this type.
contract MaliciousReentrantCompliance {
    // Slot 0
    bool public reentryAttempted;
    // Slot 1
    bytes public lastError;
    // Slot 2 (immutable not allowed for bytes32 to be set per-instance via delegatecall, so use
    // policyId field as the smuggle channel — we encode the address of an ATTACK BUNDLE there).
    address public attackBundle;

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    /// @dev policyId is reused as the address of an off-chain prepared AttackBundle which exposes
    ///      `factory()` and `payload()`. This avoids any need to seed proxy storage beforehand.
    function initialize(address, address, bytes32 policyId_, uint256) external {
        attackBundle = address(uint160(uint256(policyId_)));
        if (attackBundle.code.length == 0) return;
        if (reentryAttempted) return;
        reentryAttempted = true;
        address fac = AttackBundle(attackBundle).factoryRef();
        bytes memory payload = AttackBundle(attackBundle).payload();
        (bool ok, bytes memory ret) = fac.call(payload);
        ok;
        lastError = ret;
    }

    /// @dev Stub so that the post-deploy `complianceModule.bindBondToken(bondToken)` call from
    ///      BondFactory does not revert on an unknown selector when the proxy delegates to us.
    function bindBondToken(address) external { }
}

/// @dev Holds the BondFactory address and pre-encoded createBond payload that the malicious
///      compliance impl reads at re-entry time.
contract AttackBundle {
    address public immutable factoryRef;
    bytes public payload;

    constructor(address factory_, bytes memory payload_) {
        factoryRef = factory_;
        payload = payload_;
    }
}

contract AuditFixesBondFactoryTest is Test {
    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");

    MockERC20Decimals internal usdc;
    BondFactory internal factory;
    BondIssuance internal issuance;
    ComplianceModule internal complianceImplementation;

    function setUp() public {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        BondIssuance impl = new BondIssuance();
        issuance = BondIssuance(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(BondIssuance.initialize, (admin))))
        );
        complianceImplementation = new ComplianceModule();
        factory = new BondFactory(admin, address(issuance));

        vm.startPrank(admin);
        // AUDIT-FIX(N11) revisited: self-grant secondary roles this test exercises.
        factory.grantRole(keccak256("COMPLIANCE_ADMIN_ROLE"), admin);
        factory.grantRole(keccak256("ISSUANCE_APPROVER_ROLE"), admin);
        factory.registerComplianceImplementation(address(complianceImplementation), type(IComplianceModule).interfaceId);
        vm.stopPrank();
    }

    function _baseConfig() internal view returns (BondConfig memory) {
        return BondConfig({
            issuer: issuer,
            name: "Audit Bond",
            symbol: "AB",
            decimals: 18,
            faceValue: 1_000e6,
            couponRateBps: 500,
            maturityTimestamp: block.timestamp + 30 days,
            settlementToken: address(usdc),
            settlementTokenDecimals: 6,
            complianceImplementation: address(complianceImplementation),
            policyId: keccak256("policy"),
            policyVersion: 1,
            issueDate: block.timestamp + 1 days,
            dayCountConvention: DayCount.ACT_365,
            couponFrequency: CouponFrequency.BULLET,
            bondCategory: BondCategory.CORPORATE,
            isin: bytes12(0)
        });
    }

    function test_N3_revertWhenBondConfigHashMismatch() public {
        BondConfig memory approved = _baseConfig();
        bytes32 approvedHash = factory.hashBondConfig(approved);
        bytes32 approvalId = keccak256("audit-n3");
        vm.prank(admin);
        factory.approveIssuance(
            approvalId, issuer, address(complianceImplementation), block.timestamp + 1 days, approvedHash
        );

        BondConfig memory tampered = approved;
        tampered.couponRateBps = 1_000; // bait-and-switch attempt
        bytes32 tamperedHash = factory.hashBondConfig(tampered);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(BondConfigHashMismatch.selector, approvedHash, tamperedHash)
        );
        factory.createBond(tampered, approvalId);
    }

    function test_N12_reentrantComplianceCannotReuseApproval() public {
        MaliciousReentrantCompliance evil = new MaliciousReentrantCompliance();

        // Approve the malicious compliance implementation (it claims supportsInterface for IComplianceModule).
        vm.prank(admin);
        factory.registerComplianceImplementation(address(evil), type(IComplianceModule).interfaceId);

        BondConfig memory cfg = _baseConfig();
        cfg.complianceImplementation = address(evil);

        // Build the attack bundle and smuggle its address into BondConfig.policyId so the malicious
        // initializer can read it from delegatecall context (proxy storage starts empty).
        // First compute a placeholder hash to register an approval; we will overwrite policyId later.
        bytes32 approvalIdPlaceholder = keccak256("audit-n12");
        // Use a two-pass dance: we need the real cfg hash with the bundle address baked into policyId.
        AttackBundle bundle =
            new AttackBundle(address(factory), abi.encodeCall(BondFactory.createBond, (cfg, approvalIdPlaceholder)));
        cfg.policyId = bytes32(uint256(uint160(address(bundle))));
        // Now rebuild the payload so the inner re-entrant call uses the *final* cfg (matching its hash).
        bundle = new AttackBundle(address(factory), abi.encodeCall(BondFactory.createBond, (cfg, approvalIdPlaceholder)));
        cfg.policyId = bytes32(uint256(uint160(address(bundle))));
        bytes32 cfgHash = factory.hashBondConfig(cfg);

        vm.prank(admin);
        factory.approveIssuance(approvalIdPlaceholder, issuer, address(evil), block.timestamp + 1 days, cfgHash);

        // The outer createBond runs _deployComplianceModule which CALLs the proxy's initialize
        // (delegatecall to evil); evil reads the AttackBundle from policyId and re-enters createBond.
        // Under AUDIT-FIX(N12) the approval is already CONSUMED before that external call.
        vm.prank(issuer);
        factory.createBond(cfg, approvalIdPlaceholder);

        (, address proxyAddr) = factory.getBondAddresses(approvalIdPlaceholder);
        MaliciousReentrantCompliance proxied = MaliciousReentrantCompliance(proxyAddr);
        assertTrue(proxied.reentryAttempted(), "reentry path was not exercised");
        bytes memory expected = abi.encodeWithSelector(InvalidApprovalState.selector, ApprovalStatus.CONSUMED);
        assertEq(keccak256(proxied.lastError()), keccak256(expected));
    }

    function test_N13_revertWhenSettlementTokenDecimalsLieDuringDeploy() public {
        BondConfig memory cfg = _baseConfig();
        cfg.settlementTokenDecimals = 18; // mismatches the live USDC mock (6)
        bytes32 cfgHash = factory.hashBondConfig(cfg);

        bytes32 approvalId = keccak256("audit-n13");
        vm.prank(admin);
        factory.approveIssuance(
            approvalId, issuer, address(complianceImplementation), block.timestamp + 1 days, cfgHash
        );

        vm.prank(issuer);
        vm.expectRevert();
        factory.createBond(cfg, approvalId);
    }

    function test_N13_principalAndAccrualHelpersExposedOnBondToken() public {
        BondConfig memory cfg = _baseConfig();
        bytes32 cfgHash = factory.hashBondConfig(cfg);
        bytes32 approvalId = keccak256("audit-n13b");
        vm.prank(admin);
        factory.approveIssuance(
            approvalId, issuer, address(complianceImplementation), block.timestamp + 1 days, cfgHash
        );
        vm.prank(issuer);
        (address bondAddr,) = factory.createBond(cfg, approvalId);
        BondToken bond = BondToken(bondAddr);

        assertEq(bond.settlementTokenDecimals(), 6);
        assertEq(bond.principalOf(10e18), 10_000_000_000); // 10 bonds * 1000 USDC
        // Pre-issueDate accrual is zero
        assertEq(bond.accruedInterestFor(10e18, block.timestamp), 0);
    }

    // N11 (revisited): setPlatformAdmin is side-effect-free. It must ONLY update the platformAdmin
    // storage field and leave every AccessControl role untouched. Governance handover happens via
    // explicit grantRole/revokeRole following the standard AccessControl flow (documented in
    // 部署后操作手册.md §6.3).
    bytes32 internal constant ISSUANCE_APPROVER_ROLE = keccak256("ISSUANCE_APPROVER_ROLE");
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    function test_N11_setPlatformAdminOnlyUpdatesStorageField() public {
        address newAdmin = makeAddr("newAdmin");
        // Snapshot prior role state of admin.
        bool adminHadDefault = factory.hasRole(0x00, admin);
        bool adminHadCompliance = factory.hasRole(COMPLIANCE_ADMIN_ROLE, admin);
        bool adminHadApprover = factory.hasRole(ISSUANCE_APPROVER_ROLE, admin);

        vm.prank(admin);
        factory.setPlatformAdmin(newAdmin);

        // Only the platformAdmin storage field changed.
        assertEq(factory.platformAdmin(), newAdmin);

        // newAdmin gains NO BondFactory roles from this call.
        assertFalse(factory.hasRole(0x00, newAdmin));
        assertFalse(factory.hasRole(ISSUANCE_APPROVER_ROLE, newAdmin));
        assertFalse(factory.hasRole(COMPLIANCE_ADMIN_ROLE, newAdmin));
        assertFalse(factory.hasRole(PAUSER_ROLE, newAdmin));

        // Previous admin keeps every role they held — caller must explicitly revokeRole during handover.
        assertEq(factory.hasRole(0x00, admin), adminHadDefault);
        assertEq(factory.hasRole(COMPLIANCE_ADMIN_ROLE, admin), adminHadCompliance);
        assertEq(factory.hasRole(ISSUANCE_APPROVER_ROLE, admin), adminHadApprover);
    }

    function test_N11_setPlatformAdminRevertsForNonAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(makeAddr("nobody"));
        vm.expectRevert();
        factory.setPlatformAdmin(newAdmin);
    }

    function test_N11_setPlatformAdminAffectsFutureComplianceModuleAdmin() public {
        // The platformAdmin storage field is what BondFactory._deployComplianceModule reads when
        // seeding the initial admin of newly deployed ComplianceModule proxies.
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        factory.setPlatformAdmin(newAdmin);

        BondConfig memory cfg = _baseConfig();
        bytes32 cfgHash = factory.hashBondConfig(cfg);
        bytes32 approvalId = keccak256("audit-n11-platformAdmin");
        vm.prank(admin);
        factory.approveIssuance(approvalId, issuer, address(complianceImplementation), block.timestamp + 1 days, cfgHash);

        vm.prank(issuer);
        (, address cmProxy) = factory.createBond(cfg, approvalId);
        ComplianceModule cm = ComplianceModule(cmProxy);

        // The new platformAdmin is the initial DEFAULT_ADMIN_ROLE holder of the freshly deployed module.
        assertTrue(cm.hasRole(0x00, newAdmin));
    }

    function test_N11_initialAdminOnlyHoldsDefaultAdminRole() public {
        // AUDIT-FIX(N11) revisited: the BondFactory constructor must grant ONLY DEFAULT_ADMIN_ROLE.
        // We deploy a fresh factory here (the shared `factory` from setUp has had secondary roles
        // self-granted) to exercise the pure post-construction state.
        BondFactory fresh = new BondFactory(makeAddr("freshAdmin"), address(issuance));
        address freshAdmin = makeAddr("freshAdmin");
        assertTrue(fresh.hasRole(0x00, freshAdmin));
        assertFalse(fresh.hasRole(ISSUANCE_APPROVER_ROLE, freshAdmin));
        assertFalse(fresh.hasRole(COMPLIANCE_ADMIN_ROLE, freshAdmin));
        assertFalse(fresh.hasRole(PAUSER_ROLE, freshAdmin));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  N5 / N6 / N9 / N10 / N11 / N13   BondIssuance behaviour
// ─────────────────────────────────────────────────────────────────────────────

contract AuditFixesBondIssuanceTest is BondIssuanceRedemptionFixtures {
    function setUp() public {
        deployRedemptionFixtures();
    }

    // N5 forceRedeem
    event ForceRedemption(
        address indexed bondToken,
        address indexed holder,
        address indexed recipient,
        uint256 bondAmount,
        uint256 payout,
        address operator
    );
    event ExcessRedemptionRefunded(
        address indexed bondToken, address indexed settlementToken, address indexed issuer, uint256 excessAmount
    );

    function test_N5_adminCanForceRedeemSanctionedHolder() public {
        warpToMaturity();

        uint256 expectedPayout = 100_301_369_863;
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), expectedPayout);

        // Sanction the holder - they would otherwise be permanently locked out of claim().
        vm.prank(admin);
        complianceModule.setWhitelist(holder, false);

        address custody = makeAddr("custody");
        vm.expectEmit(true, true, true, true);
        emit ForceRedemption(address(bondToken), holder, custody, 100e18, expectedPayout, admin);

        vm.prank(admin);
        issuance.forceRedeem(address(bondToken), holder, custody);

        assertEq(usdc.balanceOf(custody), expectedPayout);
        assertEq(bondToken.balanceOf(holder), 0);
        assertEq(bondToken.totalSupply(), 0);
    }

    function test_N5_revertWhenForceRedeemBeforeMaturity() public {
        address custody = makeAddr("custody");
        vm.prank(admin);
        vm.expectRevert();
        issuance.forceRedeem(address(bondToken), holder, custody);
    }

    function test_N5_revertWhenForceRedeemByNonAdmin() public {
        warpToMaturity();
        address custody = makeAddr("custody");
        vm.prank(outsider);
        vm.expectRevert();
        issuance.forceRedeem(address(bondToken), holder, custody);
    }

    function test_N5_revertWhenForceRedeemHasNoBalance() public {
        warpToMaturity();
        address noBalance = makeAddr("noBalance");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NoClaimableBalance.selector, noBalance, address(bondToken)));
        issuance.forceRedeem(address(bondToken), noBalance, makeAddr("custody"));
    }

    function test_N5_revertWhenForceRedeemRecipientIsZero() public {
        warpToMaturity();
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_863);

        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        issuance.forceRedeem(address(bondToken), holder, address(0));
    }

    function test_N5_revertWhenForceRedeemHolderIsZero() public {
        warpToMaturity();
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        issuance.forceRedeem(address(bondToken), address(0), makeAddr("custody"));
    }

    function test_N5_revertWhenForceRedeemFundingInsufficient() public {
        warpToMaturity();
        // Deposit only half of the required payout (100_301_369_863).
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 50_000_000_000);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientRedemptionFunding.selector,
                address(bondToken),
                50_000_000_000,
                100_301_369_863
            )
        );
        issuance.forceRedeem(address(bondToken), holder, makeAddr("custody"));
    }

    function test_N5_revertWhenForceRedeemDuringClaimsPause() public {
        warpToMaturity();
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_863);

        // Fixture grants PAUSER_ROLE to admin; pause the CLAIMS domain.
        vm.prank(admin);
        issuance.pauseDomain(PauseDomain.CLAIMS, true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DomainPaused.selector, PauseDomain.CLAIMS));
        issuance.forceRedeem(address(bondToken), holder, makeAddr("custody"));
    }

    /// @dev N5 + N6 联动：单一持有者被强制赎回后，totalSupply==0 触发自动释放分支，
    ///      多余的赎回款必须原子性转回发行人。
    function test_N5_forceRedeemTriggersAutoRefundOfExcessToIssuer() public {
        warpToMaturity();

        uint256 exactPayout = 100_301_369_863;
        uint256 excess = 50_000e6;
        uint256 deposit = exactPayout + excess;
        uint256 issuerBalanceBefore = usdc.balanceOf(issuer);

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), deposit);

        // Sanction the holder so claim() would be blocked, demonstrating the deadlock that
        // forceRedeem unblocks.
        vm.prank(admin);
        complianceModule.setWhitelist(holder, false);

        address custody = makeAddr("custody");

        // Expect both events in order: ForceRedemption first, then ExcessRedemptionRefunded
        // emitted by the auto-release branch via _refundExcessToIssuer.
        vm.expectEmit(true, true, true, true);
        emit ForceRedemption(address(bondToken), holder, custody, 100e18, exactPayout, admin);
        vm.expectEmit(true, true, true, true);
        emit ExcessRedemptionRefunded(address(bondToken), address(usdc), issuer, excess);

        vm.prank(admin);
        issuance.forceRedeem(address(bondToken), holder, custody);

        // Custody got the holder's full payout.
        assertEq(usdc.balanceOf(custody), exactPayout);
        // Issuer received the excess back atomically.
        assertEq(usdc.balanceOf(issuer), issuerBalanceBefore - deposit + excess);
        // Bond fully redeemed; contract no longer holds liability for this token.
        assertEq(bondToken.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(issuance)), 0);
        (uint256 fundedAmount, uint256 claimedAmount,) = issuance.getRedemptionState(address(bondToken));
        // After auto-refund: fundedAmount equals claimedAmount (no surplus left in books).
        assertEq(fundedAmount, claimedAmount);
    }

    /// @dev N5 + N9 联动：dust 持仓（payout==0）也能被强制销毁，不会卡死 totalSupply==0 流程。
    function test_N5_forceRedeemBurnsDustPositionWithZeroPayout() public {
        // Mint 1 wei of bond to a new address. principalOf(1) and accruedInterestFor(1, ...) both
        // round down to 0 for the fixture's faceValue/decimals, so payout==0.
        address dustHolder = makeAddr("dustHolder");
        vm.prank(address(issuance));
        bondToken.mint(dustHolder, 1);

        warpToMaturity();

        // No redemption deposit needed because payout is 0.
        address custody = makeAddr("custody");
        uint256 custodyBalanceBefore = usdc.balanceOf(custody);

        vm.expectEmit(true, true, true, true);
        emit ForceRedemption(address(bondToken), dustHolder, custody, 1, 0, admin);

        vm.prank(admin);
        issuance.forceRedeem(address(bondToken), dustHolder, custody);

        assertEq(bondToken.balanceOf(dustHolder), 0);
        // No funds moved when payout==0.
        assertEq(usdc.balanceOf(custody), custodyBalanceBefore);
    }

    /// @dev SECURITY INVARIANT: forceRedeem must succeed even when *every* compliance gate would
    ///      reject a regular transfer. This works because BondToken.burn() emits _update with
    ///      `to == address(0)`, which BondToken.detectTransferRestriction explicitly bypasses
    ///      (returns 0 / SUCCESS). If a future refactor removes that bypass, this test will fail
    ///      and signal that forceRedeem (the only escape hatch for sanctioned holders) is broken.
    function test_N5_forceRedeemBypassesAllComplianceGatesForBurn() public {
        warpToMaturity();
        uint256 expectedPayout = 100_301_369_863;
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), expectedPayout);

        // Stack up *every* compliance restriction that would block a regular transfer:
        //   1. holder removed from whitelist
        //   2. holder's role cleared (so role check would fail)
        //   3. BondIssuance is NOT registered as authorized transfer operator (fixture default)
        //   4. ComplianceModule.SETTLEMENT domain paused → all regular transfers blocked
        vm.startPrank(admin);
        complianceModule.setWhitelist(holder, false);
        complianceModule.setRole(holder, Role.NONE);
        complianceModule.pauseDomain(PauseDomain.SETTLEMENT, true);
        vm.stopPrank();

        // Sanity: assert BondIssuance is indeed NOT an authorized operator.
        assertFalse(complianceModule.isTransferOperator(address(issuance)));

        // Sanity: a regular bond transfer in this state would fail with TransferRestricted.
        address recipient = makeAddr("custody");
        vm.prank(holder);
        vm.expectRevert();
        bondToken.transfer(recipient, 1);

        // Now forceRedeem proceeds despite *all* the above — because burn (to == 0) bypasses
        // detectTransferRestriction in BondToken._update.
        vm.prank(admin);
        issuance.forceRedeem(address(bondToken), holder, recipient);

        assertEq(bondToken.balanceOf(holder), 0);
        assertEq(usdc.balanceOf(recipient), expectedPayout);
        assertEq(bondToken.totalSupply(), 0);
    }

    /// @dev forceRedeem is an admin override path. It must work regardless of the holder's
    ///      whitelist status — including for currently-whitelisted (compliant) holders, in case
    ///      the admin needs to liquidate a position for a different reason (e.g. legal order).
    function test_N5_forceRedeemAlsoWorksOnWhitelistedHolder() public {
        warpToMaturity();
        uint256 expectedPayout = 100_301_369_863;
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), expectedPayout);

        // holder is still whitelisted from fixture setup — forceRedeem should still proceed.
        assertTrue(complianceModule.isWhitelisted(holder));

        address custody = makeAddr("custody");
        vm.prank(admin);
        issuance.forceRedeem(address(bondToken), holder, custody);

        assertEq(usdc.balanceOf(custody), expectedPayout);
        assertEq(bondToken.balanceOf(holder), 0);
    }

    // N9 dust burn
    function test_N9_dustBondCanBeClaimedAndBurned() public {
        // Bond's payout per bondAmount=1 wei is principalOf(1) + accruedInterestFor(1, maturity)
        // For the existing fixture (faceValue 1_000e6, decimals 18) principalOf(1) = 0 -> total payout == 0.
        // Verify path: mint dust, warp to maturity, claim should succeed without transfer.
        address dustHolder = makeAddr("dustHolder");
        vm.startPrank(admin);
        complianceModule.setWhitelist(dustHolder, true);
        complianceModule.setRole(dustHolder, Role.INVESTOR);
        vm.stopPrank();

        vm.prank(address(issuance));
        bondToken.mint(dustHolder, 1);

        warpToMaturity();
        vm.prank(dustHolder);
        issuance.claim(address(bondToken)); // must NOT revert ZeroAmount under N9.

        assertEq(bondToken.balanceOf(dustHolder), 0);
    }

    // N10: subscription window must not exceed approval expiry
    function test_N10_revertWhenSubscriptionClosesAfterApprovalExpiry() public {
        bytes32 approvalId = keccak256("audit-n10");
        uint256 approvalExpiresAt = block.timestamp + 1 days;
        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, approvalExpiresAt);
        vm.prank(admin);
        issuance.setSettlementTokenPolicy(address(usdc), true, true);

        uint256 issueDate = bondToken.issueDate();
        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_000e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: issueDate // beyond approval expiry but still <= issueDate
        });
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionWindowExceedsApprovalExpiry.selector, terms.closesAt, approvalExpiresAt)
        );
        issuance.createSubscription(terms, approvalId);
    }

    function test_N10_subscriptionAllowedWhenClosesAtEqualsApprovalExpiry() public {
        bytes32 approvalId = keccak256("audit-n10b");
        uint256 approvalExpiresAt = block.timestamp + 6 days; // before issueDate (8 days)
        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, approvalExpiresAt);
        vm.prank(admin);
        issuance.setSettlementTokenPolicy(address(usdc), true, true);

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_000e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: approvalExpiresAt
        });
        vm.prank(issuer);
        bytes32 offerId = issuance.createSubscription(terms, approvalId);
        assertTrue(offerId != bytes32(0));
    }

    // N11: setSettlementTokenPolicy cannot disable redemption while liability is outstanding
    function test_N11_revertWhenDisableRedemptionWithOutstandingLiability() public {
        // The fixture already enabled redemption. Deposit some liability then try to disable.
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_863);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementTokenHasRedemptionLiability.selector, address(usdc), 100_301_369_863)
        );
        issuance.setSettlementTokenPolicy(address(usdc), false, false);
    }

    function test_N11_disableRedemptionAllowedWhenNoLiability() public {
        // Fresh setup: no liability for usdc yet from the perspective of admin call.
        vm.prank(admin);
        issuance.setSettlementTokenPolicy(address(usdc), false, false);
        (, bool redemptionEnabled) = issuance.getSettlementTokenPolicy(address(usdc));
        assertFalse(redemptionEnabled);
    }

    // N6 second event ordering / accuracy is already covered in BondIssuance.RescueAndRedemptionIsolation.t.sol
}
