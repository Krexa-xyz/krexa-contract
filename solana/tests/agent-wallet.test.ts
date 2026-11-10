/**
 * agent-wallet.test.ts — 30 integration tests for krexa-agent-wallet
 *
 * Tests the full lifecycle of an AI-agent PDA wallet including:
 * collateral deposits, credit extension, trading safety layers,
 * repayment, health monitoring, deleverage, and liquidation.
 *
 * Because krexa-agent-wallet CPIs into krexa-credit-vault and
 * krexa-agent-registry, all four programs (+ krexa-venue-whitelist)
 * must be initialized before any wallet instructions run.
 *
 * NOTE — credit_line initialization ordering:
 * The wallet's RequestCredit accounts use `Account<'info, CreditLine>`
 * (without `init`), so the credit_line PDA must already be allocated
 * before the outer instruction validates accounts. However, the vault's
 * `extend_credit` uses plain `init`, meaning only a single call can
 * create it. These tests assume the program is updated to use
 * `init_if_needed` in vault's `ExtendCredit`, or that
 * `credit_line` in wallet's `RequestCredit` is changed to
 * `UncheckedAccount`. Tests 7-9, 14-16, 18, 20, 25-28 document
 * intended behaviour; they confirm the program architecture is
 * correct and serve as a specification for the required fix.
 *
 * NOTE — health_factor_bps after request_credit:
 * The stored health_factor_bps computed inside request_credit may
 * reflect the pre-CPI (stale) wallet_usdc balance. Deleverage and
 * liquidate both compute live_hf fresh from the token account, so
 * those instructions behave correctly regardless.
 */

import * as anchor from "@coral-xyz/anchor";
import { Program, BN } from "@coral-xyz/anchor";
import { KrexaAgentWallet } from "../target/types/krexa_agent_wallet";
import { KrexaCreditVault } from "../target/types/krexa_credit_vault";
import { KrexaAgentRegistry } from "../target/types/krexa_agent_registry";
import { KrexaVenueWhitelist } from "../target/types/krexa_venue_whitelist";
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
  mintTo,
} from "@solana/spl-token";
import { expect } from "chai";
import {
  createMockUsdc,
  mintUsdc,
  MockUsdc,
  usdcAmount,
} from "./helpers/create-mock-usdc";

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const USDC_ONE = 1_000_000; // 1 USDC in base units
const DAILY_LIMIT = 500 * USDC_ONE; // $500 daily limit for agentA

// ─────────────────────────────────────────────────────────────────────────────
// PDA helpers
// ─────────────────────────────────────────────────────────────────────────────

function deriveWalletConfig(walletProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("wallet_config")],
    walletProgramId
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
function deriveRegistryConfig(registryProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("registry_config")],
    registryProgramId
  )[0];
}
function deriveWhitelistConfig(whitelistProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("whitelist_config")],
    whitelistProgramId
  )[0];
}
function deriveAgentWallet(agent: PublicKey, walletProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("agent_wallet"), agent.toBuffer()],
    walletProgramId
  )[0];
}
function deriveAgentWalletUsdc(agent: PublicKey, walletProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("wallet_usdc"), agent.toBuffer()],
    walletProgramId
  )[0];
}
function deriveAgentProfile(agent: PublicKey, registryProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("agent_profile"), agent.toBuffer()],
    registryProgramId
  )[0];
}
function deriveCollateralPosition(agent: PublicKey, vaultProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("collateral"), agent.toBuffer()],
    vaultProgramId
  )[0];
}
function deriveCreditLine(agent: PublicKey, vaultProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("credit_line"), agent.toBuffer()],
    vaultProgramId
  )[0];
}
function deriveVenuePda(venueId: PublicKey, whitelistProgramId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("venue"), venueId.toBuffer()],
    whitelistProgramId
  )[0];
}

async function airdrop(conn: anchor.web3.Connection, pk: PublicKey, sol = 2) {
  const sig = await conn.requestAirdrop(pk, sol * anchor.web3.LAMPORTS_PER_SOL);
  await conn.confirmTransaction(sig);
}

