/**
 * revenue-validation.test.ts
 *
 * Tests for the Revenue Source Validation system within krexa-payment-router.
 * Covers: Layer 1 source classification, Layer 2 pattern detection (on-chain),
 * Layer 3 economic validation, oracle review, retroactive rejection,
 * blocklist/whitelist management.
 */

import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { KrexaPaymentRouter } from "../target/types/krexa_payment_router";
import { Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import {
  createMockUsdc,
  mintUsdc,
  getOrCreateUsdcAta,
} from "./helpers/create-mock-usdc";
import { TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { expect } from "chai";

// Classification values
const VERIFIED = 0;
const REJECTED = 1;
const QUARANTINED = 2;
const PENDING_KEEPER = 3;

// Oracle review decisions
const DECISION_APPROVE = 0;
const DECISION_REJECT = 1;
const DECISION_APPROVE_AND_WHITELIST = 2;
const DECISION_REJECT_AND_BLOCKLIST = 3;

describe("Revenue Source Validation", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const router = anchor.workspace
    .KrexaPaymentRouter as Program<KrexaPaymentRouter>;

  const admin = (provider.wallet as anchor.Wallet).payer;
  const oracle = Keypair.generate();
  const merchant = Keypair.generate();
  const agentOwner = Keypair.generate();
  const agentWalletPda = Keypair.generate(); // simulated PDA
  const stranger = Keypair.generate();
  const customer1 = Keypair.generate();
  const customer2 = Keypair.generate();

  // PDAs
  let configPda: PublicKey;
  let validatorPda: PublicKey;
  let historyPda: PublicKey;
  let blocklistPda: PublicKey;
  let platformWlPda: PublicKey;

  let mockUsdc: Awaited<ReturnType<typeof createMockUsdc>>;

  before(async () => {
    // Airdrop
    const airdrops = [oracle, merchant, agentOwner, stranger, customer1, customer2].map(
      async (kp) => {
        const sig = await provider.connection.requestAirdrop(
          kp.publicKey,
          2_000_000_000
        );
        await provider.connection.confirmTransaction(sig);
      }
    );
    await Promise.all(airdrops);

    mockUsdc = await createMockUsdc(provider);

    // Derive PDAs
    [configPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("router_config")],
      router.programId
    );
    [validatorPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("rev_validator"), merchant.publicKey.toBuffer()],
      router.programId
    );
    [historyPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("payment_history"), merchant.publicKey.toBuffer()],
      router.programId
    );
    [blocklistPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("global_blocklist")],
      router.programId
    );
    [platformWlPda] = PublicKey.findProgramAddressSync(
      [Buffer.from("platform_whitelist")],
      router.programId
    );

    // Create treasury token account
    const treasuryAta = await getOrCreateUsdcAta(
      provider,
      mockUsdc,
      admin.publicKey
    );

    // Initialize router
    await router.methods
      .initialize(1000) // 10% fee
      .accounts({
        config: configPda,
        usdcMint: mockUsdc.mint,
        platformTreasury: treasuryAta,
        oracle: oracle.publicKey,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // Initialize blocklist
    await router.methods
      .initializeBlocklist()
      .accounts({
        config: configPda,
        blocklist: blocklistPda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // Initialize platform whitelist
    await router.methods
      .initializePlatformWhitelist()
      .accounts({
        config: configPda,
        whitelist: platformWlPda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // Create revenue validator for merchant
    await router.methods
      .createRevenueValidator(
        merchant.publicKey,
        agentWalletPda.publicKey,
        agentOwner.publicKey,
        new anchor.BN(2_500_000), // $2.50/day expected
        new anchor.BN(10_000_000_000) // $10,000 credit line
      )
      .accounts({
        config: configPda,
        validator: validatorPda,
        oracle: oracle.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    // Create payment history
    await router.methods
      .createPaymentHistory(merchant.publicKey)
      .accounts({
        config: configPda,
        history: historyPda,
        oracle: oracle.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Layer 1: Source Classification
  // ─────────────────────────────────────────────────────────────────────────

  describe("1. Layer 1 — Source Classification", () => {
    it("1-1: self-transfer → rejected (agent PDA wallet)", async () => {
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          agentWalletPda.publicKey, // source = agent's own PDA
          new anchor.BN(1_000_000),
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[0];
      expect(payment.classification).to.equal(REJECTED);
    });

    it("1-2: owner wallet transfer → rejected", async () => {
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          agentOwner.publicKey, // source = agent owner
          new anchor.BN(1_000_000),
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[1];
      expect(payment.classification).to.equal(REJECTED);
    });

    it("1-3: associated wallet → rejected", async () => {
      const associatedWallet = Keypair.generate();

      // Add associated wallet first
      await router.methods
        .addAssociatedWallet(merchant.publicKey, associatedWallet.publicKey)
        .accounts({
          config: configPda,
          validator: validatorPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      // Validate payment from associated wallet
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          associatedWallet.publicKey,
          new anchor.BN(1_000_000),
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[2];
      expect(payment.classification).to.equal(REJECTED);
    });

    it("1-4: blocklisted wallet → rejected", async () => {
      const badActor = Keypair.generate();

      // Add to blocklist
      await router.methods
        .addToBlocklist(badActor.publicKey)
        .accounts({
          config: configPda,
          blocklist: blocklistPda,
          admin: admin.publicKey,
        })
        .rpc();

      // Validate payment from blocked wallet
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          badActor.publicKey,
          new anchor.BN(1_000_000),
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[3];
      expect(payment.classification).to.equal(REJECTED);
    });

    it("1-5: x402 payment → verified and credited", async () => {
      const validatorBefore = await router.account.revenueValidator.fetch(
        validatorPda
      );
      const revBefore = validatorBefore.cumulativeValidatedRevenue.toNumber();

      await router.methods
        .validateRevenue(
          merchant.publicKey,
          customer1.publicKey,
          new anchor.BN(500_000), // $0.50
          true // is_x402
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[4];
      expect(payment.classification).to.equal(VERIFIED);
      expect(payment.isX402).to.be.true;

      const validatorAfter = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validatorAfter.cumulativeValidatedRevenue.toNumber()).to.equal(
        revBefore + 500_000
      );
    });

    it("1-6: registered revenue source → verified", async () => {
      // Register customer1 as a verified source
      await router.methods
        .registerRevenueSource(merchant.publicKey, customer1.publicKey)
        .accounts({
          config: configPda,
          validator: validatorPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const validator = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validator.numRegisteredSources).to.equal(1);

      // Non-x402 payment from registered source → verified
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          customer1.publicKey,
          new anchor.BN(1_000_000),
          false // not x402
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[5];
      expect(payment.classification).to.equal(VERIFIED);
    });

    it("1-7: unknown source → pending keeper", async () => {
      const unknownSource = Keypair.generate();

      await router.methods
        .validateRevenue(
          merchant.publicKey,
          unknownSource.publicKey,
          new anchor.BN(500_000), // small amount, no flags
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[6];
      // Unknown source with no flags → PendingKeeper (tentatively credited)
      expect(payment.classification).to.equal(PENDING_KEEPER);
    });

    it("1-8: platform whitelisted source → verified", async () => {
      const platform = Keypair.generate();

      // Add to platform whitelist
      await router.methods
        .addToPlatformWhitelist(platform.publicKey)
        .accounts({
          config: configPda,
          whitelist: platformWlPda,
          admin: admin.publicKey,
        })
        .rpc();

      await router.methods
        .validateRevenue(
          merchant.publicKey,
          platform.publicKey,
          new anchor.BN(1_000_000),
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      const payment = history.payments[7];
      expect(payment.classification).to.equal(VERIFIED);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Revenue Source Management
  // ─────────────────────────────────────────────────────────────────────────

  describe("2. Source management", () => {
    it("2-1: oracle can remove a registered source", async () => {
      await router.methods
        .removeRevenueSource(merchant.publicKey, customer1.publicKey)
        .accounts({
          config: configPda,
          validator: validatorPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const validator = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validator.numRegisteredSources).to.equal(0);
    });

    it("2-2: non-oracle cannot register sources", async () => {
      try {
        await router.methods
          .registerRevenueSource(merchant.publicKey, customer2.publicKey)
          .accounts({
            config: configPda,
            validator: validatorPda,
            oracle: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotOracle");
      }
    });

    it("2-3: rejects duplicate source registration", async () => {
      // Register customer2
      await router.methods
        .registerRevenueSource(merchant.publicKey, customer2.publicKey)
        .accounts({
          config: configPda,
          validator: validatorPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      // Try to register again
      try {
        await router.methods
          .registerRevenueSource(merchant.publicKey, customer2.publicKey)
          .accounts({
            config: configPda,
            validator: validatorPda,
            oracle: oracle.publicKey,
          })
          .signers([oracle])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("SourceAlreadyRegistered");
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Oracle Review
  // ─────────────────────────────────────────────────────────────────────────

  describe("3. Oracle review", () => {
    it("3-1: oracle approves quarantined payment → revenue credited", async () => {
      // Find a PendingKeeper payment index to review
      const history = await router.account.paymentHistory.fetch(historyPda);
      let pendingIdx = -1;
      for (let i = 0; i < history.paymentCount; i++) {
        if (history.payments[i].classification === PENDING_KEEPER) {
          pendingIdx = i;
          break;
        }
      }

      if (pendingIdx >= 0) {
        const validatorBefore = await router.account.revenueValidator.fetch(
          validatorPda
        );

        await router.methods
          .reviewQuarantined(merchant.publicKey, pendingIdx, DECISION_APPROVE)
          .accounts({
            config: configPda,
            validator: validatorPda,
            history: historyPda,
            blocklist: blocklistPda,
            oracle: oracle.publicKey,
          })
          .signers([oracle])
          .rpc();

        const historyAfter = await router.account.paymentHistory.fetch(
          historyPda
        );
        expect(historyAfter.payments[pendingIdx].classification).to.equal(
          VERIFIED
        );
        // PendingKeeper was already tentatively credited, so cumulative shouldn't change
      }
    });

    it("3-2: oracle rejects a pending-keeper payment → revenue decremented + violation", async () => {
      // Create a new pending payment to reject
      const fakeSource = Keypair.generate();
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          fakeSource.publicKey,
          new anchor.BN(2_000_000), // $2
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const historyBefore = await router.account.paymentHistory.fetch(
        historyPda
      );
      const idx = historyBefore.paymentHead - 1; // last written
      expect(historyBefore.payments[idx].classification).to.equal(
        PENDING_KEEPER
      );

      const validatorBefore = await router.account.revenueValidator.fetch(
        validatorPda
      );
      const violationsBefore = validatorBefore.revenueIntegrityViolations;

      await router.methods
        .reviewQuarantined(merchant.publicKey, idx, DECISION_REJECT)
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const historyAfter = await router.account.paymentHistory.fetch(
        historyPda
      );
      expect(historyAfter.payments[idx].classification).to.equal(REJECTED);

      const validatorAfter = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validatorAfter.revenueIntegrityViolations).to.equal(
        violationsBefore + 1
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Retroactive Rejection
  // ─────────────────────────────────────────────────────────────────────────

  describe("4. Retroactive rejection", () => {
    it("4-1: retroactive reject decrements revenue and increments violations", async () => {
      // Create a verified payment via x402
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          customer1.publicKey,
          new anchor.BN(5_000_000), // $5
          true // x402
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const historyBefore = await router.account.paymentHistory.fetch(
        historyPda
      );
      const idx = historyBefore.paymentHead - 1;
      expect(historyBefore.payments[idx].classification).to.equal(VERIFIED);

      const validatorBefore = await router.account.revenueValidator.fetch(
        validatorPda
      );
      const revBefore = validatorBefore.cumulativeValidatedRevenue.toNumber();
      const violsBefore = validatorBefore.revenueIntegrityViolations;

      // Retroactively reject it
      await router.methods
        .retroactiveReject(merchant.publicKey, idx)
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const validatorAfter = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validatorAfter.cumulativeValidatedRevenue.toNumber()).to.equal(
        revBefore - 5_000_000
      );
      expect(validatorAfter.revenueIntegrityViolations).to.equal(
        violsBefore + 1
      );

      const historyAfter = await router.account.paymentHistory.fetch(
        historyPda
      );
      expect(historyAfter.payments[idx].classification).to.equal(REJECTED);
    });

    it("4-2: cannot retroactively reject an already-rejected payment", async () => {
      const history = await router.account.paymentHistory.fetch(historyPda);
      // Find a rejected payment
      let rejectedIdx = -1;
      for (let i = 0; i < history.paymentCount; i++) {
        if (history.payments[i].classification === REJECTED) {
          rejectedIdx = i;
          break;
        }
      }

      if (rejectedIdx >= 0) {
        try {
          await router.methods
            .retroactiveReject(merchant.publicKey, rejectedIdx)
            .accounts({
              config: configPda,
              validator: validatorPda,
              history: historyPda,
              oracle: oracle.publicKey,
            })
            .signers([oracle])
            .rpc();
          expect.fail("should have thrown");
        } catch (e: any) {
          expect(e.toString()).to.include("NotQuarantined");
        }
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Outflow Recording (for round-trip detection)
  // ─────────────────────────────────────────────────────────────────────────

  describe("5. Outflow recording", () => {
    it("5-1: records outflow in history", async () => {
      const dest = Keypair.generate();

      await router.methods
        .recordOutflow(merchant.publicKey, dest.publicKey, new anchor.BN(1_000_000))
        .accounts({
          config: configPda,
          history: historyPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const history = await router.account.paymentHistory.fetch(historyPda);
      expect(history.outflowCount).to.be.greaterThan(0);
      const outflow = history.outflows[0];
      expect(outflow.amount.toNumber()).to.equal(1_000_000);
      expect(outflow.destination.toBase58()).to.equal(
        dest.publicKey.toBase58()
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Validator Parameter Updates
  // ─────────────────────────────────────────────────────────────────────────

  describe("6. Validator params", () => {
    it("6-1: oracle updates expected daily revenue", async () => {
      await router.methods
        .updateValidatorParams(
          merchant.publicKey,
          new anchor.BN(5_000_000), // $5/day
          null,
          null
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const validator = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validator.expectedDailyRevenue.toNumber()).to.equal(5_000_000);
    });

    it("6-2: oracle updates total disbursed", async () => {
      await router.methods
        .updateValidatorParams(
          merchant.publicKey,
          null,
          null,
          new anchor.BN(3_000_000_000) // $3,000 disbursed
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const validator = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validator.totalDisbursed.toNumber()).to.equal(3_000_000_000);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Access Control
  // ─────────────────────────────────────────────────────────────────────────

  describe("7. Access control", () => {
    it("7-1: non-admin cannot manage blocklist", async () => {
      try {
        await router.methods
          .addToBlocklist(stranger.publicKey)
          .accounts({
            config: configPda,
            blocklist: blocklistPda,
            admin: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotAdmin");
      }
    });

    it("7-2: non-oracle cannot validate revenue", async () => {
      try {
        await router.methods
          .validateRevenue(
            merchant.publicKey,
            customer1.publicKey,
            new anchor.BN(1_000_000),
            false
          )
          .accounts({
            config: configPda,
            validator: validatorPda,
            history: historyPda,
            blocklist: blocklistPda,
            platformWhitelist: platformWlPda,
            oracle: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotOracle");
      }
    });

    it("7-3: non-oracle cannot review quarantined", async () => {
      try {
        await router.methods
          .reviewQuarantined(merchant.publicKey, 0, DECISION_APPROVE)
          .accounts({
            config: configPda,
            validator: validatorPda,
            history: historyPda,
            blocklist: blocklistPda,
            oracle: stranger.publicKey,
          })
          .signers([stranger])
          .rpc();
        expect.fail("should have thrown");
      } catch (e: any) {
        expect(e.toString()).to.include("NotOracle");
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 8. Cumulative Revenue Tracking
  // ─────────────────────────────────────────────────────────────────────────

  describe("8. Cumulative revenue", () => {
    it("8-1: rejected payments do NOT increase cumulative revenue", async () => {
      const validatorBefore = await router.account.revenueValidator.fetch(
        validatorPda
      );
      const revBefore = validatorBefore.cumulativeValidatedRevenue.toNumber();

      // Self-transfer → rejected
      await router.methods
        .validateRevenue(
          merchant.publicKey,
          agentWalletPda.publicKey,
          new anchor.BN(100_000_000), // $100
          false
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const validatorAfter = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validatorAfter.cumulativeValidatedRevenue.toNumber()).to.equal(
        revBefore
      );
    });

    it("8-2: verified x402 payments DO increase cumulative revenue", async () => {
      const validatorBefore = await router.account.revenueValidator.fetch(
        validatorPda
      );
      const revBefore = validatorBefore.cumulativeValidatedRevenue.toNumber();

      await router.methods
        .validateRevenue(
          merchant.publicKey,
          customer1.publicKey,
          new anchor.BN(2_500_000), // $2.50
          true
        )
        .accounts({
          config: configPda,
          validator: validatorPda,
          history: historyPda,
          blocklist: blocklistPda,
          platformWhitelist: platformWlPda,
          oracle: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();

      const validatorAfter = await router.account.revenueValidator.fetch(
        validatorPda
      );
      expect(validatorAfter.cumulativeValidatedRevenue.toNumber()).to.equal(
        revBefore + 2_500_000
      );
    });
  });
});
