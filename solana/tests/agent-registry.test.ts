import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { KrexaAgentRegistry } from "../target/types/krexa_agent_registry";
import { Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function agentName(s: string): number[] {
  const buf = Buffer.alloc(32, 0);
  Buffer.from(s).copy(buf);
  return [...buf];
}

function deriveConfig(programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("registry_config")],
    programId
  )[0];
}

function deriveProfile(agentPubkey: PublicKey, programId: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("agent_profile"), agentPubkey.toBuffer()],
    programId
  )[0];
}

async function airdrop(conn: anchor.web3.Connection, pk: PublicKey, sol = 1) {
  const sig = await conn.requestAirdrop(pk, sol * anchor.web3.LAMPORTS_PER_SOL);
  await conn.confirmTransaction(sig);
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("krexa-agent-registry", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.KrexaAgentRegistry as Program<KrexaAgentRegistry>;
  const conn = provider.connection;

  // Roles
  const admin   = provider.wallet as anchor.Wallet;
  const oracle   = Keypair.generate();
  const stranger = Keypair.generate();

  // A wallet-program signer stands in for the real krexa-agent-wallet program.
  // In production this is the agent-wallet config PDA. Here we use a keypair.
  const walletProgram = Keypair.generate();

  // Agent A — the first AI agent
  const agentA      = Keypair.generate();
  const agentAOwner = Keypair.generate();

  // Agent B — used for liquidation tests
  const agentB      = Keypair.generate();
  const agentBOwner = Keypair.generate();

  let configPda: PublicKey;

  // ── 1. Initialize ──────────────────────────────────────────────────────────

  it("initializes the registry config", async () => {
    configPda = deriveConfig(program.programId);

    await airdrop(conn, oracle.publicKey);
    await airdrop(conn, stranger.publicKey);
    await airdrop(conn, walletProgram.publicKey);
    await airdrop(conn, agentA.publicKey);
    await airdrop(conn, agentAOwner.publicKey, 2);
    await airdrop(conn, agentB.publicKey);
    await airdrop(conn, agentBOwner.publicKey, 2);

    await program.methods
      .initialize(oracle.publicKey, walletProgram.publicKey)
      .accounts({ config: configPda, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .rpc();

    const cfg = await program.account.registryConfig.fetch(configPda);
    expect(cfg.admin.toBase58()).to.equal(admin.publicKey.toBase58());
    expect(cfg.oracle.toBase58()).to.equal(oracle.publicKey.toBase58());
    expect(cfg.walletProgram.toBase58()).to.equal(walletProgram.publicKey.toBase58());
    expect(cfg.totalAgents.toNumber()).to.equal(0);
    expect(cfg.isPaused).to.be.false;
  });

  // ── 2. Register agent ──────────────────────────────────────────────────────

  it("registers agent A — both agent and owner must sign", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);

    await program.methods
      .registerAgent(agentName("TradingBot-Alpha"))
      .accounts({
        config: configPda,
        profile: profilePda,
        agent: agentA.publicKey,
        owner: agentAOwner.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentA, agentAOwner])
      .rpc();

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.agent.toBase58()).to.equal(agentA.publicKey.toBase58());
    expect(profile.owner.toBase58()).to.equal(agentAOwner.publicKey.toBase58());
    expect(profile.creditScore).to.equal(400); // DEFAULT_CREDIT_SCORE
    expect(profile.creditLevel).to.equal(0);   // KyaOnly
    expect(profile.kyaTier).to.equal(0);        // None
    expect(profile.isActive).to.be.true;
    expect(profile.hasWallet).to.be.false;

    const cfg = await program.account.registryConfig.fetch(configPda);
    expect(cfg.totalAgents.toNumber()).to.equal(1);
  });

  it("rejects registration when owner does not sign", async () => {
    const loneAgent = Keypair.generate();
    await airdrop(conn, loneAgent.publicKey, 2);
    const profilePda = deriveProfile(loneAgent.publicKey, program.programId);

    try {
      // Pass owner as a regular account (not a signer) — SDK will throw
      await program.methods
        .registerAgent(agentName("Unsigned-Bot"))
        .accounts({
          config: configPda,
          profile: profilePda,
          agent: loneAgent.publicKey,
          owner: stranger.publicKey,  // stranger does not co-sign
          systemProgram: SystemProgram.programId,
        })
        .signers([loneAgent]) // owner missing from signers
        .rpc();
      expect.fail("should have thrown — owner signature missing");
    } catch (e: any) {
      // Anchor / runtime rejects missing required signer
      expect(e.message).to.not.be.empty;
    }
  });

  // ── 3. KYA update ─────────────────────────────────────────────────────────

  it("oracle grants KYA Basic → auto-elevates agent to Starter (level 1)", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);

    await program.methods
      .updateKya(1) // Basic
      .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
      .signers([oracle])
      .rpc();

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.kyaTier).to.equal(1);
    expect(profile.creditLevel).to.equal(1); // auto-granted
    expect(profile.kyaVerifiedAt.toNumber()).to.be.greaterThan(0);
  });

  it("admin can also update KYA (admin OR oracle)", async () => {
    // Register agent B first
    const profilePda = deriveProfile(agentB.publicKey, program.programId);
    await program.methods
      .registerAgent(agentName("ArbBot-Beta"))
      .accounts({
        config: configPda,
        profile: profilePda,
        agent: agentB.publicKey,
        owner: agentBOwner.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([agentB, agentBOwner])
      .rpc();

    // Admin grants KYA Basic to agent B
    await program.methods
      .updateKya(1)
      .accounts({ config: configPda, profile: profilePda, authority: admin.publicKey })
      .rpc(); // admin is default payer — no extra signers needed

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.kyaTier).to.equal(1);
    expect(profile.creditLevel).to.equal(1);
  });

  it("stranger cannot update KYA", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);
    try {
      await program.methods
        .updateKya(2)
        .accounts({ config: configPda, profile: profilePda, authority: stranger.publicKey })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotAdminOrOracle");
    } catch (e: any) {
      expect(e.message).to.include("NotAdminOrOracle");
    }
  });

  // ── 4. Credit score + level auto-calculation ───────────────────────────────

  it("oracle sets score 650 with Enhanced KYA (tier 2) → level 3 (Trusted)", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);

    // First upgrade KYA to Enhanced
    await program.methods
      .updateKya(2)
      .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
      .signers([oracle])
      .rpc();

    // Now set score to 650
    await program.methods
      .updateCreditScore(650)
      .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
      .signers([oracle])
      .rpc();

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.creditScore).to.equal(650);
    expect(profile.creditLevel).to.equal(3); // Trusted
  });

  it("score drop to 480 with Enhanced KYA → level falls to 1 (Starter)", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);

    await program.methods
      .updateCreditScore(480)
      .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
      .signers([oracle])
      .rpc();

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.creditScore).to.equal(480);
    // score 480 < 500 with kya_tier=2 → can't reach Established, but ≥400 with kya_tier≥1 → Starter
    expect(profile.creditLevel).to.equal(1);
  });

  it("oracle score 750 + Institutional KYA (tier 3) → level 4 (Elite)", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);

    await program.methods
      .updateKya(3)
      .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
      .signers([oracle])
      .rpc();

    await program.methods
      .updateCreditScore(750)
      .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
      .signers([oracle])
      .rpc();

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.creditLevel).to.equal(4); // Elite
  });

  it("rejects credit score outside 200–850 range", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);
    try {
      await program.methods
        .updateCreditScore(900) // above max
        .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
        .signers([oracle])
        .rpc();
      expect.fail("should have thrown InvalidCreditScore");
    } catch (e: any) {
      expect(e.message).to.include("InvalidCreditScore");
    }
  });

  it("stranger cannot update credit score", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);
    try {
      await program.methods
        .updateCreditScore(500)
        .accounts({ config: configPda, profile: profilePda, authority: stranger.publicKey })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotOracle");
    } catch (e: any) {
      expect(e.message).to.include("NotOracle");
    }
  });

  // ── 5. Liquidation penalty ─────────────────────────────────────────────────

  it("liquidation drops score by 100 and recalculates level downward", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);
    const before = await program.account.agentProfile.fetch(profilePda);

    await program.methods
      .recordLiquidation()
      .accounts({
        config: configPda,
        profile: profilePda,
        walletProgramAuthority: walletProgram.publicKey,
      })
      .signers([walletProgram])
      .rpc();

    const after = await program.account.agentProfile.fetch(profilePda);
    expect(after.creditScore).to.equal(before.creditScore - 100);
    expect(after.liquidationCount).to.equal(before.liquidationCount + 1);
    // Score is now 650; with Institutional KYA still qualifies for Trusted (level 3)
    expect(after.creditLevel).to.equal(3);
  });

  it("score never drops below 200 regardless of liquidations", async () => {
    const profilePda = deriveProfile(agentB.publicKey, program.programId);

    // Set agent B to min score first
    await program.methods
      .updateCreditScore(210)
      .accounts({ config: configPda, profile: profilePda, authority: oracle.publicKey })
      .signers([oracle])
      .rpc();

    // Liquidate — should floor at 200
    await program.methods
      .recordLiquidation()
      .accounts({
        config: configPda,
        profile: profilePda,
        walletProgramAuthority: walletProgram.publicKey,
      })
      .signers([walletProgram])
      .rpc();

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.creditScore).to.equal(200); // floored at MIN
  });

  it("unauthorised caller cannot record liquidation", async () => {
    const profilePda = deriveProfile(agentA.publicKey, program.programId);
    try {
      await program.methods
        .recordLiquidation()
        .accounts({
          config: configPda,
          profile: profilePda,
          walletProgramAuthority: stranger.publicKey,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotWalletProgram");
    } catch (e: any) {
      expect(e.message).to.include("NotWalletProgram");
    }
  });

  // ── 6. Deactivate ─────────────────────────────────────────────────────────

  it("admin deactivates an agent — strips credit level", async () => {
    const profilePda = deriveProfile(agentB.publicKey, program.programId);

    await program.methods
      .deactivateAgent()
      .accounts({ config: configPda, profile: profilePda, admin: admin.publicKey })
      .rpc();

    const profile = await program.account.agentProfile.fetch(profilePda);
    expect(profile.isActive).to.be.false;
    expect(profile.creditLevel).to.equal(0);
  });
});
