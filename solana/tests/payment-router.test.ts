/**
 * payment-router.test.ts — 10 integration tests for krexa-payment-router
 *
 * Tests the revenue-routing model where earning agents automatically repay
 * outstanding credit from incoming x402 payments.
 *
 * Setup topology
 * ──────────────
 *  admin   = provider.wallet (router admin + vault admin)
 *  oracle  = dedicated keypair (signs every execute_payment + activate_settlement)
 *            also holds "buyer" USDC — simulates oracle holding escrow funds.
 *  treasury = admin's USDC ATA (receives platform fee)
 *  merchant1 — settlement with split_bps = 0 (no credit, full pass-through)
 *  merchant2 — settlement with split_bps = 2000 (20% of remainder to vault)
 *
 * Math reference (platform_fee_bps = 250 = 2.5 %)
 * ─────────────────────────────────────────────────
 *   $100 payment, no credit:
 *     platform_fee   =  $2.50
 *     merchant_rcvd  = $97.50
 *
 *   $100 payment, split_bps = 2000:
 *     platform_fee   =  $2.50
 *     remainder      = $97.50
 *     repayment      = $97.50 × 20 % = $19.50
 *     merchant_rcvd  = $97.50 − $19.50 = $78.00
 *
 * NOTE: vault must be initialised with wallet_program = routerConfigPda so
 * that the router config PDA can sign receive_repayment as wallet_program_authority.
 */

import * as anchor from "@coral-xyz/anchor";
import { Program, BN } from "@coral-xyz/anchor";
import { KrexaPaymentRouter } from "../target/types/krexa_payment_router";
import { KrexaCreditVault } from "../target/types/krexa_credit_vault";
import routerIdl from "../target/idl/krexa_payment_router.json";
import vaultIdl from "../target/idl/krexa_credit_vault.json";
import {
  Keypair,
  PublicKey,
  SystemProgram,
  SYSVAR_RENT_PUBKEY,
} from "@solana/web3.js";
import {
  TOKEN_PROGRAM_ID,
  getAccount,
  getOrCreateAssociatedTokenAccount,
} from "@solana/spl-token";
import { expect } from "chai";
import {
  createMockUsdc,
  mintUsdc,
  MockUsdc,
} from "./helpers/create-mock-usdc";

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const USDC_ONE = 1_000_000; // 1 USDC base unit
const PLATFORM_FEE_BPS = 250; // 2.5 %
const SPLIT_BPS_MERCHANT2 = 2000; // 20 % to vault
const ROUTER_PROGRAM_ID = new PublicKey(
  "2Zy3d7C28Z9dfazdysKVBQUXnvvWNshxtDEFKftG83u8"
);
const VAULT_PROGRAM_ID = new PublicKey(
  "26SQx3rAyujWCupxvPAMf9N3ok4cw1awyTWAVWDQfr9N"
);

// ─────────────────────────────────────────────────────────────────────────────
// PDA helpers
// ─────────────────────────────────────────────────────────────────────────────

function deriveRouterConfig(routerProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("router_config")],
    routerProgramId
  )[0];
}

function deriveSettlement(
  merchant: PublicKey,
  routerProgramId: PublicKey
): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("settlement"), merchant.toBuffer()],
    routerProgramId
  )[0];
}

function deriveVaultConfig(vaultProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("vault_config")],
    vaultProgramId
  )[0];
}

function deriveVaultToken(vaultProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("vault_usdc")],
    vaultProgramId
  )[0];
}

function deriveInsuranceToken(vaultProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("insurance_usdc")],
    vaultProgramId
  )[0];
}

function deriveCreditLine(
  agent: PublicKey,
  vaultProgramId: PublicKey
): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("credit_line"), agent.toBuffer()],
    vaultProgramId
  )[0];
}

function deriveLpDeposit(
  depositor: PublicKey,
  vaultProgramId: PublicKey
): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("deposit"), depositor.toBuffer()],
    vaultProgramId
  )[0];
}

