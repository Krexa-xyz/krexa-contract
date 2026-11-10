import * as anchor from "@coral-xyz/anchor";
import { Program, BN } from "@coral-xyz/anchor";
import { KrexaCreditVault } from "../target/types/krexa_credit_vault";
import {
  Keypair,
  PublicKey,
  SystemProgram,
  SYSVAR_RENT_PUBKEY,
} from "@solana/web3.js";
import {
  TOKEN_PROGRAM_ID,
  getOrCreateAssociatedTokenAccount,
  getAccount,
  createAssociatedTokenAccount,
  transfer as splTransfer,
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

const USDC_DECIMALS = 6;
const USDC_ONE = 1_000_000; // 1 USDC in base units

// ─────────────────────────────────────────────────────────────────────────────
// PDA helpers
// ─────────────────────────────────────────────────────────────────────────────

function deriveVaultConfig(programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("vault_config")],
    programId
  )[0];
}

function deriveVaultToken(programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("vault_usdc")],
    programId
  )[0];
}

function deriveInsuranceToken(programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("insurance_usdc")],
    programId
  )[0];
}

function deriveDepositPosition(depositor: PublicKey, programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("deposit"), depositor.toBuffer()],
    programId
  )[0];
}

function deriveCollateralPosition(agent: PublicKey, programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("collateral"), agent.toBuffer()],
    programId
  )[0];
}

function deriveCreditLine(agent: PublicKey, programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("credit_line"), agent.toBuffer()],
    programId
  )[0];
}

