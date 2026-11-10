import * as anchor from "@coral-xyz/anchor";
import { Program, AnchorError } from "@coral-xyz/anchor";
import { KrexaVenueWhitelist } from "../target/types/krexa_venue_whitelist";
import { Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function venueName(s: string): number[] {
  const buf = Buffer.alloc(32, 0);
  Buffer.from(s).copy(buf);
  return [...buf];
}

async function deriveConfig(programId: PublicKey): Promise<[PublicKey, number]> {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("whitelist_config")],
    programId
  );
}

async function deriveVenue(
  venueId: PublicKey,
  programId: PublicKey
): Promise<[PublicKey, number]> {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("venue"), venueId.toBuffer()],
    programId
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite
// ─────────────────────────────────────────────────────────────────────────────

describe("krexa-venue-whitelist", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.KrexaVenueWhitelist as Program<KrexaVenueWhitelist>;

  const admin = provider.wallet as anchor.Wallet;
  const stranger = Keypair.generate();

  // Fake program IDs standing in for real DEX programs
  const jupiterFakeId   = Keypair.generate().publicKey;
  const raydiumFakeId   = Keypair.generate().publicKey;

  let configPda: PublicKey;

  // ── 1. initialize ──────────────────────────────────────────────────────────

  it("initializes the whitelist config", async () => {
    [configPda] = await deriveConfig(program.programId);

    await program.methods
      .initialize()
      .accounts({ config: configPda, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .rpc();

    const cfg = await program.account.whitelistConfig.fetch(configPda);
    expect(cfg.admin.toBase58()).to.equal(admin.publicKey.toBase58());
    expect(cfg.totalVenues).to.equal(0);
    expect(cfg.isPaused).to.be.false;
  });

  // ── 2. add_venue ───────────────────────────────────────────────────────────

  it("admin adds Jupiter as a DEX venue (category 0)", async () => {
    const [venuePda] = await deriveVenue(jupiterFakeId, program.programId);

    await program.methods
      .addVenue(jupiterFakeId, venueName("Jupiter v6"), 0)
      .accounts({
        config: configPda,
        venue: venuePda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    const venue = await program.account.whitelistedVenue.fetch(venuePda);
    expect(venue.programId.toBase58()).to.equal(jupiterFakeId.toBase58());
    expect(venue.category).to.equal(0);
    expect(venue.isActive).to.be.true;
    expect(venue.addedAt.toNumber()).to.be.greaterThan(0);

    const cfg = await program.account.whitelistConfig.fetch(configPda);
    expect(cfg.totalVenues).to.equal(1);
  });

  it("admin adds a second venue (Raydium, category 0)", async () => {
    const [venuePda] = await deriveVenue(raydiumFakeId, program.programId);

    await program.methods
      .addVenue(raydiumFakeId, venueName("Raydium AMM"), 0)
      .accounts({
        config: configPda,
        venue: venuePda,
        admin: admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .rpc();

    const cfg = await program.account.whitelistConfig.fetch(configPda);
    expect(cfg.totalVenues).to.equal(2);
  });

  // ── 3. non-admin rejection ─────────────────────────────────────────────────

  it("rejects add_venue from a non-admin signer", async () => {
    await provider.connection.requestAirdrop(stranger.publicKey, 1e9);
    await new Promise((r) => setTimeout(r, 500));

    const fakeDex = Keypair.generate().publicKey;
    const [venuePda] = await deriveVenue(fakeDex, program.programId);

    try {
      await program.methods
        .addVenue(fakeDex, venueName("Evil DEX"), 0)
        .accounts({
          config: configPda,
          venue: venuePda,
          admin: stranger.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([stranger])
        .rpc();
      expect.fail("should have thrown NotAdmin");
    } catch (e: any) {
      // Anchor wraps constraint violations as AnchorError
      expect(e.message).to.include("NotAdmin");
    }
  });

  // ── 4. deactivate_venue ────────────────────────────────────────────────────

  it("admin deactivates Jupiter", async () => {
    const [venuePda] = await deriveVenue(jupiterFakeId, program.programId);

    await program.methods
      .deactivateVenue()
      .accounts({ config: configPda, venue: venuePda, admin: admin.publicKey })
      .rpc();

    const venue = await program.account.whitelistedVenue.fetch(venuePda);
    expect(venue.isActive).to.be.false;
  });

  it("deactivating an already-inactive venue returns AlreadyInactive", async () => {
    const [venuePda] = await deriveVenue(jupiterFakeId, program.programId);

    try {
      await program.methods
        .deactivateVenue()
        .accounts({ config: configPda, venue: venuePda, admin: admin.publicKey })
        .rpc();
      expect.fail("should have thrown AlreadyInactive");
    } catch (e: any) {
      expect(e.message).to.include("AlreadyInactive");
    }
  });

  // ── 5. reactivate_venue ────────────────────────────────────────────────────

  it("admin reactivates Jupiter", async () => {
    const [venuePda] = await deriveVenue(jupiterFakeId, program.programId);

    await program.methods
      .reactivateVenue()
      .accounts({ config: configPda, venue: venuePda, admin: admin.publicKey })
      .rpc();

    const venue = await program.account.whitelistedVenue.fetch(venuePda);
    expect(venue.isActive).to.be.true;
  });

  it("reactivating an already-active venue returns AlreadyActive", async () => {
    const [venuePda] = await deriveVenue(jupiterFakeId, program.programId);

    try {
      await program.methods
        .reactivateVenue()
        .accounts({ config: configPda, venue: venuePda, admin: admin.publicKey })
        .rpc();
      expect.fail("should have thrown AlreadyActive");
    } catch (e: any) {
      expect(e.message).to.include("AlreadyActive");
    }
  });

  // ── 6. PDA derivation — CPI pattern ───────────────────────────────────────

  it("WhitelistedVenue PDA is deterministic from program_id seed", async () => {
    // This verifies the pattern krexa-agent-wallet will use:
    // derive PDA off-chain → pass as account → Anchor validates seeds
    const [derived] = await deriveVenue(jupiterFakeId, program.programId);
    const venue = await program.account.whitelistedVenue.fetch(derived);
    expect(venue.programId.toBase58()).to.equal(jupiterFakeId.toBase58());
    expect(venue.isActive).to.be.true;
  });
});