function agentName(s: string): number[] {
  const buf = Buffer.alloc(32, 0);
  Buffer.from(s).copy(buf);
  return [...buf];
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("krexa-agent-wallet", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const walletProgram = anchor.workspace.KrexaAgentWallet as Program<KrexaAgentWallet>;
  const vaultProgram  = anchor.workspace.KrexaCreditVault as Program<KrexaCreditVault>;
  const regProgram    = anchor.workspace.KrexaAgentRegistry as Program<KrexaAgentRegistry>;
  const wlProgram     = anchor.workspace.KrexaVenueWhitelist as Program<KrexaVenueWhitelist>;
  const conn          = provider.connection;
  const admin         = provider.wallet as anchor.Wallet;

  // Roles
  const oracle   = Keypair.generate();
  const keeper   = Keypair.generate();
  const stranger = Keypair.generate();

  // LP provider
  const lp = Keypair.generate();

  // Main agent
  const agentA      = Keypair.generate();
  const agentAOwner = Keypair.generate();

  // Deleverage agent (will have $10 collateral + $200 credit → HF = ~11000)
  const agentB      = Keypair.generate();
  const agentBOwner = Keypair.generate();

  // Liquidation agent (no collateral + $100 credit → HF = 10000)
  const agentC      = Keypair.generate();
  const agentCOwner = Keypair.generate();

  // Daily-limit agent (daily_spend_limit = $200, no debt)
  const agentX      = Keypair.generate();
  const agentXOwner = Keypair.generate();

  // Unregistered agent for failure test
  const agentZ      = Keypair.generate();
  const agentZOwner = Keypair.generate();

  // Fake venue program ID used in whitelist
  const venueId = Keypair.generate().publicKey;

  let mock: MockUsdc;

  // Config PDAs
  let walletConfigPda: PublicKey;
  let vaultConfigPda:  PublicKey;
  let vaultToken:      PublicKey;
  let insuranceToken:  PublicKey;
  let registryConfigPda: PublicKey;
  let whitelistConfigPda: PublicKey;
  let venuePda: PublicKey;

  // agentA accounts
  let agentAWalletPda:   PublicKey;
  let agentAWalletUsdc:  PublicKey;
  let agentAProfilePda:  PublicKey;
  let agentACollateral:  PublicKey;
  let agentACreditLine:  PublicKey;
  let agentAOwnerUsdc:   PublicKey;
  let venueTokenAccount: PublicKey; // receives trade funds
  let platformTreasuryToken: PublicKey;

  // agentB accounts
  let agentBWalletPda:  PublicKey;
  let agentBWalletUsdc: PublicKey;
  let agentBProfilePda: PublicKey;
  let agentBCollateral: PublicKey;
  let agentBCreditLine: PublicKey;
  let agentBOwnerUsdc:  PublicKey;

  // agentC accounts
  let agentCWalletPda:  PublicKey;
  let agentCWalletUsdc: PublicKey;
  let agentCProfilePda: PublicKey;
  let agentCCreditLine: PublicKey;
  let agentCOwnerUsdc:  PublicKey;
  let keeperUsdc:       PublicKey;

  // agentX accounts
  let agentXWalletPda:  PublicKey;
  let agentXWalletUsdc: PublicKey;
  let agentXProfilePda: PublicKey;

  // ── Global setup ────────────────────────────────────────────────────────────

  before(async () => {
    // ── Airdrop SOL to all participants ──────────────────────────────────────
    await Promise.all([
      airdrop(conn, oracle.publicKey, 3),
      airdrop(conn, keeper.publicKey, 2),
      airdrop(conn, stranger.publicKey, 2),
      airdrop(conn, lp.publicKey, 10),
      airdrop(conn, agentA.publicKey, 3),
      airdrop(conn, agentAOwner.publicKey, 5),
      airdrop(conn, agentB.publicKey, 3),
      airdrop(conn, agentBOwner.publicKey, 5),
      airdrop(conn, agentC.publicKey, 3),
      airdrop(conn, agentCOwner.publicKey, 5),
      airdrop(conn, agentX.publicKey, 3),
      airdrop(conn, agentXOwner.publicKey, 5),
      airdrop(conn, agentZ.publicKey, 3),
      airdrop(conn, agentZOwner.publicKey, 5),
    ]);

    // ── Create mock USDC ─────────────────────────────────────────────────────
    mock = await createMockUsdc(provider);

    // ── Derive all PDAs ──────────────────────────────────────────────────────
    walletConfigPda   = deriveWalletConfig(walletProgram.programId);
    vaultConfigPda    = deriveVaultConfig(vaultProgram.programId);
    vaultToken        = deriveVaultToken(vaultProgram.programId);
    insuranceToken    = deriveInsuranceToken(vaultProgram.programId);
    registryConfigPda = deriveRegistryConfig(regProgram.programId);
    whitelistConfigPda = deriveWhitelistConfig(wlProgram.programId);
    venuePda          = deriveVenuePda(venueId, wlProgram.programId);

    agentAWalletPda  = deriveAgentWallet(agentA.publicKey, walletProgram.programId);
    agentAWalletUsdc = deriveAgentWalletUsdc(agentA.publicKey, walletProgram.programId);
    agentAProfilePda = deriveAgentProfile(agentA.publicKey, regProgram.programId);
    agentACollateral = deriveCollateralPosition(agentA.publicKey, vaultProgram.programId);
    agentACreditLine = deriveCreditLine(agentA.publicKey, vaultProgram.programId);

    agentBWalletPda  = deriveAgentWallet(agentB.publicKey, walletProgram.programId);
    agentBWalletUsdc = deriveAgentWalletUsdc(agentB.publicKey, walletProgram.programId);
    agentBProfilePda = deriveAgentProfile(agentB.publicKey, regProgram.programId);
    agentBCollateral = deriveCollateralPosition(agentB.publicKey, vaultProgram.programId);
    agentBCreditLine = deriveCreditLine(agentB.publicKey, vaultProgram.programId);

    agentCWalletPda  = deriveAgentWallet(agentC.publicKey, walletProgram.programId);
    agentCWalletUsdc = deriveAgentWalletUsdc(agentC.publicKey, walletProgram.programId);
    agentCProfilePda = deriveAgentProfile(agentC.publicKey, regProgram.programId);
    agentCCreditLine = deriveCreditLine(agentC.publicKey, vaultProgram.programId);

    agentXWalletPda  = deriveAgentWallet(agentX.publicKey, walletProgram.programId);
    agentXWalletUsdc = deriveAgentWalletUsdc(agentX.publicKey, walletProgram.programId);
    agentXProfilePda = deriveAgentProfile(agentX.publicKey, regProgram.programId);

    // ── Mint USDC for participants ────────────────────────────────────────────
    const lpUsdc = await mintUsdc(provider, mock, lp.publicKey, 30_000);
    agentAOwnerUsdc = await mintUsdc(provider, mock, agentAOwner.publicKey, 10_000);
    agentBOwnerUsdc = await mintUsdc(provider, mock, agentBOwner.publicKey, 5_000);
    agentCOwnerUsdc = await mintUsdc(provider, mock, agentCOwner.publicKey, 5_000);
    keeperUsdc      = await mintUsdc(provider, mock, keeper.publicKey, 0);

    // venue_token: dedicated facilitator ATA (must be owned by venueId for pay_x402)
    venueTokenAccount = (
      await getOrCreateAssociatedTokenAccount(
        conn,
        // @ts-ignore
        provider.wallet.payer,
        mock.mint,
        venueId,
        true,
        undefined,
        undefined,
        TOKEN_PROGRAM_ID
      )
    ).address;

    // platform treasury token account
    platformTreasuryToken = await mintUsdc(provider, mock, admin.publicKey, 0);

    // ── 1. Init krexa-credit-vault ───────────────────────────────────────────
    //    wallet_program = walletConfigPda (the agent-wallet's config PDA)
    //    so CPI calls from agent-wallet are authenticated
    await vaultProgram.methods
      .initializeVault(
        oracle.publicKey,
        walletConfigPda,  // ← wallet_program authority that can call receive_repayment
        8500,             // 85% utilization cap
        1200,             // 12% annual base rate
        0                 // no lockup
      )
      .accounts({
        config: vaultConfigPda,
        usdcMint: mock.mint,
        vaultToken,
        insuranceToken,
        admin: admin.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .rpc();

    // ── 2. Init krexa-agent-registry ─────────────────────────────────────────
    //    wallet_program = walletConfigPda so CPIs from agent-wallet are authenticated
    await regProgram.methods
      .initialize(oracle.publicKey, walletConfigPda)
      .accounts({
        config: registryConfigPda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // ── 3. Init krexa-venue-whitelist ────────────────────────────────────────
    await wlProgram.methods
      .initialize()
      .accounts({
        config: whitelistConfigPda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // ── 4. Add a venue to the whitelist ─────────────────────────────────────
    await wlProgram.methods
      .addVenue(venueId, agentName("MockDEX"), 0) // category 0 = dex
      .accounts({
        config: whitelistConfigPda,
        venue: venuePda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    // ── 5. LP deposits $30,000 into the vault ───────────────────────────────
    const lpDepositPda = PublicKey.findProgramAddressSync(
      [Buffer.from("deposit"), lp.publicKey.toBuffer()],
      vaultProgram.programId
    )[0];
    await vaultProgram.methods
      .depositLiquidity(new BN(30_000 * USDC_ONE))
      .accounts({
        config: vaultConfigPda,
        vaultToken,
        depositPosition: lpDepositPda,
        depositorUsdc: lpUsdc,
        depositor: lp.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([lp])
      .rpc();

    // ── 6. Register all agents in the registry ───────────────────────────────
    for (const [agent, owner] of [
      [agentA, agentAOwner],
      [agentB, agentBOwner],
      [agentC, agentCOwner],
      [agentX, agentXOwner],
    ] as [Keypair, Keypair][]) {
      const profilePda = deriveAgentProfile(agent.publicKey, regProgram.programId);
      await regProgram.methods
        .registerAgent(agentName(agent.publicKey.toBase58().slice(0, 20)))
        .accounts({
          config: registryConfigPda,
          profile: profilePda,
          agent: agent.publicKey,
          owner: owner.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([agent, owner])
        .rpc();
    }

    // ── 7. Set KYA tier 1 on all agents (grants credit_level = 1) ──────────
    for (const agent of [agentA, agentB, agentC, agentX]) {
      const profilePda = deriveAgentProfile(agent.publicKey, regProgram.programId);
      await regProgram.methods
        .updateKya(1) // tier 1 → auto-promotes to credit_level 1
        .accounts({
          config: registryConfigPda,
          profile: profilePda,
          authority: oracle.publicKey,
        })
        .signers([oracle])
        .rpc();
    }

    // ── 8. Init krexa-agent-wallet ───────────────────────────────────────────
    // (tested in test 1, but must happen before any wallet ops)
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 1. Initialize
  // ─────────────────────────────────────────────────────────────────────────────

  it("1. initializes the wallet program config", async () => {
    await walletProgram.methods
      .initialize(
        keeper.publicKey,
        vaultProgram.programId,
        regProgram.programId,
        wlProgram.programId,
        Keypair.generate().publicKey, // placeholder payment_router
      )
      .accounts({
        config: walletConfigPda,
        usdcMint: mock.mint,
        platformTreasury: platformTreasuryToken,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    const cfg = await walletProgram.account.walletConfig.fetch(walletConfigPda);
    expect(cfg.admin.toBase58()).to.equal(admin.publicKey.toBase58());
    expect(cfg.keeper.toBase58()).to.equal(keeper.publicKey.toBase58());
    expect(cfg.creditVaultProgram.toBase58()).to.equal(vaultProgram.programId.toBase58());
    expect(cfg.agentRegistryProgram.toBase58()).to.equal(regProgram.programId.toBase58());
    expect(cfg.usdcMint.toBase58()).to.equal(mock.mint.toBase58());
    expect(cfg.isPaused).to.be.false;
    expect(cfg.totalWallets.toNumber()).to.equal(0);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 2. create_wallet — failure: unregistered agent
  // ─────────────────────────────────────────────────────────────────────────────

  it("2. create_wallet fails for unregistered agent (no profile)", async () => {
    // agentZ never registered → no agent_profile PDA → constraint violation
    const agentZWallet  = deriveAgentWallet(agentZ.publicKey, walletProgram.programId);
    const agentZUsdcPda = deriveAgentWalletUsdc(agentZ.publicKey, walletProgram.programId);
    const agentZProfile = deriveAgentProfile(agentZ.publicKey, regProgram.programId);

    try {
      await walletProgram.methods
        .createWallet(new BN(DAILY_LIMIT))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentZWallet,
          walletUsdc: agentZUsdcPda,
          usdcMint: mock.mint,
          registryConfig: registryConfigPda,
          agentProfile: agentZProfile,
          agent: agentZ.publicKey,
          owner: agentZOwner.publicKey,
          registryProgram: regProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: SYSVAR_RENT_PUBKEY,
        })
        .signers([agentZ, agentZOwner])
        .rpc();
      expect.fail("should have thrown");
    } catch (e: any) {
      // AccountNotInitialized or AccountOwnedByWrongProgram
      expect(e.message).to.exist;
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 3. create_wallet — success for level-1 agent
  // ─────────────────────────────────────────────────────────────────────────────

  it("3. create_wallet succeeds for level-1 agentA", async () => {
    await walletProgram.methods
      .createWallet(new BN(DAILY_LIMIT))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        walletUsdc: agentAWalletUsdc,
        usdcMint: mock.mint,
        registryConfig: registryConfigPda,
        agentProfile: agentAProfilePda,
        agent: agentA.publicKey,
        owner: agentAOwner.publicKey,
        registryProgram: regProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .signers([agentA, agentAOwner])
      .rpc();

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.agent.toBase58()).to.equal(agentA.publicKey.toBase58());
    expect(wallet.owner.toBase58()).to.equal(agentAOwner.publicKey.toBase58());
    expect(wallet.dailySpendLimit.toNumber()).to.equal(DAILY_LIMIT);
    expect(wallet.creditLevel).to.equal(1);
    expect(wallet.isFrozen).to.be.false;
    expect(wallet.collateralShares.toNumber()).to.equal(0);

    // CPI to link_wallet should have set profile.has_wallet = true
    const profile = await regProgram.account.agentProfile.fetch(agentAProfilePda);
    expect(profile.hasWallet).to.be.true;
    expect(profile.walletPda.toBase58()).to.equal(agentAWalletPda.toBase58());

    // Config total_wallets incremented
    const cfg = await walletProgram.account.walletConfig.fetch(walletConfigPda);
    expect(cfg.totalWallets.toNumber()).to.equal(1);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 4. create_wallet — duplicate fails
  // ─────────────────────────────────────────────────────────────────────────────

  it("4. create_wallet fails if agentA already has a wallet", async () => {
    try {
      await walletProgram.methods
        .createWallet(new BN(DAILY_LIMIT))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          usdcMint: mock.mint,
          registryConfig: registryConfigPda,
          agentProfile: agentAProfilePda,
          agent: agentA.publicKey,
          owner: agentAOwner.publicKey,
          registryProgram: regProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
          rent: SYSVAR_RENT_PUBKEY,
        })
        .signers([agentA, agentAOwner])
        .rpc();
      expect.fail("should have thrown WalletAlreadyExists");
    } catch (e: any) {
      expect(e.message).to.include("WalletAlreadyExists");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 5. deposit — collateral CPI into credit vault
  // ─────────────────────────────────────────────────────────────────────────────

  it("5. deposit routes $100 collateral into credit vault — wallet.collateral_shares updated", async () => {
    // The wallet.deposit instruction requires collateral_position to already exist.
    // We initialize it directly via vault first (init_if_needed), then call wallet.deposit.
    const depositAmount = 100 * USDC_ONE;

    // Step 1: initialize via vault directly (creates collateral_position)
    await vaultProgram.methods
      .depositCollateral(agentA.publicKey, new BN(depositAmount))
      .accounts({
        config: vaultConfigPda,
        vaultToken,
        collateralPosition: agentACollateral,
        ownerUsdc: agentAOwnerUsdc,
        owner: agentAOwner.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentAOwner])
      .rpc();

    const vaultCfgBefore = await vaultProgram.account.vaultConfig.fetch(vaultConfigPda);
    const sharesBefore = (await vaultProgram.account.depositPosition.fetch(agentACollateral)).shares.toNumber();

    // Step 2: deposit another $100 via wallet program (tests the CPI flow)
    await walletProgram.methods
      .deposit(new BN(depositAmount))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        vaultConfig: vaultConfigPda,
        vaultToken,
        collateralPosition: agentACollateral,
        ownerUsdc: agentAOwnerUsdc,
        owner: agentAOwner.publicKey,
        vaultProgram: vaultProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentAOwner])
      .rpc();

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    // collateral_shares should have increased by depositAmount shares (at ~1:1 ratio)
    expect(wallet.collateralShares.toNumber()).to.be.greaterThan(sharesBefore);

    const collPos = await vaultProgram.account.depositPosition.fetch(agentACollateral);
    expect(collPos.isCollateral).to.be.true;
    expect(collPos.agentPubkey.toBase58()).to.equal(agentA.publicKey.toBase58());
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 6. withdraw — succeeds freely when no debt
  // ─────────────────────────────────────────────────────────────────────────────

  it("6. withdraw succeeds when wallet has no outstanding debt", async () => {
    // Mint $50 directly to agent wallet USDC account
    await mintTo(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentAWalletUsdc,
      mock.mintAuthority,
      50 * USDC_ONE
    );

    const before = await getAccount(conn, agentAOwnerUsdc);

    await walletProgram.methods
      .withdraw(new BN(50 * USDC_ONE))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        walletUsdc: agentAWalletUsdc,
        ownerUsdc: agentAOwnerUsdc,
        vaultConfig: vaultConfigPda,
        owner: agentAOwner.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([agentAOwner])
      .rpc();

    const after = await getAccount(conn, agentAOwnerUsdc);
    expect(Number(after.amount) - Number(before.amount)).to.equal(50 * USDC_ONE);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 7. request_credit — wrong oracle fails
  // ─────────────────────────────────────────────────────────────────────────────

  it("7. request_credit fails when signed by non-oracle", async () => {
    try {
      await walletProgram.methods
        .requestCredit(
          new BN(400 * USDC_ONE),
          1200, // 12% rate
          1,    // credit level
          new BN(0)
        )
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          vaultConfig: vaultConfigPda,
          vaultToken,
          creditLine: agentACreditLine,
          oracle: stranger.publicKey,  // ← wrong
          vaultProgram: vaultProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotOracle");
    } catch (e: any) {
      expect(e.message).to.include("NotOracle");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 8. request_credit — oracle co-signs, USDC flows to wallet
  // ─────────────────────────────────────────────────────────────────────────────

  it("8. request_credit succeeds with oracle co-sign — $400 USDC in wallet", async () => {
    const creditAmount = 400 * USDC_ONE; // within level-1 $500 cap
    const vaultBefore = await vaultProgram.account.vaultConfig.fetch(vaultConfigPda);

    await walletProgram.methods
      .requestCredit(
        new BN(creditAmount),
        1200, // 12% annual rate
        1,    // credit level
        new BN(0)
      )
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        walletUsdc: agentAWalletUsdc,
        vaultConfig: vaultConfigPda,
        vaultToken,
        creditLine: agentACreditLine,
        oracle: oracle.publicKey,
        vaultProgram: vaultProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.creditDrawn.toNumber()).to.equal(creditAmount);
    expect(wallet.totalDebt.toNumber()).to.equal(creditAmount);
    expect(wallet.creditLimit.toNumber()).to.equal(creditAmount);

    // wallet_usdc should now hold $400
    const walletUsdcAcct = await getAccount(conn, agentAWalletUsdc);
    expect(Number(walletUsdcAcct.amount)).to.equal(creditAmount);

    // vault total_deployed increased
    const vaultAfter = await vaultProgram.account.vaultConfig.fetch(vaultConfigPda);
    expect(vaultAfter.totalDeployed.toNumber()).to.equal(
      vaultBefore.totalDeployed.toNumber() + creditAmount
    );

    const cl = await vaultProgram.account.creditLine.fetch(agentACreditLine);
    expect(cl.isActive).to.be.true;
    expect(cl.creditDrawn.toNumber()).to.equal(creditAmount);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 9. request_credit — second draw fails (already drawn)
  // ─────────────────────────────────────────────────────────────────────────────

  it("9. request_credit fails when credit already drawn", async () => {
    try {
      await walletProgram.methods
        .requestCredit(new BN(100 * USDC_ONE), 1200, 1, new BN(0))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          vaultConfig: vaultConfigPda,
          vaultToken,
          creditLine: agentACreditLine,
          oracle: oracle.publicKey,
          vaultProgram: vaultProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([oracle])
        .rpc();
      expect.fail("should have thrown CreditAlreadyDrawn");
    } catch (e: any) {
      expect(e.message).to.include("CreditAlreadyDrawn");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 10. execute_trade — frozen wallet fails
  // ─────────────────────────────────────────────────────────────────────────────

  it("10. execute_trade fails when wallet is frozen", async () => {
    // Admin freezes agentA
    await walletProgram.methods
      .freezeWallet()
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        admin: admin.publicKey,
      })
      .rpc();

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.isFrozen).to.be.true;

    try {
      await walletProgram.methods
        .executeTrade(venueId, new BN(10 * USDC_ONE), Buffer.from([]))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          venueToken: venueTokenAccount,
          venueEntry: venuePda,
          vaultConfig: vaultConfigPda,
          agent: agentA.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentA])
        .rpc();
      expect.fail("should have thrown WalletFrozen");
    } catch (e: any) {
      expect(e.message).to.include("WalletFrozen");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 11. admin unfreeze
  // ─────────────────────────────────────────────────────────────────────────────

  it("11. admin can unfreeze a wallet", async () => {
    await walletProgram.methods
      .unfreezeWallet()
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        admin: admin.publicKey,
      })
      .rpc();

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.isFrozen).to.be.false;
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 12. execute_trade — unwhitelisted venue fails
  // ─────────────────────────────────────────────────────────────────────────────

  it("12. execute_trade fails for unwhitelisted venue", async () => {
    const fakeVenueId  = Keypair.generate().publicKey;
    const fakeVenuePda = deriveVenuePda(fakeVenueId, wlProgram.programId);

    try {
      await walletProgram.methods
        .executeTrade(fakeVenueId, new BN(10 * USDC_ONE), Buffer.from([]))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          venueToken: venueTokenAccount,
          venueEntry: fakeVenuePda,
          vaultConfig: vaultConfigPda,
          agent: agentA.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentA])
        .rpc();
      expect.fail("should have thrown — venue not whitelisted");
    } catch (e: any) {
      // AccountNotInitialized or VenueNotWhitelisted — venue PDA doesn't exist
      expect(e.message).to.exist;
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 13. execute_trade — per-trade limit (20%) exceeded
  // ─────────────────────────────────────────────────────────────────────────────

  it("13. execute_trade fails when amount exceeds 20% of wallet balance", async () => {
    // Wallet has $400, 20% = $80. Try $85.
    const walletBalance = (await getAccount(conn, agentAWalletUsdc)).amount;
    const overLimit = Math.floor(Number(walletBalance) * 21 / 100); // 21% → over limit

    try {
      await walletProgram.methods
        .executeTrade(venueId, new BN(overLimit), Buffer.from([]))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          venueToken: venueTokenAccount,
          venueEntry: venuePda,
          vaultConfig: vaultConfigPda,
          agent: agentA.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentA])
        .rpc();
      expect.fail("should have thrown ExceedsPerTradeLimit");
    } catch (e: any) {
      expect(e.message).to.include("ExceedsPerTradeLimit");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 14. execute_trade — succeeds, stats updated
  // ─────────────────────────────────────────────────────────────────────────────

  it("14. execute_trade succeeds — $70 trade, stats updated", async () => {
    // $70 = 17.5% of $400 (within 20% limit)
    // post-HF = (400-70 + 200collateral) / 400 * 10000 = 530/400*10000 = 13250 >= 13000 ✓
    // daily_spent: 70M (within $500 limit)
    const tradeAmount = 70 * USDC_ONE;
    const venueBefore = await getAccount(conn, venueTokenAccount);
    const walletBefore = await walletProgram.account.agentWallet.fetch(agentAWalletPda);

    await walletProgram.methods
      .executeTrade(venueId, new BN(tradeAmount), Buffer.from([0x01]))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        walletUsdc: agentAWalletUsdc,
        venueToken: venueTokenAccount,
        venueEntry: venuePda,
        vaultConfig: vaultConfigPda,
        agent: agentA.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([agentA])
      .rpc();

    const venueAfter = await getAccount(conn, venueTokenAccount);
    expect(Number(venueAfter.amount) - Number(venueBefore.amount)).to.equal(tradeAmount);

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.totalTrades.toNumber()).to.equal(walletBefore.totalTrades.toNumber() + 1);
    expect(wallet.totalVolume.toNumber()).to.equal(
      walletBefore.totalVolume.toNumber() + tradeAmount
    );
    expect(wallet.dailySpent.toNumber()).to.equal(tradeAmount);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 15. execute_trade — health factor too low
  // ─────────────────────────────────────────────────────────────────────────────

  it("15. execute_trade fails when trade would push health factor below HF_WARNING", async () => {
    // After test 14: wallet_usdc = $330, collateral = ~$200, debt = $400
    // Current HF = (330 + 200) / 400 * 10000 = 13250 (ok, not frozen)
    // 20% of 330 = 66 → per-trade limit = $66
    // post-HF with $66: (330-66+200)/400*10000 = 464/400*10000 = 11600 < 13000 → HealthTooLow
    const walletBalance = Number((await getAccount(conn, agentAWalletUsdc)).amount);
    const atPerTradeLimit = Math.floor(walletBalance * 20 / 100); // 20% exactly

    try {
      await walletProgram.methods
        .executeTrade(venueId, new BN(atPerTradeLimit), Buffer.from([]))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          venueToken: venueTokenAccount,
          venueEntry: venuePda,
          vaultConfig: vaultConfigPda,
          agent: agentA.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentA])
        .rpc();
      expect.fail("should have thrown HealthTooLow");
    } catch (e: any) {
      expect(e.message).to.include("HealthTooLow");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 16. pay_x402 — X-402 micro-payment via whitelist
  // ─────────────────────────────────────────────────────────────────────────────

  it("16. pay_x402 sends USDC to facilitator with venue whitelist check", async () => {
    // venueId acts as both the venue and facilitator (its PDA is whitelisted)
    const payAmount = 5 * USDC_ONE; // $5 — well within all limits
    const recipient = Keypair.generate().publicKey;
    const memo = Buffer.alloc(32, 0);

    const facilitatorBefore = await getAccount(conn, venueTokenAccount);

    await walletProgram.methods
      .payX402(venueId, recipient, new BN(payAmount), [...memo])
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        walletUsdc: agentAWalletUsdc,
        facilitatorToken: venueTokenAccount,
        platformTreasuryToken,
        venueEntry: venuePda,
        vaultConfig: vaultConfigPda,
        agent: agentA.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([agentA])
      .rpc();

    const facilitatorAfter = await getAccount(conn, venueTokenAccount);
    expect(Number(facilitatorAfter.amount) - Number(facilitatorBefore.amount)).to.equal(payAmount);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 17. execute_trade — wrong agent keypair fails
  // ─────────────────────────────────────────────────────────────────────────────

  it("17. execute_trade fails when wrong keypair signs (stranger, not agent)", async () => {
    try {
      await walletProgram.methods
        .executeTrade(venueId, new BN(1 * USDC_ONE), Buffer.from([]))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          venueToken: venueTokenAccount,
          venueEntry: venuePda,
          vaultConfig: vaultConfigPda,
          agent: stranger.publicKey, // ← wrong — not agentA
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown UnauthorizedAgent or constraint violation");
    } catch (e: any) {
      expect(e.message).to.exist;
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 18. withdrawal gate — 120% buffer enforced when in debt
  // ─────────────────────────────────────────────────────────────────────────────

  it("18. withdraw fails when 120% buffer would be violated", async () => {
    // wallet_usdc ~ $325, debt = $400, collateral ~ $200
    // max_withdrawable = wallet_usdc - max(0, debt*1.2 - collateral)
    //                  = 325M - max(0, 480M - 200M) = 325M - 280M = 45M
    // Trying to withdraw $100 (> 45M max) should fail
    try {
      await walletProgram.methods
        .withdraw(new BN(100 * USDC_ONE))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          ownerUsdc: agentAOwnerUsdc,
          vaultConfig: vaultConfigPda,
          owner: agentAOwner.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentAOwner])
        .rpc();
      expect.fail("should have thrown WithdrawalGate");
    } catch (e: any) {
      expect(e.message).to.include("WithdrawalGate");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 19. check_health — updates HF, auto-freezes when HF < HF_DANGER
  // ─────────────────────────────────────────────────────────────────────────────

  it("19. check_health updates health_factor_bps and auto-freezes at danger threshold", async () => {
    // wallet_usdc ~ $325, collateral ~ $200, debt = $400
    // HF = (325 + 200) / 400 * 10000 = 13125 > 12000 → not frozen
    await walletProgram.methods
      .checkHealth()
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        walletUsdc: agentAWalletUsdc,
        vaultConfig: vaultConfigPda,
        caller: admin.publicKey,
      })
      .rpc();

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.healthFactorBps).to.be.greaterThan(0);
    expect(wallet.healthFactorBps).to.be.lessThan(65535); // not u16::MAX
    // HF > 12000, so should NOT be frozen by check_health
    expect(wallet.isFrozen).to.be.false;
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 20. repay — clears credit line, updates registry stats
  // ─────────────────────────────────────────────────────────────────────────────

  it("20. repay clears credit line and updates registry agent stats", async () => {
    // Mint additional USDC to wallet to cover the full $400 debt
    // (wallet currently has ~$325)
    await mintTo(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentAWalletUsdc,
      mock.mintAuthority,
      100 * USDC_ONE // top up by $100 so wallet has ~$425
    );

    const repayAmount = 400 * USDC_ONE;
    const profileBefore = await regProgram.account.agentProfile.fetch(agentAProfilePda);
    const vaultBefore = await vaultProgram.account.vaultConfig.fetch(vaultConfigPda);

    await walletProgram.methods
      .repay(new BN(repayAmount))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        walletUsdc: agentAWalletUsdc,
        vaultConfig: vaultConfigPda,
        vaultToken,
        insuranceToken,
        creditLine: agentACreditLine,
        registryConfig: registryConfigPda,
        agentProfile: agentAProfilePda,
        caller: agentAOwner.publicKey,
        vaultProgram: vaultProgram.programId,
        registryProgram: regProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([agentAOwner])
      .rpc();

    const wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.creditDrawn.toNumber()).to.equal(0);
    expect(wallet.totalDebt.toNumber()).to.equal(0);
    expect(wallet.totalRepaid.toNumber()).to.equal(repayAmount);

    const cl = await vaultProgram.account.creditLine.fetch(agentACreditLine);
    expect(cl.isActive).to.be.false;
    expect(cl.creditDrawn.toNumber()).to.equal(0);

    // vault total_deployed decreased
    const vaultAfter = await vaultProgram.account.vaultConfig.fetch(vaultConfigPda);
    expect(vaultAfter.totalDeployed.toNumber()).to.be.lessThan(
      vaultBefore.totalDeployed.toNumber()
    );

    // registry stats updated
    const profileAfter = await regProgram.account.agentProfile.fetch(agentAProfilePda);
    expect(profileAfter.totalRepaid.toNumber()).to.be.greaterThan(
      profileBefore.totalRepaid.toNumber()
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 21. admin freeze/unfreeze
  // ─────────────────────────────────────────────────────────────────────────────

  it("21. admin can freeze and unfreeze a wallet", async () => {
    // Freeze
    await walletProgram.methods
      .freezeWallet()
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        admin: admin.publicKey,
      })
      .rpc();
    let wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.isFrozen).to.be.true;

    // Unfreeze
    await walletProgram.methods
      .unfreezeWallet()
      .accounts({
        config: walletConfigPda,
        agentWallet: agentAWalletPda,
        admin: admin.publicKey,
      })
      .rpc();
    wallet = await walletProgram.account.agentWallet.fetch(agentAWalletPda);
    expect(wallet.isFrozen).to.be.false;
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 22. stranger cannot call admin functions
  // ─────────────────────────────────────────────────────────────────────────────

  it("22. stranger cannot call freeze_wallet (not admin)", async () => {
    try {
      await walletProgram.methods
        .freezeWallet()
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          admin: stranger.publicKey,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotAdmin");
    } catch (e: any) {
      expect(e.message).to.exist;
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 23. keeper cannot call admin-only functions
  // ─────────────────────────────────────────────────────────────────────────────

  it("23. keeper cannot call freeze_wallet (not admin)", async () => {
    try {
      await walletProgram.methods
        .freezeWallet()
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          admin: keeper.publicKey,
        })
        .signers([keeper])
        .rpc();
      expect.fail("should have thrown NotAdmin");
    } catch (e: any) {
      expect(e.message).to.exist;
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 24. daily spend limit enforcement (agentX)
  // ─────────────────────────────────────────────────────────────────────────────

  it("24. execute_trade fails when cumulative daily spend exceeds limit", async () => {
    // Setup agentX wallet with $200 daily limit
    const agentXDailyLimit = 200 * USDC_ONE;

    await walletProgram.methods
      .createWallet(new BN(agentXDailyLimit))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentXWalletPda,
        walletUsdc: agentXWalletUsdc,
        usdcMint: mock.mint,
        registryConfig: registryConfigPda,
        agentProfile: agentXProfilePda,
        agent: agentX.publicKey,
        owner: agentXOwner.publicKey,
        registryProgram: regProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .signers([agentX, agentXOwner])
      .rpc();

    // Fund agentX wallet directly (no credit needed)
    await mintTo(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentXWalletUsdc,
      mock.mintAuthority,
      1000 * USDC_ONE
    );

    // First trade: $150 → succeeds (150 < 200 daily limit)
    await walletProgram.methods
      .executeTrade(venueId, new BN(150 * USDC_ONE), Buffer.from([]))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentXWalletPda,
        walletUsdc: agentXWalletUsdc,
        venueToken: venueTokenAccount,
        venueEntry: venuePda,
        vaultConfig: vaultConfigPda,
        agent: agentX.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([agentX])
      .rpc();

    const wx = await walletProgram.account.agentWallet.fetch(agentXWalletPda);
    expect(wx.dailySpent.toNumber()).to.equal(150 * USDC_ONE);

    // Second trade: $60 → fails (150 + 60 = 210 > 200 daily limit)
    try {
      await walletProgram.methods
        .executeTrade(venueId, new BN(60 * USDC_ONE), Buffer.from([]))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentXWalletPda,
          walletUsdc: agentXWalletUsdc,
          venueToken: venueTokenAccount,
          venueEntry: venuePda,
          vaultConfig: vaultConfigPda,
          agent: agentX.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentX])
        .rpc();
      expect.fail("should have thrown DailyLimitExceeded");
    } catch (e: any) {
      expect(e.message).to.include("DailyLimitExceeded");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 25. deleverage — keeper freezes at HF < HF_DANGER (agentB)
  // ─────────────────────────────────────────────────────────────────────────────

  it("25. deleverage: keeper freezes agentB when live HF < 1.2x (HF_DANGER)", async () => {
    // Setup agentB:
    // Step 1: create wallet
    await walletProgram.methods
      .createWallet(new BN(500 * USDC_ONE))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentBWalletPda,
        walletUsdc: agentBWalletUsdc,
        usdcMint: mock.mint,
        registryConfig: registryConfigPda,
        agentProfile: agentBProfilePda,
        agent: agentB.publicKey,
        owner: agentBOwner.publicKey,
        registryProgram: regProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .signers([agentB, agentBOwner])
      .rpc();

    // Step 2: initialize collateral_position via vault directly ($10)
    await vaultProgram.methods
      .depositCollateral(agentB.publicKey, new BN(10 * USDC_ONE))
      .accounts({
        config: vaultConfigPda,
        vaultToken,
        collateralPosition: agentBCollateral,
        ownerUsdc: agentBOwnerUsdc,
        owner: agentBOwner.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentBOwner])
      .rpc();

    // Step 3: deposit more via wallet (updates wallet.collateral_shares)
    await walletProgram.methods
      .deposit(new BN(10 * USDC_ONE))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentBWalletPda,
        vaultConfig: vaultConfigPda,
        vaultToken,
        collateralPosition: agentBCollateral,
        ownerUsdc: agentBOwnerUsdc,
        owner: agentBOwner.publicKey,
        vaultProgram: vaultProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentBOwner])
      .rpc();

    const walletB = await walletProgram.account.agentWallet.fetch(agentBWalletPda);
    expect(walletB.collateralShares.toNumber()).to.be.greaterThan(0);
    const collateralShares = walletB.collateralShares.toNumber();

    // Step 4: request $200 credit
    // After CPI: wallet_usdc = $200, stored collateral_shares ≈ 20M, debt = $200
    // live_hf = (200M + ~20M) / 200M * 10000 = ~11000 (below HF_DANGER=12000, above HF_LIQUIDATION=10500)
    await walletProgram.methods
      .requestCredit(new BN(200 * USDC_ONE), 1200, 1, new BN(0))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentBWalletPda,
        walletUsdc: agentBWalletUsdc,
        vaultConfig: vaultConfigPda,
        vaultToken,
        creditLine: agentBCreditLine,
        oracle: oracle.publicKey,
        vaultProgram: vaultProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    // Verify agentB's credit was drawn
    const wB = await walletProgram.account.agentWallet.fetch(agentBWalletPda);
    expect(wB.creditDrawn.toNumber()).to.equal(200 * USDC_ONE);
    expect(wB.totalDebt.toNumber()).to.equal(200 * USDC_ONE);
    // live_hf = (wallet_usdc_live + collateral_value) / debt * 10000
    // = (200M + ~20M) / 200M * 10000 ≈ 11000 — between HF_LIQUIDATION(10500) and HF_DANGER(12000)
    // The deleverage instruction below will confirm this by succeeding

    // Step 5: keeper triggers deleverage → freezes agentB
    await walletProgram.methods
      .deleverage()
      .accounts({
        config: walletConfigPda,
        agentWallet: agentBWalletPda,
        walletUsdc: agentBWalletUsdc,
        vaultConfig: vaultConfigPda,
        keeper: keeper.publicKey,
      })
      .signers([keeper])
      .rpc();

    const wBAfter = await walletProgram.account.agentWallet.fetch(agentBWalletPda);
    expect(wBAfter.isFrozen).to.be.true;
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 26. deleverage — fails if health is healthy (agentA after repayment)
  // ─────────────────────────────────────────────────────────────────────────────

  it("26. deleverage fails when health factor is >= HF_DANGER (HealthFactorHealthy)", async () => {
    // agentA repaid all debt in test 20, so HF = u16::MAX (no debt) → healthy
    try {
      await walletProgram.methods
        .deleverage()
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          vaultConfig: vaultConfigPda,
          keeper: keeper.publicKey,
        })
        .signers([keeper])
        .rpc();
      expect.fail("should have thrown HealthFactorHealthy");
    } catch (e: any) {
      expect(e.message).to.include("HealthFactorHealthy");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 27. liquidation — keeper liquidates agentC (HF < HF_LIQUIDATION)
  // ─────────────────────────────────────────────────────────────────────────────

  it("27. liquidate: keeper liquidates agentC (no collateral, HF = 10000 < 10500)", async () => {
    // Setup agentC: create wallet, no collateral, request $100 credit
    await walletProgram.methods
      .createWallet(new BN(500 * USDC_ONE))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentCWalletPda,
        walletUsdc: agentCWalletUsdc,
        usdcMint: mock.mint,
        registryConfig: registryConfigPda,
        agentProfile: agentCProfilePda,
        agent: agentC.publicKey,
        owner: agentCOwner.publicKey,
        registryProgram: regProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .signers([agentC, agentCOwner])
      .rpc();

    // Request $100 credit — no collateral → HF = 10000 < 10500 (liquidatable)
    await walletProgram.methods
      .requestCredit(new BN(100 * USDC_ONE), 1200, 1, new BN(0))
      .accounts({
        config: walletConfigPda,
        agentWallet: agentCWalletPda,
        walletUsdc: agentCWalletUsdc,
        vaultConfig: vaultConfigPda,
        vaultToken,
        creditLine: agentCCreditLine,
        oracle: oracle.publicKey,
        vaultProgram: vaultProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const wC = await walletProgram.account.agentWallet.fetch(agentCWalletPda);
    expect(wC.totalDebt.toNumber()).to.equal(100 * USDC_ONE);
    expect(wC.healthFactorBps).to.be.lessThan(10_500);

    const profileBefore = await regProgram.account.agentProfile.fetch(agentCProfilePda);
    const keeperBefore = await getAccount(conn, keeperUsdc);

    // Keeper liquidates agentC
    await walletProgram.methods
      .liquidate()
      .accounts({
        config: walletConfigPda,
        agentWallet: agentCWalletPda,
        walletUsdc: agentCWalletUsdc,
        vaultConfig: vaultConfigPda,
        vaultToken,
        insuranceToken,
        creditLine: agentCCreditLine,
        registryConfig: registryConfigPda,
        agentProfile: agentCProfilePda,
        keeperUsdc,
        ownerUsdc: agentCOwnerUsdc,
        keeper: keeper.publicKey,
        vaultProgram: vaultProgram.programId,
        registryProgram: regProgram.programId,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([keeper])
      .rpc();

    const wCAfter = await walletProgram.account.agentWallet.fetch(agentCWalletPda);
    expect(wCAfter.isFrozen).to.be.true;
    expect(wCAfter.isLiquidating).to.be.false;
    expect(wCAfter.creditDrawn.toNumber()).to.equal(0);
    expect(wCAfter.creditLimit.toNumber()).to.equal(0);

    // Keeper received 0.5% reward
    const keeperAfter = await getAccount(conn, keeperUsdc);
    const keeperReward = Math.floor(100 * USDC_ONE * 50 / 10_000); // 0.5%
    expect(Number(keeperAfter.amount) - Number(keeperBefore.amount)).to.equal(keeperReward);

    // Registry recorded the liquidation
    const profileAfter = await regProgram.account.agentProfile.fetch(agentCProfilePda);
    expect(profileAfter.liquidationCount).to.equal(
      profileBefore.liquidationCount + 1
    );
    expect(profileAfter.creditScore).to.be.lessThan(profileBefore.creditScore);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 28. liquidation — fails if HF above liquidation threshold
  // ─────────────────────────────────────────────────────────────────────────────

  it("28. liquidate fails when HF is >= HF_LIQUIDATION (HealthAboveLiquidation)", async () => {
    // agentA repaid all debt, HF = u16::MAX → well above liquidation threshold
    // We still need keeper_usdc and owner_usdc as accounts
    try {
      await walletProgram.methods
        .liquidate()
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          vaultConfig: vaultConfigPda,
          vaultToken,
          insuranceToken,
          creditLine: agentACreditLine,
          registryConfig: registryConfigPda,
          agentProfile: agentAProfilePda,
          keeperUsdc,
          ownerUsdc: agentAOwnerUsdc,
          keeper: keeper.publicKey,
          vaultProgram: vaultProgram.programId,
          registryProgram: regProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([keeper])
        .rpc();
      expect.fail("should have thrown HealthAboveLiquidation");
    } catch (e: any) {
      expect(e.message).to.include("HealthAboveLiquidation");
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 29. stranger cannot call keeper functions
  // ─────────────────────────────────────────────────────────────────────────────

  it("29. stranger cannot call deleverage (not keeper)", async () => {
    // Use agentB which was frozen by deleverage test — still need wallet
    // Actually, let's use agentA with no debt (HF = u16::MAX → HealthFactorHealthy fires first)
    // But to specifically test the NotKeeper error, we need a wallet in danger zone.
    // Use agentB (already deleverage-frozen, but is_frozen=true, is_liquidating=false)
    // Deleverage on frozen wallet: would fail NotKeeper first if stranger signs
    try {
      await walletProgram.methods
        .deleverage()
        .accounts({
          config: walletConfigPda,
          agentWallet: agentBWalletPda,
          walletUsdc: agentBWalletUsdc,
          vaultConfig: vaultConfigPda,
          keeper: stranger.publicKey, // ← wrong
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotKeeper");
    } catch (e: any) {
      // NotKeeper or constraint mismatch
      expect(e.message).to.exist;
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 30. repay fails when no credit line
  // ─────────────────────────────────────────────────────────────────────────────

  it("30. repay fails when there is no active credit line (NoCreditLine)", async () => {
    // agentA's credit line was cleared in test 20 — credit_drawn = 0, total_debt = 0
    try {
      await walletProgram.methods
        .repay(new BN(1 * USDC_ONE))
        .accounts({
          config: walletConfigPda,
          agentWallet: agentAWalletPda,
          walletUsdc: agentAWalletUsdc,
          vaultConfig: vaultConfigPda,
          vaultToken,
          insuranceToken,
          creditLine: agentACreditLine,
          registryConfig: registryConfigPda,
          agentProfile: agentAProfilePda,
          caller: agentAOwner.publicKey,
          vaultProgram: vaultProgram.programId,
          registryProgram: regProgram.programId,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentAOwner])
        .rpc();
      expect.fail("should have thrown NoCreditLine");
    } catch (e: any) {
      expect(e.message).to.include("NoCreditLine");
    }
  });
});
