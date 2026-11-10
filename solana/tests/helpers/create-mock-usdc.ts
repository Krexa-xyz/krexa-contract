/**
 * create-mock-usdc.ts
 *
 * Creates a mock USDC SPL token mint for local / devnet testing.
 * Real mainnet USDC: EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
 *
 * Usage in tests:
 *   import { createMockUsdc, mintUsdc } from "./helpers/create-mock-usdc";
 *   const { mint, mintAuthority } = await createMockUsdc(provider);
 *   await mintUsdc(provider, mint, mintAuthority, recipientAta, 10_000);
 */

import * as anchor from "@coral-xyz/anchor";
import {
  Keypair,
  PublicKey,
} from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

export const USDC_DECIMALS = 6;
export const USDC_SCALE = 10 ** USDC_DECIMALS; // 1_000_000

/** Convert a dollar amount to USDC base units */
export function usdcAmount(dollars: number): bigint {
  return BigInt(Math.round(dollars * USDC_SCALE));
}

/** Convert USDC base units to a human-readable dollar string */
export function formatUsdc(baseUnits: bigint | number): string {
  const n = typeof baseUnits === "bigint" ? Number(baseUnits) : baseUnits;
  return `$${(n / USDC_SCALE).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock USDC factory
// ─────────────────────────────────────────────────────────────────────────────

export interface MockUsdc {
  /** The SPL token mint public key */
  mint: PublicKey;
  /** The keypair that holds mint authority */
  mintAuthority: Keypair;
  /** The keypair that holds freeze authority (same as mint authority) */
  freezeAuthority: Keypair;
}

/**
 * Creates a new mock USDC mint with 6 decimals on the given cluster.
 * The payer wallet is used to pay for account creation.
 */
export async function createMockUsdc(
  provider: anchor.AnchorProvider,
  mintAuthority?: Keypair
): Promise<MockUsdc> {
  const authority = mintAuthority ?? Keypair.generate();

  const mint = await createMint(
    provider.connection,
    // @ts-ignore — payer may not always be a Keypair type in wallet adapters
    provider.wallet.payer,
    authority.publicKey,   // mint authority
    authority.publicKey,   // freeze authority
    USDC_DECIMALS,
    undefined,
    undefined,
    TOKEN_PROGRAM_ID
  );

  console.log(
    `[MockUSDC] Created mock USDC mint: ${mint.toBase58()} (authority: ${authority.publicKey.toBase58().slice(0, 8)}…)`
  );

  return { mint, mintAuthority: authority, freezeAuthority: authority };
}

// ─────────────────────────────────────────────────────────────────────────────
// Minting helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Mint USDC to a wallet's ATA. Creates the ATA if it does not exist.
 * `amount` is in dollar units (e.g. 1000 = $1,000 USDC).
 */
export async function mintUsdc(
  provider: anchor.AnchorProvider,
  mock: MockUsdc,
  recipient: PublicKey,
  amountDollars: number
): Promise<PublicKey> {
  const ata = await getOrCreateAssociatedTokenAccount(
    provider.connection,
    // @ts-ignore
    provider.wallet.payer,
    mock.mint,
    recipient
  );

  await mintTo(
    provider.connection,
    // @ts-ignore
    provider.wallet.payer,
    mock.mint,
    ata.address,
    mock.mintAuthority,
    Number(usdcAmount(amountDollars))
  );

  console.log(
    `[MockUSDC] Minted ${formatUsdc(usdcAmount(amountDollars))} to ${recipient.toBase58().slice(0, 8)}… (ATA: ${ata.address.toBase58().slice(0, 8)}…)`
  );

  return ata.address;
}

/**
 * Get or create an ATA for `owner` on the mock USDC mint.
 */
export async function getOrCreateUsdcAta(
  provider: anchor.AnchorProvider,
  mock: MockUsdc,
  owner: PublicKey
): Promise<PublicKey> {
  const ata = await getOrCreateAssociatedTokenAccount(
    provider.connection,
    // @ts-ignore
    provider.wallet.payer,
    mock.mint,
    owner
  );
  return ata.address;
}

/**
 * Derive the ATA address without creating it.
 */
export function deriveUsdcAta(
  owner: PublicKey,
  mint: PublicKey
): PublicKey {
  return anchor.utils.token.associatedAddress({ mint, owner });
}

// ─────────────────────────────────────────────────────────────────────────────
// Test wallet factory
// ─────────────────────────────────────────────────────────────────────────────

export interface TestWallet {
  keypair: Keypair;
  usdcAta: PublicKey;
}

/**
 * Convenience: create N test wallets, airdrop SOL, and mint USDC to each.
 */
export async function createTestWallets(
  provider: anchor.AnchorProvider,
  mock: MockUsdc,
  count: number,
  solLamports = 2_000_000_000,
  usdcDollars = 10_000
): Promise<TestWallet[]> {
  const wallets: TestWallet[] = [];

  // Airdrop SOL to all wallets first
  const airdrops = Array.from({ length: count }, () => {
    const kp = Keypair.generate();
    return provider.connection
      .requestAirdrop(kp.publicKey, solLamports)
      .then((sig) =>
        provider.connection.confirmTransaction(sig).then(() => kp)
      );
  });

  const keypairs = await Promise.all(airdrops);

  // Mint USDC sequentially (avoids rate-limiting on localnet)
  for (const kp of keypairs) {
    const ata = await mintUsdc(provider, mock, kp.publicKey, usdcDollars);
    wallets.push({ keypair: kp, usdcAta: ata });
  }

  return wallets;
}