// ─────────────────────────────────────────────────────────────────────────────
// Test suite
// ─────────────────────────────────────────────────────────────────────────────

describe("krexa-payment-router", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const router = new Program<KrexaPaymentRouter>(
    { ...routerIdl, address: ROUTER_PROGRAM_ID.toBase58() } as KrexaPaymentRouter,
    provider
  );
  const vault = new Program<KrexaCreditVault>(
    { ...vaultIdl, address: VAULT_PROGRAM_ID.toBase58() } as KrexaCreditVault,
    provider
  );

  const conn = provider.connection;
  const admin = provider.wallet as anchor.Wallet;

  // Actors
  let oracle: Keypair;
  let merchant1: Keypair; // no credit, split_bps = 0
  let merchant2: Keypair; // has credit, split_bps = 2000
  let stranger: Keypair;

  // Mock USDC
  let mock: MockUsdc;

  // Token accounts
  let oracleUsdc: PublicKey;       // oracle holds "buyer" escrow funds
  let merchant1Usdc: PublicKey;
  let merchant2Usdc: PublicKey;
  let treasuryUsdc: PublicKey;     // admin's ATA — receives platform fee

  // LP deposit account (for vault liquidity)
  let lpUsdc: PublicKey;

  // PDAs
  let routerConfigPda: PublicKey;
  let settlement1Pda: PublicKey;
  let settlement2Pda: PublicKey;
  let vaultConfigPda: PublicKey;
  let vaultTokenPda: PublicKey;
  let insuranceTokenPda: PublicKey;
  let creditLine2Pda: PublicKey;  // credit line for merchant2
  let lpDepositPda: PublicKey;

  // ── before: bootstrap all programs ────────────────────────────────────────

  before(async () => {
    oracle = Keypair.generate();
    merchant1 = Keypair.generate();
    merchant2 = Keypair.generate();
    stranger = Keypair.generate();

    // Fund oracle for PDA rent where oracle is the account payer (e.g. extend_credit,
    // activate_settlement). This avoids local/devnet faucet dependence.
    const minOracleLamports = 30_000_000; // 0.03 SOL
    const oracleLamports = await conn.getBalance(oracle.publicKey);
    if (oracleLamports < minOracleLamports) {
      const topUpLamports = minOracleLamports - oracleLamports + 5_000_000;
      const tx = new anchor.web3.Transaction().add(
        SystemProgram.transfer({
          fromPubkey: admin.publicKey,
          toPubkey: oracle.publicKey,
          lamports: topUpLamports,
        })
      );
      await provider.sendAndConfirm(tx, []);
    }

    // Create mock USDC
    mock = await createMockUsdc(provider);

    // Derive PDAs
    routerConfigPda = deriveRouterConfig(router.programId);
    settlement1Pda = deriveSettlement(merchant1.publicKey, router.programId);
    settlement2Pda = deriveSettlement(merchant2.publicKey, router.programId);
    vaultConfigPda = deriveVaultConfig(vault.programId);
    vaultTokenPda = deriveVaultToken(vault.programId);
    insuranceTokenPda = deriveInsuranceToken(vault.programId);
    creditLine2Pda = deriveCreditLine(merchant2.publicKey, vault.programId);
    lpDepositPda = deriveLpDeposit(admin.publicKey, vault.programId);

    // Create token accounts
    oracleUsdc = await mintUsdc(provider, mock, oracle.publicKey, 50_000);
    merchant1Usdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      merchant1.publicKey
    ).then((a) => a.address);
    merchant2Usdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      merchant2.publicKey
    ).then((a) => a.address);
    treasuryUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      admin.publicKey
    ).then((a) => a.address);
    lpUsdc = await mintUsdc(provider, mock, admin.publicKey, 100_000);

    // ── Initialize vault (wallet_program = routerConfigPda) ────────────────
    await vault.methods
      .initializeVault(
        oracle.publicKey,       // oracle
        routerConfigPda,        // wallet_program = router config PDA
        8_500,                  // utilization_cap_bps = 85%
        500,                    // base_interest_rate_bps = 5%
        new BN(0),              // lockup_seconds = 0
        treasuryUsdc            // treasury_account
      )
      .accounts({
        config: vaultConfigPda,
        usdcMint: mock.mint,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId
      })
      .rpc();

    await vault.methods
      .createVaultToken()
      .accounts({
        config: vaultConfigPda,
        usdcMint: mock.mint,
        vaultToken: vaultTokenPda,
        admin: admin.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .rpc();

    await vault.methods
      .createInsuranceToken()
      .accounts({
        config: vaultConfigPda,
        usdcMint: mock.mint,
        insuranceToken: insuranceTokenPda,
        admin: admin.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .rpc();

    await vault.methods
      .updateConfig(
        null,                       // new_admin
        null,                       // new_oracle
        null,                       // new_wallet_program
        router.programId,           // new_router_program
        null,                       // new_utilization_cap_bps
        null,                       // new_base_interest_rate_bps
        null,                       // new_lockup_seconds
        null                        // new_service_plan_program
      )
      .accounts({
        config: vaultConfigPda,
        admin: admin.publicKey,
      })
      .rpc();

    // ── LP deposits $50k into vault for liquidity ──────────────────────────
    await vault.methods
      .depositLiquidity(new BN(50_000 * USDC_ONE), 0)
      .accounts({
        config: vaultConfigPda,
        vaultToken: vaultTokenPda,
        depositPosition: lpDepositPda,
        depositorUsdc: lpUsdc,
        depositor: admin.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // ── Initialize router ──────────────────────────────────────────────────
    await router.methods
      .initialize(PLATFORM_FEE_BPS)
      .accounts({
        config: routerConfigPda,
        usdcMint: mock.mint,
        platformTreasury: treasuryUsdc,
        oracle: oracle.publicKey,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // ── Create credit line for merchant2 in the vault ──────────────────────
    // Level 1 credit: $500 limit. We draw $100 for the test.
    await vault.methods
      .extendCredit(
        merchant2.publicKey,    // agent
        new BN(100 * USDC_ONE), // amount $100
        500,                    // rate_bps = 5%
        1,                      // credit_level = 1
        new BN(0)               // collateral_value (level 1 uses flat cap)
      )
      .accounts({
        config: vaultConfigPda,
        vaultToken: vaultTokenPda,
        creditLine: creditLine2Pda,
        agentWalletUsdc: merchant2Usdc, // funds land in merchant2's USDC ATA
        oracle: oracle.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();
  });

  // ── Test 1: RouterConfig initialised correctly ─────────────────────────────

  it("initializes router with correct config", async () => {
    const cfg = await router.account.routerConfig.fetch(routerConfigPda);
    expect(cfg.admin.toBase58()).to.equal(admin.publicKey.toBase58());
    expect(cfg.oracle.toBase58()).to.equal(oracle.publicKey.toBase58());
    expect(cfg.platformTreasury.toBase58()).to.equal(treasuryUsdc.toBase58());
    expect(cfg.platformFeeBps).to.equal(PLATFORM_FEE_BPS);
    expect(cfg.isPaused).to.be.false;
  });

  // ── Test 2: activate_settlement — no credit (split_bps = 0) ───────────────

  it("oracle activates settlement for merchant1 with no credit split", async () => {
    await router.methods
      .activateSettlement(
        merchant1.publicKey,
        0,                      // split_bps = 0
        PublicKey.default       // no agent wallet
      )
      .accounts({
        config: routerConfigPda,
        settlement: settlement1Pda,
        oracle: oracle.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const s = await router.account.merchantSettlement.fetch(settlement1Pda);
    expect(s.merchant.toBase58()).to.equal(merchant1.publicKey.toBase58());
    expect(s.splitBps).to.equal(0);
    expect(s.hasActiveCredit).to.be.false;
    expect(s.isActive).to.be.true;
    expect(s.nonce.toNumber()).to.equal(0);
  });

  // ── Test 3: activate_settlement — with credit split ───────────────────────

  it("oracle activates settlement for merchant2 with 20% repayment split", async () => {
    // Use a dummy agent wallet PDA (the credit_line PDA itself) to signal
    // has_active_credit = true without needing a full wallet setup.
    await router.methods
      .activateSettlement(
        merchant2.publicKey,
        SPLIT_BPS_MERCHANT2,    // 20 %
        creditLine2Pda          // any non-default pubkey → has_active_credit = true
      )
      .accounts({
        config: routerConfigPda,
        settlement: settlement2Pda,
        oracle: oracle.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const s = await router.account.merchantSettlement.fetch(settlement2Pda);
    expect(s.splitBps).to.equal(SPLIT_BPS_MERCHANT2);
    expect(s.hasActiveCredit).to.be.true;
  });

  // ── Test 4: stranger cannot activate_settlement ────────────────────────────

  it("stranger cannot activate_settlement (not oracle)", async () => {
    const fakeMerchant = Keypair.generate();
    const fakePda = deriveSettlement(fakeMerchant.publicKey, router.programId);

    try {
      await router.methods
        .activateSettlement(fakeMerchant.publicKey, 0, PublicKey.default)
        .accounts({
          config: routerConfigPda,
          settlement: fakePda,
          oracle: stranger.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown");
    } catch (err: any) {
      const msg =
        typeof err?.toString === "function" ? err.toString() : String(err);
      const logs = Array.isArray(err?.logs)
        ? err.logs.join("\n")
        : typeof err?.getLogs === "function"
        ? (await err.getLogs()).join("\n")
        : "";
      const anchorCode = err?.error?.errorCode?.code;
      const combined = `${msg}\n${logs}`;
      expect(
        anchorCode === "NotOracle" ||
          /NotOracle|ConstraintHasOne|has one constraint was violated|custom program error|Simulation failed/i.test(
            combined
          )
      ).to.equal(true);
    }
  });

  // ── Test 5: execute_payment — no credit, full pass-through ────────────────
  //
  //   $100 in:  platform_fee = $2.50 → treasury
  //             merchant_rcvd = $97.50

  it("routes $100 payment to merchant1 with 2.5% platform fee only", async () => {
    const paymentAmount = 100 * USDC_ONE;

    const treasuryBefore = await getAccount(conn, treasuryUsdc);
    const merchant1Before = await getAccount(conn, merchant1Usdc);
    const oracleBefore = await getAccount(conn, oracleUsdc);

    await router.methods
      .executePayment(
        merchant1.publicKey,
        new BN(paymentAmount),
        new BN(1) // nonce = 1
      )
      .accounts({
        config: routerConfigPda,
        settlement: settlement1Pda,
        payerUsdc: oracleUsdc,
        merchantUsdc: merchant1Usdc,
        platformTreasuryToken: treasuryUsdc,
        vaultConfig: vaultConfigPda,
        vaultToken: vaultTokenPda,
        insuranceToken: insuranceTokenPda,
        creditLine: creditLine2Pda, // dummy — repayment = 0
        oracle: oracle.publicKey,
        vaultProgram: vault.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const treasuryAfter = await getAccount(conn, treasuryUsdc);
    const merchant1After = await getAccount(conn, merchant1Usdc);
    const oracleAfter = await getAccount(conn, oracleUsdc);

    const expectedFee = Math.floor(paymentAmount * PLATFORM_FEE_BPS / 10_000);
    const expectedNet = paymentAmount - expectedFee;

    expect(Number(treasuryAfter.amount - treasuryBefore.amount)).to.equal(
      expectedFee,
      "treasury receives platform fee"
    );
    expect(Number(merchant1After.amount - merchant1Before.amount)).to.equal(
      expectedNet,
      "merchant1 receives net amount"
    );
    expect(Number(oracleBefore.amount - oracleAfter.amount)).to.equal(
      paymentAmount,
      "oracle (payer) sends full amount"
    );

    // State updated
    const s = await router.account.merchantSettlement.fetch(settlement1Pda);
    expect(s.nonce.toNumber()).to.equal(1);
    expect(s.totalRouted.toNumber()).to.equal(paymentAmount);
    expect(s.totalMerchantReceived.toNumber()).to.equal(expectedNet);
  });

  // ── Test 6: replay attack fails (same nonce) ───────────────────────────────

  it("execute_payment fails with same nonce (replay protection)", async () => {
    try {
      await router.methods
        .executePayment(
          merchant1.publicKey,
          new BN(100 * USDC_ONE),
          new BN(1) // same nonce as test 5
        )
        .accounts({
          config: routerConfigPda,
          settlement: settlement1Pda,
          payerUsdc: oracleUsdc,
          merchantUsdc: merchant1Usdc,
          platformTreasuryToken: treasuryUsdc,
          vaultConfig: vaultConfigPda,
          vaultToken: vaultTokenPda,
          insuranceToken: insuranceTokenPda,
          creditLine: creditLine2Pda,
          oracle: oracle.publicKey,
          vaultProgram: vault.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([oracle])
        .rpc();
      expect.fail("should have thrown");
    } catch (err: any) {
      expect(err.toString()).to.include("InvalidNonce");
    }
  });

  // ── Test 7: execute_payment — with credit split, CPI to vault ─────────────
  //
  //   $100 in:  platform_fee  = $2.50
  //             remainder     = $97.50
  //             repayment     = $97.50 × 20% = $19.50
  //             merchant_rcvd = $97.50 − $19.50 = $78.00

  it("routes $100 payment with 20% credit split: fee + repayment + net", async () => {
    const paymentAmount = 100 * USDC_ONE;

    const vaultBefore = await getAccount(conn, vaultTokenPda);
    const merchant2Before = await getAccount(conn, merchant2Usdc);
    const treasuryBefore = await getAccount(conn, treasuryUsdc);
    const oracleBefore = await getAccount(conn, oracleUsdc);

    await router.methods
      .executePayment(
        merchant2.publicKey,
        new BN(paymentAmount),
        new BN(1) // nonce = 1 (merchant2's first payment)
      )
      .accounts({
        config: routerConfigPda,
        settlement: settlement2Pda,
        payerUsdc: oracleUsdc,
        merchantUsdc: merchant2Usdc,
        platformTreasuryToken: treasuryUsdc,
        vaultConfig: vaultConfigPda,
        vaultToken: vaultTokenPda,
        insuranceToken: insuranceTokenPda,
        creditLine: creditLine2Pda,
        oracle: oracle.publicKey,
        vaultProgram: vault.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const platformFee = Math.floor(paymentAmount * PLATFORM_FEE_BPS / 10_000);
    const remainder = paymentAmount - platformFee;
    const repayment = Math.floor(remainder * SPLIT_BPS_MERCHANT2 / 10_000);
    const merchantNet = remainder - repayment;

    const vaultAfter = await getAccount(conn, vaultTokenPda);
    const merchant2After = await getAccount(conn, merchant2Usdc);
    const treasuryAfter = await getAccount(conn, treasuryUsdc);
    const oracleAfter = await getAccount(conn, oracleUsdc);

    expect(Number(treasuryAfter.amount - treasuryBefore.amount)).to.equal(
      platformFee,
      "treasury receives platform fee"
    );
    expect(Number(vaultAfter.amount - vaultBefore.amount)).to.equal(
      repayment,
      "vault receives repayment portion"
    );
    expect(Number(merchant2After.amount - merchant2Before.amount)).to.equal(
      merchantNet,
      "merchant2 receives net after fee+repayment"
    );
    expect(Number(oracleBefore.amount - oracleAfter.amount)).to.equal(
      paymentAmount,
      "oracle (payer) sends full amount"
    );

    // State totals
    const s = await router.account.merchantSettlement.fetch(settlement2Pda);
    expect(s.totalRepaid.toNumber()).to.equal(repayment);
    expect(s.totalMerchantReceived.toNumber()).to.equal(merchantNet);
    expect(s.nonce.toNumber()).to.equal(1);
  });

  // ── Test 8: update_split — oracle adjusts repayment split ─────────────────

  it("oracle updates merchant2 split from 2000 → 1000 bps", async () => {
    const newSplit = 1000;

    await router.methods
      .updateSplit(merchant2.publicKey, newSplit)
      .accounts({
        config: routerConfigPda,
        settlement: settlement2Pda,
        oracle: oracle.publicKey,
      })
      .signers([oracle])
      .rpc();

    const s = await router.account.merchantSettlement.fetch(settlement2Pda);
    expect(s.splitBps).to.equal(newSplit);
    // has_active_credit stays true since split > 0 and agent_wallet_pda != default
    expect(s.hasActiveCredit).to.be.true;
  });

  // ── Test 9: set_paused — router paused, payment fails ─────────────────────

  it("paused router rejects execute_payment", async () => {
    await router.methods
      .setPaused(true)
      .accounts({
        config: routerConfigPda,
        admin: admin.publicKey,
      })
      .rpc();

    try {
      await router.methods
        .executePayment(
          merchant1.publicKey,
          new BN(50 * USDC_ONE),
          new BN(99)
        )
        .accounts({
          config: routerConfigPda,
          settlement: settlement1Pda,
          payerUsdc: oracleUsdc,
          merchantUsdc: merchant1Usdc,
          platformTreasuryToken: treasuryUsdc,
          vaultConfig: vaultConfigPda,
          vaultToken: vaultTokenPda,
          insuranceToken: insuranceTokenPda,
          creditLine: creditLine2Pda,
          oracle: oracle.publicKey,
          vaultProgram: vault.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([oracle])
        .rpc();
      expect.fail("should have thrown");
    } catch (err: any) {
      expect(err.toString()).to.include("Paused");
    }

    // Unpause for subsequent tests
    await router.methods
      .setPaused(false)
      .accounts({ config: routerConfigPda, admin: admin.publicKey })
      .rpc();
  });

  // ── Test 10: deactivate_settlement — payment fails after deactivation ──────

  it("admin deactivates merchant1 settlement; payment fails with SettlementInactive", async () => {
    await router.methods
      .deactivateSettlement(merchant1.publicKey)
      .accounts({
        config: routerConfigPda,
        settlement: settlement1Pda,
        admin: admin.publicKey,
      })
      .rpc();

    const s = await router.account.merchantSettlement.fetch(settlement1Pda);
    expect(s.isActive).to.be.false;

    // Payment should now fail
    try {
      await router.methods
        .executePayment(
          merchant1.publicKey,
          new BN(50 * USDC_ONE),
          new BN(100)
        )
        .accounts({
          config: routerConfigPda,
          settlement: settlement1Pda,
          payerUsdc: oracleUsdc,
          merchantUsdc: merchant1Usdc,
          platformTreasuryToken: treasuryUsdc,
          vaultConfig: vaultConfigPda,
          vaultToken: vaultTokenPda,
          insuranceToken: insuranceTokenPda,
          creditLine: creditLine2Pda,
          oracle: oracle.publicKey,
          vaultProgram: vault.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([oracle])
        .rpc();
      expect.fail("should have thrown");
    } catch (err: any) {
      expect(err.toString()).to.include("SettlementInactive");
    }
  });
});
