// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {MilestoneRegistry} from "../src/MilestoneRegistry.sol";
import {IMilestoneRegistry} from "../src/interfaces/IMilestoneRegistry.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";

// ── Minimal USDC interface (includes testnet mint) ────────────────────────────
interface ITestUSDC {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

// ── Minimal vault view interface ──────────────────────────────────────────────
interface IVaultView {
    enum VaultState { Fundraising, Active, Repaying, Completed, Cancelled, Defaulted }
    function state() external view returns (VaultState);
    function tranchesReleased() external view returns (uint256);
    function totalRaised() external view returns (uint256);
    function totalRepaid() external view returns (uint256);
    function totalToRepay() external view returns (uint256);
    function invest(uint256 amount) external;
    function releaseTranche() external;
    function getAgent() external view returns (address);
}

/// @title SeedDemo - Krexa investor demo data seeder
/// @notice Populates Base Sepolia with realistic demo state using already-deployed contracts.
///         Run ONCE before an investor presentation to create a compelling live demo.
///
/// Prerequisites:
///   - DEPLOYER_PRIVATE_KEY: must be the oracle/admin key (0xA1090527...)
///   - Deployer needs ~800,000 test USDC (get from faucet.circle.com or script auto-mints)
///   - BASE_SEPOLIA_RPC_URL set in .env
///
/// Idempotent: re-running skips already-completed steps.
contract SeedDemo is Script {

    // ── Deployed Contract Addresses (Base Sepolia) ────────────────────────────
    address constant REGISTRY            = 0xAEa7C5CCACebB1423b163b765d3214752f1496A4;
    address constant ROUTER              = 0xf8A5ED433222dFfb9514637243C3599cCE87f977;
    address constant FACTORY             = 0xf8fDa17F877dEFFCD80784E0465F33d585644360;
    address constant SENIOR_POOL         = 0xDf980d0734b00888e4Ac350027515B4D6E473bBa;
    address constant GENERAL_POOL        = 0x7E7D8082572C0AD2f51074D272A501180Db06Fb2;
    address constant USDC                = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant MILESTONE_REGISTRY  = 0x48a471eEB88f84a867bEBC0f6DFF848660BC8c84;

    // ── Demo Amounts ──────────────────────────────────────────────────────────
    uint256 constant SENIOR_DEPOSIT    = 500_000e6;   // 500k USDC into SeniorPool
    uint256 constant GENERAL_DEPOSIT   = 200_000e6;   // 200k USDC into GeneralPool
    uint256 constant VAULT_A_TARGET    = 100_000e6;   // Vault A: 100k USDC loan
    uint256 constant VAULT_B_TARGET    =  50_000e6;   // Vault B: 50k USDC (fundraising)
    uint256 constant VAULT_A_SENIOR    =  70_000e6;   // SeniorPool -> Vault A
    uint256 constant VAULT_A_GENERAL   =  20_000e6;   // GeneralPool -> Vault A
    uint256 constant VAULT_A_COMMUNITY =  10_000e6;   // deployer community investment

    // ── Dummy evidence hash for demo milestones ───────────────────────────────
    bytes32 constant DEMO_EVIDENCE_HASH = keccak256("krexa.demo.milestone.evidence.approved.v1");

    // ── Payment nonce tracker (per deployer as x402 payer) ────────────────────
    uint256 private _nextNonce;

    // ─────────────────────────────────────────────────────────────────────────
    // MAIN ENTRY POINT
    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Deterministic merchant private keys - TESTNET ONLY, never use on mainnet
        uint256 keyA = uint256(keccak256("krexa.demo.merchant_a.v1"));
        uint256 keyB = uint256(keccak256("krexa.demo.merchant_b.v1"));
        uint256 keyC = uint256(keccak256("krexa.demo.merchant_c.v1"));
        uint256 keyD = uint256(keccak256("krexa.demo.merchant_d.v1"));

        address merchantA = vm.addr(keyA);
        address merchantB = vm.addr(keyB);
        address merchantC = vm.addr(keyC);
        address merchantD = vm.addr(keyD);

        console.log("========================================");
        console.log(" Krexa Demo Seed - Base Sepolia");
        console.log("========================================");
        console.log("Admin/Oracle:              ", deployer);
        console.log("Merchant A (GlobalTextiles):", merchantA);
        console.log("Merchant B (TechSaaSCo):   ", merchantB);
        console.log("Merchant C (LocalCrafts):  ", merchantC);
        console.log("Merchant D (NewStartup):   ", merchantD);
        console.log("");

        // ── STEP 1: Register merchants & set credit scores ────────────────────
        _step1_registerMerchants(deployerKey, keyA, keyB, keyC, keyD,
                                 merchantA, merchantB, merchantC, merchantD);

        // ── STEP 2: Deposit liquidity into pools ──────────────────────────────
        _step2_fundPools(deployerKey, deployer);

        // ── STEP 3: Create & activate Vault A (mid-repayment) ────────────────
        _step3_createVaultA(deployerKey, deployer, keyA, merchantA);

        // ── STEP 3b: Create Vault B (leave in Fundraising for live demo) ──────
        _step3b_createVaultB(deployerKey, deployer, keyB, merchantB);

        // ── STEP 4: Generate 20 x402 payment events on Vault A ───────────────
        _step4_generatePayments(deployerKey, deployer, merchantA);

        console.log("");
        console.log("========================================");
        console.log(" Seed complete. Demo is ready!");
        console.log("========================================");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 1 - Register 4 merchants + set credit scores
    // ─────────────────────────────────────────────────────────────────────────

    function _step1_registerMerchants(
        uint256 deployerKey,
        uint256 keyA, uint256 keyB, uint256 keyC, uint256 keyD,
        address merchantA, address merchantB, address merchantC, address merchantD
    ) internal {
        console.log("[Step 1] Registering merchants...");

        AgentRegistry registry = AgentRegistry(REGISTRY);

        // Each merchant must call registerAgent from their own address
        _registerIfNeeded(keyA, merchantA, "ipfs://krexa-demo/global-textiles.json", registry);
        _registerIfNeeded(keyB, merchantB, "ipfs://krexa-demo/tech-saas-co.json",    registry);
        _registerIfNeeded(keyC, merchantC, "ipfs://krexa-demo/local-crafts.json",    registry);
        _registerIfNeeded(keyD, merchantD, "ipfs://krexa-demo/new-startup.json",     registry);

        // Admin updates credit scores
        vm.startBroadcast(deployerKey);
        registry.updateCreditScore(merchantA, 780); // Tier A (>=750)
        registry.updateCreditScore(merchantB, 650); // Tier B (>=600)
        registry.updateCreditScore(merchantC, 500); // Tier C (>=450)
        registry.updateCreditScore(merchantD, 380); // Tier D (<450) - BLOCKED from vaults
        vm.stopBroadcast();

        console.log("  GlobalTextiles  score=780  Tier A  (Full access, best rates)");
        console.log("  TechSaaSCo      score=650  Tier B  (Full access)");
        console.log("  LocalCrafts     score=500  Tier C  (Full access)");
        console.log("  NewStartup      score=380  Tier D  (BLOCKED - system enforcement demo)");
        console.log("");
    }

    function _registerIfNeeded(
        uint256 key,
        address merchant,
        string memory metadataURI,
        AgentRegistry registry
    ) internal {
        if (registry.isRegistered(merchant)) {
            console.log("  [skip] Already registered:", merchant);
            return;
        }
        vm.startBroadcast(key);
        registry.registerAgent(metadataURI);
        vm.stopBroadcast();
        console.log("  [ok]   Registered:", merchant);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 2 - Deposit liquidity into SeniorPool and GeneralPool
    // ─────────────────────────────────────────────────────────────────────────

    function _step2_fundPools(uint256 deployerKey, address deployer) internal {
        console.log("[Step 2] Funding liquidity pools...");

        ITestUSDC usdc        = ITestUSDC(USDC);
        LiquidityPool senior  = LiquidityPool(SENIOR_POOL);
        LiquidityPool general = LiquidityPool(GENERAL_POOL);

        uint256 needed = SENIOR_DEPOSIT + GENERAL_DEPOSIT
                       + VAULT_A_COMMUNITY   // for community invest later
                       + 84_000e6;           // reserve for 20 payments (step 4)

        vm.startBroadcast(deployerKey);

        _ensureUsdc(usdc, deployer, needed);

        // Deposit into SeniorPool (isAlpha=true - senior tranche)
        usdc.approve(SENIOR_POOL, SENIOR_DEPOSIT);
        senior.deposit(SENIOR_DEPOSIT);
        console.log("  Deposited 500,000 USDC into SeniorPool");

        // Deposit into GeneralPool (isAlpha=false - LP tranche)
        usdc.approve(GENERAL_POOL, GENERAL_DEPOSIT);
        general.deposit(GENERAL_DEPOSIT);
        console.log("  Deposited 200,000 USDC into GeneralPool");

        vm.stopBroadcast();

        console.log("  Pool TVL: 700,000 USDC total");
        console.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 3 - Create Vault A: 100k USDC, 12% APY, 3 tranches, mid-repayment
    // ─────────────────────────────────────────────────────────────────────────

    function _step3_createVaultA(
        uint256 deployerKey,
        address deployer,
        uint256 keyA,
        address merchantA
    ) internal {
        console.log("[Step 3] Setting up Vault A (GlobalTextiles - 100k, 12% APY)...");

        VaultFactory  factory  = VaultFactory(FACTORY);
        LiquidityPool senior   = LiquidityPool(SENIOR_POOL);
        LiquidityPool general  = LiquidityPool(GENERAL_POOL);
        ITestUSDC     usdc     = ITestUSDC(USDC);

        address vaultAddr = factory.agentToVault(merchantA);

        vm.startBroadcast(deployerKey);

        // ── Create vault (idempotent) ──────────────────────────────────────
        if (vaultAddr == address(0)) {
            vaultAddr = factory.createVault(
                merchantA,
                VAULT_A_TARGET,              // 100,000 USDC
                1200,                        // 12% APY (interestRateBps)
                180 days,                    // 6-month term
                3,                           // 3 tranches
                5000,                        // repaymentRateBps: 50% of x402 -> repayment
                0,                           // minPaymentInterval: 0 (no rate limit, for demo)
                0,                           // maxSinglePayment: unlimited
                100,                         // lateFeeBps: 1%
                7 days,                      // gracePeriodSeconds
                block.timestamp + 30 days    // fundraisingDeadline
            );
            console.log("  Created Vault A:", vaultAddr);
        } else {
            console.log("  [skip] Vault A already exists:", vaultAddr);
        }

        IVaultView vault = IVaultView(vaultAddr);

        // ── Fund vault from pools + community (idempotent) ────────────────
        if (vault.state() == IVaultView.VaultState.Fundraising) {
            // 70k from SeniorPool -> vault.investSenior(70k)
            senior.allocateToVault(vaultAddr, VAULT_A_SENIOR);
            console.log("  Allocated  70,000 USDC from SeniorPool  (senior tranche)");

            // 20k from GeneralPool -> vault.investFromPool(20k)
            general.allocateToVault(vaultAddr, VAULT_A_GENERAL);
            console.log("  Allocated  20,000 USDC from GeneralPool (LP tranche)");

            // 10k community invest from deployer - triggers auto-activation at 100k
            usdc.approve(vaultAddr, VAULT_A_COMMUNITY);
            vault.invest(VAULT_A_COMMUNITY);
            console.log("  Invested   10,000 USDC  (community tranche)");
            console.log("  Vault auto-activated: Fundraising -> Active (100k raised = target)");
        } else {
            console.log("  [skip] Vault A already funded (state:", uint8(vault.state()), ")");
        }

        vm.stopBroadcast();

        // ── Pre-approve milestones for all 3 tranches ──────────────────────
        // Required before releaseTranche() calls.
        // Milestone gate must be Approved for each tranche.
        _approveMilestonesForVault(deployerKey, deployer, keyA, vaultAddr, 3);

        vm.startBroadcast(deployerKey);

        // ── Release first tranche (idempotent) ────────────────────────────
        if (vault.tranchesReleased() == 0 &&
            vault.state() != IVaultView.VaultState.Fundraising)
        {
            vault.releaseTranche();
            console.log("  Released tranche 1/3: ~33,333 USDC disbursed to GlobalTextiles");
        } else if (vault.tranchesReleased() > 0) {
            console.log("  [skip] Tranche already released (released:", vault.tranchesReleased(), ")");
        }

        vm.stopBroadcast();
        console.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 3b - Create Vault B: 50k USDC, 15% APY, leave in Fundraising
    // ─────────────────────────────────────────────────────────────────────────

    function _step3b_createVaultB(
        uint256 deployerKey,
        address deployer,
        uint256 keyB,
        address merchantB
    ) internal {
        console.log("[Step 3b] Creating Vault B (TechSaaSCo - 50k, 15% APY, Fundraising)...");

        VaultFactory factory = VaultFactory(FACTORY);
        address vaultAddr    = factory.agentToVault(merchantB);

        if (vaultAddr == address(0)) {
            vm.startBroadcast(deployerKey);

            vaultAddr = factory.createVault(
                merchantB,
                VAULT_B_TARGET,              // 50,000 USDC
                1500,                        // 15% APY
                90 days,                     // 3-month term
                2,                           // 2 tranches
                2500,                        // repaymentRateBps: 25%
                0,                           // minPaymentInterval
                0,                           // maxSinglePayment: unlimited
                150,                         // lateFeeBps: 1.5%
                7 days,                      // gracePeriodSeconds
                block.timestamp + 14 days    // 2-week fundraising window for live demo
            );

            vm.stopBroadcast();

            console.log("  Created Vault B:", vaultAddr);
            console.log("  State: Fundraising - investors can fund this LIVE in the demo!");
            console.log("  Fundraising closes: 14 days from now");
        } else {
            console.log("  [skip] Vault B already exists:", vaultAddr);
        }

        // ── Pre-approve milestones for both tranches ───────────────────────
        // Even though vault is in Fundraising, pre-approving ensures that when
        // demo investors fund it and tranches release, there are no milestone blocks.
        _approveMilestonesForVault(deployerKey, deployer, keyB, vaultAddr, 2);

        console.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STEP 4 - Generate 20 realistic x402 payment events on Vault A
    // ─────────────────────────────────────────────────────────────────────────

    function _step4_generatePayments(
        uint256 deployerKey,
        address deployer,
        address merchantA
    ) internal {
        console.log("[Step 4] Generating 20 x402 payment events on Vault A...");

        VaultFactory factory = VaultFactory(FACTORY);
        address vaultAddr    = factory.agentToVault(merchantA);
        require(vaultAddr != address(0), "SeedDemo: Vault A not found");

        IVaultView    vault  = IVaultView(vaultAddr);
        PaymentRouter router = PaymentRouter(ROUTER);
        ITestUSDC     usdc   = ITestUSDC(USDC);

        IVaultView.VaultState currentState = vault.state();
        if (currentState != IVaultView.VaultState.Active &&
            currentState != IVaultView.VaultState.Repaying)
        {
            console.log("  [skip] Vault A not in Active/Repaying state. Skipping payments.");
            return;
        }

        // Payment amounts in USDC (6 decimals) - varied to look like real business revenue
        // Total: 84,000 USDC. At 50% repaymentRateBps -> 42,000 USDC to vault ~= 40% of loan.
        uint256[20] memory amounts = [
            uint256( 2_500e6), uint256( 5_500e6), uint256( 1_500e6), uint256( 8_000e6),
            uint256( 3_500e6), uint256( 4_200e6), uint256( 1_000e6), uint256( 7_800e6),
            uint256( 5_200e6), uint256( 1_800e6), uint256( 3_800e6), uint256( 9_200e6),
            uint256( 3_000e6), uint256( 2_200e6), uint256( 6_800e6), uint256( 2_000e6),
            uint256( 4_800e6), uint256( 3_200e6), uint256( 5_800e6), uint256( 2_200e6)
        ];

        // ── Pre-compute oracle signatures (local, no broadcast) ───────────────
        // Find starting nonce on-chain (skips any already-used from prior runs)
        _nextNonce = _findStartingNonce(router, deployer);
        console.log("  Starting from nonce:", _nextNonce);

        uint256[20] memory nonces;
        bytes[20] memory sigs;
        bytes32[20] memory paymentIds;
        uint256 deadline = block.timestamp + 2 hours;

        for (uint256 i = 0; i < 20; i++) {
            nonces[i]     = _nextNonce + i;
            paymentIds[i] = keccak256(abi.encodePacked("krexa-x402-demo-v1", nonces[i]));
            sigs[i]       = _signPayment(
                deployerKey,
                deployer,    // from: the x402 payer (deployer simulates customers)
                merchantA,   // to:   the merchant receiving payment
                amounts[i],
                nonces[i],
                deadline,
                paymentIds[i]
            );
        }

        // ── Broadcast payment transactions ────────────────────────────────────
        uint256 totalVolume = 84_000e6;

        vm.startBroadcast(deployerKey);

        _ensureUsdc(usdc, deployer, totalVolume);
        usdc.approve(address(router), totalVolume);

        for (uint256 i = 0; i < 20; i++) {
            IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
                from:      deployer,
                to:        merchantA,
                amount:    amounts[i],
                nonce:     nonces[i],
                deadline:  deadline,
                paymentId: paymentIds[i]
            });

            router.executePayment(payment, sigs[i]);

            console.log("  Payment %s: %s USDC (nonce %s)",
                        i + 1, amounts[i] / 1e6, nonces[i]);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("  Total x402 volume:     84,000 USDC");
        console.log("  Routed to repayment:   42,000 USDC (50% rate)");
        console.log("  Vault state: mid-repayment (~40% of loan repaid)");
        console.log("  Waterfall events: 20 (Senior -> Pool -> Community)");
        console.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MILESTONE HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pre-approve all milestones for a demo vault so tranche releases
    ///         are never blocked by the MilestoneRegistry gate.
    ///
    ///         Three-phase process (each requires different msg.sender):
    ///           Phase 1 (deployer/admin): addVerifier + initializeMilestone per tranche
    ///           Phase 2 (vault agent):    submitMilestone per tranche
    ///           Phase 3 (deployer as verifier): voteMilestone(approve=true) per tranche
    ///
    ///         Idempotent: reads current on-chain state upfront and only executes
    ///         what hasn't been done yet.
    function _approveMilestonesForVault(
        uint256 deployerKey,
        address deployer,
        uint256 agentKey,
        address vault,
        uint256 numTranches
    ) internal {
        MilestoneRegistry milestone = MilestoneRegistry(MILESTONE_REGISTRY);

        console.log("  [milestones] Pre-approving", numTranches, "milestone(s) for vault:", vault);

        // ── Read current state upfront (no broadcast) ─────────────────────────
        bool needsVerifier = !milestone.isVerifier(deployer);
        bool[] memory needsInit   = new bool[](numTranches);
        bool[] memory needsSubmit = new bool[](numTranches);
        bool[] memory needsVote   = new bool[](numTranches);
        bool anyPhase1 = needsVerifier;
        bool anyPhase2 = false;
        bool anyPhase3 = false;

        for (uint256 i = 0; i < numTranches; i++) {
            IMilestoneRegistry.Milestone memory m = milestone.getMilestone(vault, i);

            if (m.status == IMilestoneRegistry.MilestoneStatus.Approved) {
                console.log("  [milestones]   [skip] tranche", i, "already approved");
                continue;
            }

            // Not initialized: requiredApprovals is still 0
            if (m.requiredApprovals == 0) {
                needsInit[i] = true;
                anyPhase1    = true;
                // After init it will be Pending -> needs submit + vote
                needsSubmit[i] = true;
                needsVote[i]   = true;
                anyPhase2 = true;
                anyPhase3 = true;
            } else if (m.status == IMilestoneRegistry.MilestoneStatus.Pending) {
                needsSubmit[i] = true;
                needsVote[i]   = true;
                anyPhase2 = true;
                anyPhase3 = true;
            } else if (m.status == IMilestoneRegistry.MilestoneStatus.Submitted) {
                needsVote[i] = true;
                anyPhase3    = true;
            }
        }

        // ── Phase 1: deployer (admin) - addVerifier + initializeMilestone ─────
        if (anyPhase1) {
            vm.startBroadcast(deployerKey);
            if (needsVerifier) {
                milestone.addVerifier(deployer);
                console.log("  [milestones]   Added deployer as verifier");
            }
            for (uint256 i = 0; i < numTranches; i++) {
                if (needsInit[i]) {
                    milestone.initializeMilestone(vault, i, 1); // requiredApprovals = 1
                    console.log("  [milestones]   Initialized tranche", i);
                }
            }
            vm.stopBroadcast();
        }

        // ── Phase 2: agent (vault owner) - submitMilestone ────────────────────
        if (anyPhase2) {
            vm.startBroadcast(agentKey);
            for (uint256 i = 0; i < numTranches; i++) {
                if (needsSubmit[i]) {
                    milestone.submitMilestone(vault, i, DEMO_EVIDENCE_HASH);
                    console.log("  [milestones]   Submitted evidence for tranche", i);
                }
            }
            vm.stopBroadcast();
        }

        // ── Phase 3: deployer (verifier) - voteMilestone(approve=true) ────────
        if (anyPhase3) {
            vm.startBroadcast(deployerKey);
            for (uint256 i = 0; i < numTranches; i++) {
                if (needsVote[i]) {
                    milestone.voteMilestone(vault, i, true);
                    console.log("  [milestones]   Approved tranche", i);
                }
            }
            vm.stopBroadcast();
        }

        if (!anyPhase1 && !anyPhase2 && !anyPhase3) {
            console.log("  [milestones]   [skip] All milestones already approved");
        } else {
            console.log("  [milestones]   All", numTranches, "milestone(s) approved");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Sign an x402 payment with the oracle private key.
    ///      Matches SignatureLib.verifyPaymentProof which does toEthSignedMessageHash internally.
    function _signPayment(
        uint256 oracleKey,
        address from,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes32 paymentId
    ) internal pure returns (bytes memory) {
        bytes32 rawHash = keccak256(abi.encode(from, to, amount, nonce, deadline, paymentId));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(rawHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oracleKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Find the first unused nonce for `payer` in the PaymentRouter.
    ///      Starts at 0 and scans forward - safe for demo use.
    function _findStartingNonce(PaymentRouter router, address payer)
        internal view returns (uint256)
    {
        uint256 nonce = 0;
        // Scan up to 1000 to handle multiple seed runs
        for (uint256 i = 0; i < 1000; i++) {
            if (!router.isNonceUsed(payer, i)) {
                return i;
            }
            nonce = i + 1;
        }
        return nonce;
    }

    /// @dev Attempt to mint test USDC if deployer balance is insufficient.
    ///      Circle's Base Sepolia USDC has a restricted mint - falls back to a balance check.
    ///      Call this INSIDE a vm.startBroadcast block.
    function _ensureUsdc(ITestUSDC usdc, address deployer, uint256 needed) internal {
        uint256 balance = usdc.balanceOf(deployer);
        if (balance >= needed) return;

        uint256 shortfall = needed - balance;
        console.log("  USDC balance: %s USDC (need %s USDC)", balance / 1e6, needed / 1e6);
        console.log("  Attempting to mint", shortfall / 1e6, "USDC...");

        try usdc.mint(deployer, shortfall) {
            console.log("  Minted successfully.");
        } catch {
            console.log("  Auto-mint failed. Get test USDC from: https://faucet.circle.com");
            revert(string(abi.encodePacked(
                "SeedDemo: insufficient USDC. Need ",
                _usdcStr(needed),
                " USDC. Get test USDC from faucet.circle.com then re-run."
            )));
        }
    }

    /// @dev Format a USDC amount (6 decimals) as a human-readable string for error messages.
    function _usdcStr(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        if (whole >= 1_000_000) return "1,000,000+";
        if (whole >= 100_000)   return "100,000+";
        if (whole >= 10_000)    return "10,000+";
        return "some";
    }
}