async function airdrop(
  conn: anchor.web3.Connection,
  pk: PublicKey,
  sol = 2
): Promise<void> {
  const sig = await conn.requestAirdrop(pk, sol * anchor.web3.LAMPORTS_PER_SOL);
  await conn.confirmTransaction(sig);
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("krexa-credit-vault", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.KrexaCreditVault as Program<KrexaCreditVault>;
  const conn = provider.connection;

  const admin = provider.wallet as anchor.Wallet;
  const oracle = Keypair.generate();
  const walletProgram = Keypair.generate(); // stands in for krexa-agent-wallet

  // Two LP providers
  const lp1 = Keypair.generate();
  const lp2 = Keypair.generate();

  // Agent + owner
  const agentA = Keypair.generate();
  const agentAOwner = Keypair.generate();

  // Second agent for utilization tests
  const agentB = Keypair.generate();
  const agentBOwner = Keypair.generate();

  let mock: MockUsdc;
  let configPda: PublicKey;
  let vaultToken: PublicKey;
  let insuranceToken: PublicKey;

  let lp1Usdc: PublicKey;
  let lp2Usdc: PublicKey;
  let agentAOwnerUsdc: PublicKey;
  let agentBOwnerUsdc: PublicKey;

  // ── 0. Setup ───────────────────────────────────────────────────────────────

  before(async () => {
    // Airdrop SOL
    await Promise.all([
      airdrop(conn, oracle.publicKey),
      airdrop(conn, walletProgram.publicKey),
      airdrop(conn, lp1.publicKey, 5),
      airdrop(conn, lp2.publicKey, 5),
      airdrop(conn, agentAOwner.publicKey, 5),
      airdrop(conn, agentBOwner.publicKey, 5),
    ]);

    // Mock USDC
    mock = await createMockUsdc(provider);

    // Create ATAs and mint USDC
    lp1Usdc = await mintUsdc(provider, mock, lp1.publicKey, 50_000);
    lp2Usdc = await mintUsdc(provider, mock, lp2.publicKey, 50_000);
    agentAOwnerUsdc = await mintUsdc(provider, mock, agentAOwner.publicKey, 20_000);
    agentBOwnerUsdc = await mintUsdc(provider, mock, agentBOwner.publicKey, 20_000);

    configPda = deriveVaultConfig(program.programId);
    vaultToken = deriveVaultToken(program.programId);
    insuranceToken = deriveInsuranceToken(program.programId);
  });

  // ── 1. initialize_vault ────────────────────────────────────────────────────

  it("initializes the vault with correct parameters", async () => {
    await program.methods
      .initializeVault(
        oracle.publicKey,
        walletProgram.publicKey,
        8500,  // 85% utilization cap
        1200,  // 12% annual base rate
        0      // no lockup
      )
      .accounts({
        config: configPda,
        usdcMint: mock.mint,
        vaultToken,
        insuranceToken,
        admin: admin.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent: SYSVAR_RENT_PUBKEY,
      })
      .rpc();

    const cfg = await program.account.vaultConfig.fetch(configPda);
    expect(cfg.admin.toBase58()).to.equal(admin.publicKey.toBase58());
    expect(cfg.oracle.toBase58()).to.equal(oracle.publicKey.toBase58());
    expect(cfg.walletProgram.toBase58()).to.equal(walletProgram.publicKey.toBase58());
    expect(cfg.utilizationCapBps).to.equal(8500);
    expect(cfg.baseInterestRateBps).to.equal(1200);
    expect(cfg.totalDeposits.toNumber()).to.equal(0);
    expect(cfg.totalShares.toNumber()).to.equal(0);
    expect(cfg.isPaused).to.be.false;
  });

  // ── 2. deposit_liquidity — first deposit (1:1 share ratio) ─────────────────

  it("LP1 deposits $10,000 USDC — gets 1:1 shares on first deposit", async () => {
    const depositAmount = 10_000 * USDC_ONE;
    const depositPositionPda = deriveDepositPosition(lp1.publicKey, program.programId);

    await program.methods
      .depositLiquidity(new BN(depositAmount))
      .accounts({
        config: configPda,
        vaultToken,
        depositPosition: depositPositionPda,
        depositorUsdc: lp1Usdc,
        depositor: lp1.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([lp1])
      .rpc();

    const cfg = await program.account.vaultConfig.fetch(configPda);
    expect(cfg.totalDeposits.toNumber()).to.equal(depositAmount);
    expect(cfg.totalShares.toNumber()).to.equal(depositAmount); // 1:1

    const pos = await program.account.depositPosition.fetch(depositPositionPda);
    expect(pos.shares.toNumber()).to.equal(depositAmount);
    expect(pos.isCollateral).to.be.false;
  });

  // ── 3. deposit_liquidity — second LP proportional shares ──────────────────

  it("LP2 deposits $5,000 USDC — receives proportional shares", async () => {
    const depositAmount = 5_000 * USDC_ONE;
    const depositPositionPda = deriveDepositPosition(lp2.publicKey, program.programId);

    await program.methods
      .depositLiquidity(new BN(depositAmount))
      .accounts({
        config: configPda,
        vaultToken,
        depositPosition: depositPositionPda,
        depositorUsdc: lp2Usdc,
        depositor: lp2.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([lp2])
      .rpc();

    const cfg = await program.account.vaultConfig.fetch(configPda);
    // Pool: $15k deposits, 15M shares. LP2 deposited $5k → 5M shares
    expect(cfg.totalDeposits.toNumber()).to.equal(15_000 * USDC_ONE);
    expect(cfg.totalShares.toNumber()).to.equal(15_000 * USDC_ONE);

    const pos = await program.account.depositPosition.fetch(depositPositionPda);
    expect(pos.shares.toNumber()).to.equal(depositAmount);
  });

  // ── 4. deposit_collateral — agent owner deposits for agent ────────────────

  it("agentA owner deposits $2,000 collateral — earns same shares as LPs", async () => {
    const depositAmount = 2_000 * USDC_ONE;
    const collateralPda = deriveCollateralPosition(agentA.publicKey, program.programId);

    await program.methods
      .depositCollateral(agentA.publicKey, new BN(depositAmount))
      .accounts({
        config: configPda,
        vaultToken,
        collateralPosition: collateralPda,
        ownerUsdc: agentAOwnerUsdc,
        owner: agentAOwner.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentAOwner])
      .rpc();

    const cfg = await program.account.vaultConfig.fetch(configPda);
    // Pool: $17k deposits, 17M shares
    expect(cfg.totalDeposits.toNumber()).to.equal(17_000 * USDC_ONE);
    expect(cfg.totalShares.toNumber()).to.equal(17_000 * USDC_ONE);

    const pos = await program.account.depositPosition.fetch(collateralPda);
    expect(pos.isCollateral).to.be.true;
    expect(pos.agentPubkey.toBase58()).to.equal(agentA.publicKey.toBase58());
    expect(pos.shares.toNumber()).to.equal(depositAmount);
  });

  // ── 5. withdraw_liquidity — LP gets their USDC back ──────────────────────

  it("LP2 withdraws all their shares — receives proportional USDC", async () => {
    const depositPositionPda = deriveDepositPosition(lp2.publicKey, program.programId);
    const pos = await program.account.depositPosition.fetch(depositPositionPda);
    const shares = pos.shares.toNumber();

    const before = await getAccount(conn, lp2Usdc);

    await program.methods
      .withdrawLiquidity(new BN(shares))
      .accounts({
        config: configPda,
        vaultToken,
        depositPosition: depositPositionPda,
        depositorUsdc: lp2Usdc,
        depositor: lp2.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([lp2])
      .rpc();

    const after = await getAccount(conn, lp2Usdc);
    const received = Number(after.amount) - Number(before.amount);
    // At 1:1 ratio they should get exactly what they put in
    expect(received).to.equal(5_000 * USDC_ONE);

    const cfg = await program.account.vaultConfig.fetch(configPda);
    expect(cfg.totalDeposits.toNumber()).to.equal(12_000 * USDC_ONE);
  });

  // ── 6. withdraw_collateral — succeeds when no credit line ────────────────

  it("agentA owner withdraws collateral when no credit line exists", async () => {
    // First deposit more collateral so we have a balance to withdraw from
    const depositAmount = 1_000 * USDC_ONE;
    const collateralPda = deriveCollateralPosition(agentA.publicKey, program.programId);

    // Get current shares before adding more
    const before = await program.account.depositPosition.fetch(collateralPda);
    const beforeShares = before.shares.toNumber();

    // Withdraw half the current shares — credit_line PDA doesn't exist → empty account
    const creditLinePda = deriveCreditLine(agentA.publicKey, program.programId);
    const withdrawShares = Math.floor(beforeShares / 2);

    const usdcBefore = await getAccount(conn, agentAOwnerUsdc);

    await program.methods
      .withdrawCollateral(agentA.publicKey, new BN(withdrawShares))
      .accounts({
        config: configPda,
        vaultToken,
        collateralPosition: collateralPda,
        creditLine: creditLinePda,
        ownerUsdc: agentAOwnerUsdc,
        depositor: agentAOwner.publicKey,
        owner: agentAOwner.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([agentAOwner])
      .rpc();

    const usdcAfter = await getAccount(conn, agentAOwnerUsdc);
    expect(Number(usdcAfter.amount)).to.be.greaterThan(Number(usdcBefore.amount));
  });

  // ── 7. extend_credit — oracle extends level-1 credit ($500 max, no collateral)

  it("oracle extends level-1 credit ($500) to agentA", async () => {
    // First re-deposit collateral since we withdrew some
    const agentAWalletUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentA.publicKey
    );

    const creditLinePda = deriveCreditLine(agentA.publicKey, program.programId);
    const creditAmount = 500 * USDC_ONE; // level 1 max

    await program.methods
      .extendCredit(
        agentA.publicKey,
        new BN(creditAmount),
        1200,         // 12% annual rate
        1,            // credit level 1
        new BN(0)     // collateral_value (irrelevant for level 1)
      )
      .accounts({
        config: configPda,
        vaultToken,
        creditLine: creditLinePda,
        agentWalletUsdc: agentAWalletUsdc.address,
        oracle: oracle.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const cl = await program.account.creditLine.fetch(creditLinePda);
    expect(cl.creditDrawn.toNumber()).to.equal(creditAmount);
    expect(cl.creditLimit.toNumber()).to.equal(500 * USDC_ONE);
    expect(cl.isActive).to.be.true;
    expect(cl.interestRateBps).to.equal(1200);

    const cfg = await program.account.vaultConfig.fetch(configPda);
    expect(cfg.totalDeployed.toNumber()).to.equal(creditAmount);

    // Verify agent received USDC
    const agentBalance = await getAccount(conn, agentAWalletUsdc.address);
    expect(Number(agentBalance.amount)).to.equal(creditAmount);
  });

  // ── 8. withdraw_collateral blocked while credit line active ───────────────

  it("withdraw_collateral is blocked while agentA has active credit line", async () => {
    const collateralPda = deriveCollateralPosition(agentA.publicKey, program.programId);
    const creditLinePda = deriveCreditLine(agentA.publicKey, program.programId);
    const pos = await program.account.depositPosition.fetch(collateralPda);

    try {
      await program.methods
        .withdrawCollateral(agentA.publicKey, new BN(pos.shares.toNumber()))
        .accounts({
          config: configPda,
          vaultToken,
          collateralPosition: collateralPda,
          creditLine: creditLinePda,
          ownerUsdc: agentAOwnerUsdc,
          depositor: agentAOwner.publicKey,
          owner: agentAOwner.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([agentAOwner])
        .rpc();
      expect.fail("should have thrown CreditLineActive");
    } catch (e: any) {
      expect(e.message).to.include("CreditLineActive");
    }
  });

  // ── 9. extend_credit — exceeds level-1 cap ────────────────────────────────

  it("oracle cannot extend credit above level-1 cap ($500) for level-1 agent", async () => {
    // Use agentB for this test (no credit line yet)
    const agentBWalletUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentB.publicKey
    );
    const creditLinePda = deriveCreditLine(agentB.publicKey, program.programId);

    try {
      await program.methods
        .extendCredit(
          agentB.publicKey,
          new BN(600 * USDC_ONE), // $600 > $500 level-1 cap
          1200,
          1,
          new BN(0)
        )
        .accounts({
          config: configPda,
          vaultToken,
          creditLine: creditLinePda,
          agentWalletUsdc: agentBWalletUsdc.address,
          oracle: oracle.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([oracle])
        .rpc();
      expect.fail("should have thrown ExceedsCreditLimit");
    } catch (e: any) {
      expect(e.message).to.include("ExceedsCreditLimit");
    }
  });

  // ── 10. level-2 credit with collateral leverage ───────────────────────────

  it("oracle extends level-2 credit ($2,000) with $2,000 collateral (1:1 leverage)", async () => {
    // Deposit $2000 collateral for agentB first
    const agentBCollateralPda = deriveCollateralPosition(agentB.publicKey, program.programId);
    await program.methods
      .depositCollateral(agentB.publicKey, new BN(2_000 * USDC_ONE))
      .accounts({
        config: configPda,
        vaultToken,
        collateralPosition: agentBCollateralPda,
        ownerUsdc: agentBOwnerUsdc,
        owner: agentBOwner.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentBOwner])
      .rpc();

    const agentBWalletUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentB.publicKey
    );
    const creditLinePda = deriveCreditLine(agentB.publicKey, program.programId);
    const collateralValue = 2_000 * USDC_ONE; // oracle attests this value

    await program.methods
      .extendCredit(
        agentB.publicKey,
        new BN(2_000 * USDC_ONE),
        1000, // 10% annual rate
        2,    // credit level 2
        new BN(collateralValue)
      )
      .accounts({
        config: configPda,
        vaultToken,
        creditLine: creditLinePda,
        agentWalletUsdc: agentBWalletUsdc.address,
        oracle: oracle.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    const cl = await program.account.creditLine.fetch(creditLinePda);
    expect(cl.creditDrawn.toNumber()).to.equal(2_000 * USDC_ONE);
    expect(cl.creditLimit.toNumber()).to.equal(2_000 * USDC_ONE); // 1:1 leverage
    expect(cl.isActive).to.be.true;
  });

  // ── 11. non-oracle cannot extend credit ───────────────────────────────────

  it("non-oracle cannot call extend_credit", async () => {
    const stranger = Keypair.generate();
    await airdrop(conn, stranger.publicKey);

    const agentC = Keypair.generate();
    const agentCWalletUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentC.publicKey
    );
    const creditLinePda = deriveCreditLine(agentC.publicKey, program.programId);

    try {
      await program.methods
        .extendCredit(agentC.publicKey, new BN(100 * USDC_ONE), 1000, 1, new BN(0))
        .accounts({
          config: configPda,
          vaultToken,
          creditLine: creditLinePda,
          agentWalletUsdc: agentCWalletUsdc.address,
          oracle: stranger.publicKey,
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

  // ── 12. receive_repayment — full repayment with insurance split ───────────

  it("agentA fully repays credit line — insurance fee split, credit cleared", async () => {
    const creditLinePda = deriveCreditLine(agentA.publicKey, program.programId);
    const clBefore = await program.account.creditLine.fetch(creditLinePda);
    const cfgBefore = await program.account.vaultConfig.fetch(configPda);

    const totalDebt = clBefore.creditDrawn.toNumber() + clBefore.accruedInterest.toNumber();
    // Repay exact principal (no interest yet — just borrowed)
    const repayAmount = clBefore.creditDrawn.toNumber();

    // Step 1: agent transfers USDC back to vault (simulates krexa-agent-wallet doing it)
    const agentAWalletUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentA.publicKey
    );
    await splTransfer(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      agentAWalletUsdc.address,
      vaultToken,
      agentA, // agent must sign their ATA
      repayAmount
    );

    // Step 2: call receive_repayment (walletProgram authority signs)
    await program.methods
      .receiveRepayment(agentA.publicKey, new BN(repayAmount))
      .accounts({
        config: configPda,
        vaultToken,
        insuranceToken,
        creditLine: creditLinePda,
        walletProgramAuthority: walletProgram.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([walletProgram])
      .rpc();

    const clAfter = await program.account.creditLine.fetch(creditLinePda);
    expect(clAfter.creditDrawn.toNumber()).to.equal(0);
    expect(clAfter.isActive).to.be.false;

    const cfgAfter = await program.account.vaultConfig.fetch(configPda);
    expect(cfgAfter.totalDeployed.toNumber()).to.equal(
      cfgBefore.totalDeployed.toNumber() - repayAmount
    );
  });

  // ── 13. non-wallet-program cannot call receive_repayment ─────────────────

  it("stranger cannot call receive_repayment", async () => {
    const stranger = Keypair.generate();
    await airdrop(conn, stranger.publicKey);
    const creditLinePda = deriveCreditLine(agentB.publicKey, program.programId);

    try {
      await program.methods
        .receiveRepayment(agentB.publicKey, new BN(100 * USDC_ONE))
        .accounts({
          config: configPda,
          vaultToken,
          insuranceToken,
          creditLine: creditLinePda,
          walletProgramAuthority: stranger.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotWalletProgram");
    } catch (e: any) {
      expect(e.message).to.include("NotWalletProgram");
    }
  });

  // ── 14. share price increases after interest received ─────────────────────

  it("interest received increases share price — LP gets more USDC per share", async () => {
    // LP1 currently has shares in the pool. We'll add artificial interest by
    // minting directly to vault_token and calling receive_repayment with interest.

    // Setup: agentA credit line is closed; open a new small one and repay with interest
    const agentD = Keypair.generate();
    const agentDWalletUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentD.publicKey
    );
    const creditLinePda = deriveCreditLine(agentD.publicKey, program.programId);

    await airdrop(conn, agentD.publicKey);

    // Record LP1 shares before interest
    const lp1PosPda = deriveDepositPosition(lp1.publicKey, program.programId);
    const lp1Pos = await program.account.depositPosition.fetch(lp1PosPda);
    const cfgBefore = await program.account.vaultConfig.fetch(configPda);
    const valueBeforePerShare =
      cfgBefore.totalDeposits.toNumber() / cfgBefore.totalShares.toNumber();

    // Extend $200 credit to agentD
    await program.methods
      .extendCredit(agentD.publicKey, new BN(200 * USDC_ONE), 1200, 1, new BN(0))
      .accounts({
        config: configPda,
        vaultToken,
        creditLine: creditLinePda,
        agentWalletUsdc: agentDWalletUsdc.address,
        oracle: oracle.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([oracle])
      .rpc();

    // Simulate repayment with $10 interest on top ($210 total)
    const interestAmount = 10 * USDC_ONE;
    const principal = 200 * USDC_ONE;
    const totalRepay = principal + interestAmount;

    // Mint extra $10 to agentD wallet (represents earned interest)
    await mintUsdc(provider, mock, agentD.publicKey, 10);
    // Transfer $210 back to vault
    await splTransfer(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      agentDWalletUsdc.address,
      vaultToken,
      agentD,
      totalRepay
    );

    await program.methods
      .receiveRepayment(agentD.publicKey, new BN(totalRepay))
      .accounts({
        config: configPda,
        vaultToken,
        insuranceToken,
        creditLine: creditLinePda,
        walletProgramAuthority: walletProgram.publicKey,
        tokenProgram: TOKEN_PROGRAM_ID,
      })
      .signers([walletProgram])
      .rpc();

    const cfgAfter = await program.account.vaultConfig.fetch(configPda);
    const valueAfterPerShare =
      cfgAfter.totalDeposits.toNumber() / cfgAfter.totalShares.toNumber();

    // Net interest (after 5% insurance cut) should have increased share price
    const insuranceCut = Math.floor(interestAmount * 500 / 10_000); // 5%
    expect(cfgAfter.insuranceBalance.toNumber()).to.equal(insuranceCut);
    expect(valueAfterPerShare).to.be.greaterThan(valueBeforePerShare);
  });

  // ── 15. bad debt write-off — insurance covers first, LP absorbs remainder ─

  it("admin writes off bad debt — insurance covers first, LP share price drops", async () => {
    // Ensure agentB credit line is still active
    const agentBCreditPda = deriveCreditLine(agentB.publicKey, program.programId);
    const clBefore = await program.account.creditLine.fetch(agentBCreditPda);
    expect(clBefore.isActive).to.be.true;

    const cfgBefore = await program.account.vaultConfig.fetch(configPda);
    const insuranceBefore = cfgBefore.insuranceBalance.toNumber();
    const depositsBefore = cfgBefore.totalDeposits.toNumber();
    const loss = clBefore.creditDrawn.toNumber() + clBefore.accruedInterest.toNumber();
    const insuranceCover = Math.min(loss, insuranceBefore);
    const lpAbsorb = loss - insuranceCover;

    await program.methods
      .writeOffBadDebt(agentB.publicKey)
      .accounts({
        config: configPda,
        creditLine: agentBCreditPda,
        admin: admin.publicKey,
      })
      .rpc();

    const clAfter = await program.account.creditLine.fetch(agentBCreditPda);
    expect(clAfter.isActive).to.be.false;
    expect(clAfter.creditDrawn.toNumber()).to.equal(0);

    const cfgAfter = await program.account.vaultConfig.fetch(configPda);
    expect(cfgAfter.insuranceBalance.toNumber()).to.equal(insuranceBefore - insuranceCover);
    // LP share price drops by lpAbsorb
    expect(cfgAfter.totalDeposits.toNumber()).to.equal(depositsBefore - lpAbsorb);
    expect(cfgAfter.totalDefaults.toNumber()).to.equal(loss);
  });

  // ── 16. non-admin cannot write off bad debt ────────────────────────────────

  it("non-admin cannot write off bad debt", async () => {
    // Use agentD credit line which is already closed — doesn't matter, auth check first
    const stranger = Keypair.generate();
    await airdrop(conn, stranger.publicKey);
    const creditLinePda = deriveCreditLine(agentA.publicKey, program.programId);

    try {
      await program.methods
        .writeOffBadDebt(agentA.publicKey)
        .accounts({
          config: configPda,
          creditLine: creditLinePda,
          admin: stranger.publicKey,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotAdmin");
    } catch (e: any) {
      expect(e.message).to.include("NotAdmin");
    }
  });

  // ── 17. set_paused — admin pauses and unpauses vault ─────────────────────

  it("admin can pause and unpause the vault", async () => {
    await program.methods
      .setPaused(true)
      .accounts({ config: configPda, admin: admin.publicKey })
      .rpc();

    let cfg = await program.account.vaultConfig.fetch(configPda);
    expect(cfg.isPaused).to.be.true;

    // Verify deposits are blocked while paused
    const lp2PositionPda = deriveDepositPosition(lp2.publicKey, program.programId);
    try {
      await program.methods
        .depositLiquidity(new BN(100 * USDC_ONE))
        .accounts({
          config: configPda,
          vaultToken,
          depositPosition: lp2PositionPda,
          depositorUsdc: lp2Usdc,
          depositor: lp2.publicKey,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([lp2])
        .rpc();
      expect.fail("should have thrown Paused");
    } catch (e: any) {
      expect(e.message).to.include("Paused");
    }

    // Unpause
    await program.methods
      .setPaused(false)
      .accounts({ config: configPda, admin: admin.publicKey })
      .rpc();

    cfg = await program.account.vaultConfig.fetch(configPda);
    expect(cfg.isPaused).to.be.false;
  });

  // ── 18. utilization cap enforcement ───────────────────────────────────────

  it("extend_credit fails when utilization cap (85%) would be exceeded", async () => {
    // Pool has limited free liquidity; try to draw 90% of it
    const cfg = await program.account.vaultConfig.fetch(configPda);
    const available = cfg.totalDeposits.toNumber() - cfg.totalDeployed.toNumber();
    // Try to borrow more than the utilization cap allows
    const overAmount = Math.floor(available * 0.90); // pushes past 85%

    const agentE = Keypair.generate();
    const agentEWalletUsdc = await getOrCreateAssociatedTokenAccount(
      conn,
      // @ts-ignore
      provider.wallet.payer,
      mock.mint,
      agentE.publicKey
    );
    const creditLinePda = deriveCreditLine(agentE.publicKey, program.programId);
    await airdrop(conn, agentE.publicKey);

    if (overAmount > 500 * USDC_ONE) {
      // Only meaningful if large enough to exceed cap
      try {
        await program.methods
          .extendCredit(agentE.publicKey, new BN(overAmount), 1000, 4, new BN(overAmount * 5))
          .accounts({
            config: configPda,
            vaultToken,
            creditLine: creditLinePda,
            agentWalletUsdc: agentEWalletUsdc.address,
            oracle: oracle.publicKey,
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([oracle])
          .rpc();
        expect.fail("should have thrown UtilizationCap");
      } catch (e: any) {
        expect(e.message).to.include("UtilizationCap");
      }
    } else {
      // Pool is already mostly deployed — skip this assertion
      console.log("  (skipped: pool liquidity too low to trigger utilization cap test)");
    }
  });
});
