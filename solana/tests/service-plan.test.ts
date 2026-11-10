/**
 * service-plan.test.ts
 *
 * Tests for krexa-service-plan: Type B service agent enforcement.
 * Covers: plan creation, milestone disbursement, expense management,
 * revenue monitoring, health transitions, and wind-down lifecycle.
 */

import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { KrexaServicePlan } from "../target/types/krexa_service_plan";
import { Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import {
  createMockUsdc,
  mintUsdc,
  getOrCreateUsdcAta,
  usdcAmount,
} from "./helpers/create-mock-usdc";
import {
  TOKEN_PROGRAM_ID,
  getOrCreateAssociatedTokenAccount,
  getAccount,
} from "@solana/spl-token";
import { expect } from "chai";

// ─────────────────────────────────────────────────────────────────────────────
// Constants (mirror krexa-common/src/constants.rs)
// ─────────────────────────────────────────────────────────────────────────────

const BPS_DENOMINATOR = 10_000;
const REVENUE_GREEN_BPS = 8_000;
const REVENUE_YELLOW_BPS = 5_000;
const REVENUE_ORANGE_BPS = 2_500;
const ZERO_REVENUE_ORANGE_DAYS = 7;
const ZERO_REVENUE_RED_DAYS = 14;
const WIND_DOWN_GRACE_SECONDS = 172_800; // 48 hours
const MAX_MILESTONES = 8;
const YELLOW_MILESTONE_DELAY_SECONDS = 604_800; // 7 days

// Wind-down states
const WIND_DOWN_NONE = 0;
const WIND_DOWN_GRACE = 1;
const WIND_DOWN_EXECUTING = 2;
const WIND_DOWN_COMPLETED = 3;

// Health states
const HEALTH_GREEN = 0;
const HEALTH_YELLOW = 1;
const HEALTH_ORANGE = 2;
const HEALTH_RED = 3;

describe("krexa-service-plan", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const servicePlan = anchor.workspace
    .KrexaServicePlan as Program<KrexaServicePlan>;

  // Keypairs
  const admin = (provider.wallet as anchor.Wallet).payer;
  const oracle = Keypair.generate();
  const owner1 = Keypair.generate();
  const agentWallet1 = Keypair.generate(); // mock agent wallet pubkey
  const stranger = Keypair.generate();

  // PDAs
  let configPda: PublicKey;
  let configBump: number;
  let planPda: PublicKey;
  let planBump: number;

  // Token accounts
  let mockUsdc: Awaited<ReturnType<typeof createMockUsdc>>;
  let vaultTokenAccount: PublicKey; // config PDA's token account (simulated vault)
  let agentTokenAccount: PublicKey; // agent wallet's token account

  // ─────────────────────────────────────────────────────────────────────────
  // Setup
  // ─────────────────────────────────────────────────────────────────────────

  before(async () => {
    // Airdrop SOL to test accounts
    const airdrops = [oracle, owner1, stranger].map(async (kp) => {
      const sig = await provider.connection.requestAirdrop(
        kp.publicKey,
        2_000_000_000
      );
      await provider.connection.confirmTransaction(sig);
    });
    await Promise.all(airdrops);

    // Create mock USDC
    mockUsdc = await createMockUsdc(provider);

    // Derive PDAs
    [configPda, configBump] = PublicKey.findProgramAddressSync(
      [Buffer.from("svc_config")],
      servicePlan.programId
    );

    [planPda, planBump] = PublicKey.findProgramAddressSync(
      [Buffer.from("service_plan"), agentWallet1.publicKey.toBuffer()],
      servicePlan.programId
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Initialization
  // ─────────────────────────────────────────────────────────────────────────

  describe("1. Initialize", () => {
    it("1-1: initializes service plan config", async () => {
      await servicePlan.methods
        .initialize(
          oracle.publicKey,
          Keypair.generate().publicKey, // credit_vault_program (mock)
          Keypair.generate().publicKey // agent_wallet_program (mock)
        )
        .accounts({
          config: configPda,
          admin: admin.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const config = await servicePlan.account.servicePlanConfig.fetch(
        configPda
      );
      expect(config.admin.toBase58()).to.equal(admin.publicKey.toBase58());
      expect(config.oracle.toBase58()).to.equal(oracle.publicKey.toBase58());
      expect(config.totalPlans.toNumber()).to.equal(0);
      expect(config.isPaused).to.be.false;
    });

    it("1-2: non-admin cannot update config", async () => {
      try {
        await servicePlan.methods
          .updateConfig(null, null)
          .accounts({
            config: configPda,
            admin: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotAdmin");
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Plan creation
  // ─────────────────────────────────────────────────────────────────────────

  describe("2. Create plan", () => {
    it("2-1: creates a service plan with milestones", async () => {
      const now = Math.floor(Date.now() / 1000);
      const totalCredit = new anchor.BN(10_000_000_000); // $10,000

      const milestones = [
        {
          amount: new anchor.BN(3_000_000_000), // $3,000
          descriptionHash: Buffer.alloc(32, 1),
          eligibleAt: new anchor.BN(now),
        },
        {
          amount: new anchor.BN(3_000_000_000), // $3,000
          descriptionHash: Buffer.alloc(32, 2),
          eligibleAt: new anchor.BN(now + 30 * 86400), // 30 days
        },
        {
          amount: new anchor.BN(4_000_000_000), // $4,000
          descriptionHash: Buffer.alloc(32, 3),
          eligibleAt: new anchor.BN(now + 60 * 86400), // 60 days
        },
      ];

      await servicePlan.methods
        .createPlan(totalCredit, milestones)
        .accounts({
          config: configPda,
          plan: planPda,
          agentWallet: agentWallet1.publicKey,
          owner: owner1.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([owner1])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.agentWallet.toBase58()).to.equal(
        agentWallet1.publicKey.toBase58()
      );
      expect(plan.owner.toBase58()).to.equal(owner1.publicKey.toBase58());
      expect(plan.totalCredit.toNumber()).to.equal(10_000_000_000);
      expect(plan.totalDisbursed.toNumber()).to.equal(0);
      expect(plan.milestoneCount).to.equal(3);
      expect(plan.health).to.equal(HEALTH_GREEN);
      expect(plan.windDownState).to.equal(WIND_DOWN_NONE);

      // Verify milestones
      expect(plan.milestones[0].amount.toNumber()).to.equal(3_000_000_000);
      expect(plan.milestones[0].isActive).to.be.true;
      expect(plan.milestones[0].disbursed).to.be.false;
      expect(plan.milestones[1].amount.toNumber()).to.equal(3_000_000_000);
      expect(plan.milestones[2].amount.toNumber()).to.equal(4_000_000_000);

      // Inactive milestone slots
      expect(plan.milestones[3].isActive).to.be.false;

      // Check config counter
      const config = await servicePlan.account.servicePlanConfig.fetch(
        configPda
      );
      expect(config.totalPlans.toNumber()).to.equal(1);
    });

    it("2-2: rejects milestone sum exceeding total credit", async () => {
      const agentWallet2 = Keypair.generate();
      const [plan2Pda] = PublicKey.findProgramAddressSync(
        [Buffer.from("service_plan"), agentWallet2.publicKey.toBuffer()],
        servicePlan.programId
      );

      const milestones = [
        {
          amount: new anchor.BN(6_000_000_000),
          descriptionHash: Buffer.alloc(32, 1),
          eligibleAt: new anchor.BN(0),
        },
        {
          amount: new anchor.BN(6_000_000_000), // sum = $12k > $10k
          descriptionHash: Buffer.alloc(32, 2),
          eligibleAt: new anchor.BN(0),
        },
      ];

      try {
        await servicePlan.methods
          .createPlan(new anchor.BN(10_000_000_000), milestones)
          .accounts({
            config: configPda,
            plan: plan2Pda,
            agentWallet: agentWallet2.publicKey,
            owner: owner1.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([owner1])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("MilestoneSumExceedsCredit");
      }
    });

    it("2-3: rejects zero total credit", async () => {
      const agentWallet3 = Keypair.generate();
      const [plan3Pda] = PublicKey.findProgramAddressSync(
        [Buffer.from("service_plan"), agentWallet3.publicKey.toBuffer()],
        servicePlan.programId
      );

      try {
        await servicePlan.methods
          .createPlan(new anchor.BN(0), [])
          .accounts({
            config: configPda,
            plan: plan3Pda,
            agentWallet: agentWallet3.publicKey,
            owner: owner1.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([owner1])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("ZeroCredit");
      }
    });

    it("2-4: rejects more than 8 milestones", async () => {
      const agentWallet4 = Keypair.generate();
      const [plan4Pda] = PublicKey.findProgramAddressSync(
        [Buffer.from("service_plan"), agentWallet4.publicKey.toBuffer()],
        servicePlan.programId
      );

      const milestones = Array.from({ length: 9 }, (_, i) => ({
        amount: new anchor.BN(100_000_000), // $100 each
        descriptionHash: Buffer.alloc(32, i),
        eligibleAt: new anchor.BN(0),
      }));

      try {
        await servicePlan.methods
          .createPlan(new anchor.BN(10_000_000_000), milestones)
          .accounts({
            config: configPda,
            plan: plan4Pda,
            agentWallet: agentWallet4.publicKey,
            owner: owner1.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([owner1])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("MaxMilestonesReached");
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Expense destination management
  // ─────────────────────────────────────────────────────────────────────────

  describe("3. Expense destinations", () => {
    const destKeypair = Keypair.generate();
    let expenseDestPda: PublicKey;

    before(() => {
      [expenseDestPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("expense_dest"),
          planPda.toBuffer(),
          destKeypair.publicKey.toBuffer(),
        ],
        servicePlan.programId
      );
    });

    it("3-1: owner adds an expense destination", async () => {
      const labelHash = Buffer.alloc(32, 0xaa);
      const category = 1; // API
      const maxAmount = new anchor.BN(500_000_000); // $500 per-tx limit

      await servicePlan.methods
        .addExpenseDestination(
          Array.from(labelHash) as any,
          category,
          maxAmount
        )
        .accounts({
          config: configPda,
          plan: planPda,
          expenseDest: expenseDestPda,
          destination: destKeypair.publicKey,
          owner: owner1.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([owner1])
        .rpc();

      const dest = await servicePlan.account.expenseDestination.fetch(
        expenseDestPda
      );
      expect(dest.isActive).to.be.true;
      expect(dest.category).to.equal(1);
      expect(dest.maxAmount.toNumber()).to.equal(500_000_000);
      expect(dest.totalSent.toNumber()).to.equal(0);

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.expenseDestCount).to.equal(1);
    });

    it("3-2: non-owner cannot add expense destination", async () => {
      const dest2 = Keypair.generate();
      const [dest2Pda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("expense_dest"),
          planPda.toBuffer(),
          dest2.publicKey.toBuffer(),
        ],
        servicePlan.programId
      );

      try {
        await servicePlan.methods
          .addExpenseDestination(Array.from(Buffer.alloc(32, 0xbb)) as any, 0, new anchor.BN(0))
          .accounts({
            config: configPda,
            plan: planPda,
            expenseDest: dest2Pda,
            destination: dest2.publicKey,
            owner: stranger.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotOwner");
      }
    });

    it("3-3: owner removes an expense destination", async () => {
      await servicePlan.methods
        .removeExpenseDestination()
        .accounts({
          config: configPda,
          plan: planPda,
          expenseDest: expenseDestPda,
          owner: owner1.publicKey,
        })
        .signers([owner1])
        .rpc();

      const dest = await servicePlan.account.expenseDestination.fetch(
        expenseDestPda
      );
      expect(dest.isActive).to.be.false;

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.expenseDestCount).to.equal(0);
    });

    it("3-4: rejects invalid expense category (>4)", async () => {
      const dest3 = Keypair.generate();
      const [dest3Pda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("expense_dest"),
          planPda.toBuffer(),
          dest3.publicKey.toBuffer(),
        ],
        servicePlan.programId
      );

      try {
        await servicePlan.methods
          .addExpenseDestination(Array.from(Buffer.alloc(32, 0xcc)) as any, 5, new anchor.BN(0))
          .accounts({
            config: configPda,
            plan: planPda,
            expenseDest: dest3Pda,
            destination: dest3.publicKey,
            owner: owner1.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([owner1])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("InvalidCategory");
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Revenue monitoring & health transitions
  // ─────────────────────────────────────────────────────────────────────────

  describe("4. Revenue monitoring", () => {
    it("4-1: oracle sets projected revenue", async () => {
      const projected = new anchor.BN(5_000_000_000); // $5,000/month

      await servicePlan.methods
        .setProjectedRevenue(projected)
        .accounts({
          config: configPda,
          plan: planPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.projectedMonthlyRevenue.toNumber()).to.equal(5_000_000_000);
      expect(plan.actualRevenueThisPeriod.toNumber()).to.equal(0);
    });

    it("4-2: oracle records revenue — stays Green at ≥80%", async () => {
      // Record $4,000 = 80% of $5,000 → Green
      await servicePlan.methods
        .recordRevenue(new anchor.BN(4_000_000_000))
        .accounts({
          config: configPda,
          plan: planPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.health).to.equal(HEALTH_GREEN);
      expect(plan.actualRevenueThisPeriod.toNumber()).to.equal(4_000_000_000);
      expect(plan.zeroRevenueDays).to.equal(0);
    });

    it("4-3: non-oracle cannot record revenue", async () => {
      try {
        await servicePlan.methods
          .recordRevenue(new anchor.BN(1_000_000))
          .accounts({
            config: configPda,
            plan: planPda,
            oracle: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotOracle");
      }
    });

    it("4-4: oracle updates zero-revenue days — transitions to Orange at 7 days", async () => {
      await servicePlan.methods
        .updateZeroRevenueDays(ZERO_REVENUE_ORANGE_DAYS)
        .accounts({
          config: configPda,
          plan: planPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.health).to.equal(HEALTH_ORANGE);
      expect(plan.zeroRevenueDays).to.equal(7);
    });

    it("4-5: zero-revenue days 14 → transitions to Red", async () => {
      await servicePlan.methods
        .updateZeroRevenueDays(ZERO_REVENUE_RED_DAYS)
        .accounts({
          config: configPda,
          plan: planPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.health).to.equal(HEALTH_RED);
    });

    it("4-6: recording revenue resets zero-revenue days and recalculates health", async () => {
      // Reset projected revenue first
      await servicePlan.methods
        .setProjectedRevenue(new anchor.BN(5_000_000_000))
        .accounts({
          config: configPda,
          plan: planPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      // Record $4,500 (90% of $5k → Green)
      await servicePlan.methods
        .recordRevenue(new anchor.BN(4_500_000_000))
        .accounts({
          config: configPda,
          plan: planPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(planPda);
      expect(plan.health).to.equal(HEALTH_GREEN);
      expect(plan.zeroRevenueDays).to.equal(0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Wind-down lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  describe("5. Wind-down", () => {
    // Use a separate plan for wind-down tests
    const windDownAgent = Keypair.generate();
    let windDownPlanPda: PublicKey;

    before(async () => {
      [windDownPlanPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("service_plan"), windDownAgent.publicKey.toBuffer()],
        servicePlan.programId
      );

      const now = Math.floor(Date.now() / 1000);
      await servicePlan.methods
        .createPlan(new anchor.BN(5_000_000_000), [
          {
            amount: new anchor.BN(5_000_000_000),
            descriptionHash: Buffer.alloc(32, 0xff),
            eligibleAt: new anchor.BN(now),
          },
        ])
        .accounts({
          config: configPda,
          plan: windDownPlanPda,
          agentWallet: windDownAgent.publicKey,
          owner: owner1.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([owner1])
        .rpc();

      // Set projected revenue and push to Red
      await servicePlan.methods
        .setProjectedRevenue(new anchor.BN(5_000_000_000))
        .accounts({
          config: configPda,
          plan: windDownPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      await servicePlan.methods
        .updateZeroRevenueDays(ZERO_REVENUE_RED_DAYS)
        .accounts({
          config: configPda,
          plan: windDownPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();
    });

    it("5-1: oracle starts wind-down when health is Red", async () => {
      const planBefore = await servicePlan.account.servicePlan.fetch(
        windDownPlanPda
      );
      expect(planBefore.health).to.equal(HEALTH_RED);

      await servicePlan.methods
        .startWindDown()
        .accounts({
          config: configPda,
          plan: windDownPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(
        windDownPlanPda
      );
      expect(plan.windDownState).to.equal(WIND_DOWN_GRACE);
      expect(plan.windDownStartedAt.toNumber()).to.be.greaterThan(0);
    });

    it("5-2: cannot start wind-down twice", async () => {
      try {
        await servicePlan.methods
          .startWindDown()
          .accounts({
            config: configPda,
            plan: windDownPlanPda,
            oracle: oracle.publicKey,
          })
          .signers([oracle])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("WindDownAlreadyStarted");
      }
    });

    it("5-3: cannot advance wind-down before grace period elapses", async () => {
      try {
        await servicePlan.methods
          .advanceWindDown()
          .accounts({
            plan: windDownPlanPda,
            caller: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("GracePeriodNotElapsed");
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Pause functionality
  // ─────────────────────────────────────────────────────────────────────────

  describe("6. Pause", () => {
    it("6-1: admin can pause the program", async () => {
      await servicePlan.methods
        .setPaused(true)
        .accounts({
          config: configPda,
          admin: admin.publicKey,
        })
        .rpc();

      const config = await servicePlan.account.servicePlanConfig.fetch(
        configPda
      );
      expect(config.isPaused).to.be.true;
    });

    it("6-2: operations fail when paused", async () => {
      try {
        await servicePlan.methods
          .recordRevenue(new anchor.BN(1_000_000))
          .accounts({
            config: configPda,
            plan: planPda,
            oracle: oracle.publicKey,
          })
          .signers([oracle])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("Paused");
      }
    });

    it("6-3: admin can unpause", async () => {
      await servicePlan.methods
        .setPaused(false)
        .accounts({
          config: configPda,
          admin: admin.publicKey,
        })
        .rpc();

      const config = await servicePlan.account.servicePlanConfig.fetch(
        configPda
      );
      expect(config.isPaused).to.be.false;
    });

    it("6-4: non-admin cannot pause", async () => {
      try {
        await servicePlan.methods
          .setPaused(true)
          .accounts({
            config: configPda,
            admin: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotAdmin");
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Health zone transitions via revenue ratio
  // ─────────────────────────────────────────────────────────────────────────

  describe("7. Revenue velocity health zones", () => {
    const revenueAgent = Keypair.generate();
    let revPlanPda: PublicKey;

    before(async () => {
      [revPlanPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("service_plan"), revenueAgent.publicKey.toBuffer()],
        servicePlan.programId
      );

      await servicePlan.methods
        .createPlan(new anchor.BN(10_000_000_000), [])
        .accounts({
          config: configPda,
          plan: revPlanPda,
          agentWallet: revenueAgent.publicKey,
          owner: owner1.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([owner1])
        .rpc();

      // Set projected $10,000/month
      await servicePlan.methods
        .setProjectedRevenue(new anchor.BN(10_000_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();
    });

    it("7-1: 79% revenue → Yellow", async () => {
      // $7,900 of $10,000 = 79% < 80% Green threshold
      await servicePlan.methods
        .recordRevenue(new anchor.BN(7_900_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(revPlanPda);
      expect(plan.health).to.equal(HEALTH_YELLOW);
    });

    it("7-2: cumulative 50%+ stays Yellow (not Orange)", async () => {
      // Reset period
      await servicePlan.methods
        .setProjectedRevenue(new anchor.BN(10_000_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      // $5,000 of $10,000 = 50% → Yellow threshold
      await servicePlan.methods
        .recordRevenue(new anchor.BN(5_000_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(revPlanPda);
      expect(plan.health).to.equal(HEALTH_YELLOW);
    });

    it("7-3: 24% revenue → Red", async () => {
      // Reset period
      await servicePlan.methods
        .setProjectedRevenue(new anchor.BN(10_000_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      // $2,400 of $10,000 = 24% < 25% Orange threshold → Red
      await servicePlan.methods
        .recordRevenue(new anchor.BN(2_400_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(revPlanPda);
      expect(plan.health).to.equal(HEALTH_RED);
    });

    it("7-4: 30% revenue → Orange", async () => {
      // Reset period
      await servicePlan.methods
        .setProjectedRevenue(new anchor.BN(10_000_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      // $3,000 of $10,000 = 30% → between 25% and 50% → Orange
      await servicePlan.methods
        .recordRevenue(new anchor.BN(3_000_000_000))
        .accounts({
          config: configPda,
          plan: revPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(revPlanPda);
      expect(plan.health).to.equal(HEALTH_ORANGE);
    });

    it("7-5: no projection set → stays Green", async () => {
      const noProjectionAgent = Keypair.generate();
      const [npPlanPda] = PublicKey.findProgramAddressSync(
        [
          Buffer.from("service_plan"),
          noProjectionAgent.publicKey.toBuffer(),
        ],
        servicePlan.programId
      );

      await servicePlan.methods
        .createPlan(new anchor.BN(1_000_000_000), [])
        .accounts({
          config: configPda,
          plan: npPlanPda,
          agentWallet: noProjectionAgent.publicKey,
          owner: owner1.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([owner1])
        .rpc();

      // Record revenue without setting projection (projected = 0)
      await servicePlan.methods
        .recordRevenue(new anchor.BN(100_000_000))
        .accounts({
          config: configPda,
          plan: npPlanPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const plan = await servicePlan.account.servicePlan.fetch(npPlanPda);
      expect(plan.health).to.equal(HEALTH_GREEN); // no projection = always Green
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 8. Admin config updates
  // ─────────────────────────────────────────────────────────────────────────

  describe("8. Config management", () => {
    it("8-1: admin can rotate oracle", async () => {
      const newOracle = Keypair.generate();

      await servicePlan.methods
        .updateConfig(null, newOracle.publicKey)
        .accounts({
          config: configPda,
          admin: admin.publicKey,
        })
        .rpc();

      const config = await servicePlan.account.servicePlanConfig.fetch(
        configPda
      );
      expect(config.oracle.toBase58()).to.equal(
        newOracle.publicKey.toBase58()
      );

      // Rotate back for subsequent tests
      await servicePlan.methods
        .updateConfig(null, oracle.publicKey)
        .accounts({
          config: configPda,
          admin: admin.publicKey,
        })
        .rpc();
    });

    it("8-2: admin can transfer admin", async () => {
      const newAdmin = Keypair.generate();
      const sig = await provider.connection.requestAirdrop(
        newAdmin.publicKey,
        1_000_000_000
      );
      await provider.connection.confirmTransaction(sig);

      await servicePlan.methods
        .updateConfig(newAdmin.publicKey, null)
        .accounts({
          config: configPda,
          admin: admin.publicKey,
        })
        .rpc();

      const config = await servicePlan.account.servicePlanConfig.fetch(
        configPda
      );
      expect(config.admin.toBase58()).to.equal(
        newAdmin.publicKey.toBase58()
      );

      // Transfer back
      await servicePlan.methods
        .updateConfig(admin.publicKey, null)
        .accounts({
          config: configPda,
          admin: newAdmin.publicKey,
        })
        .signers([newAdmin])
        .rpc();
    });
  });
});
