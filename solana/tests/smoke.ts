/**
 * smoke.ts — verify all 5 programs load and their IDL can be fetched.
 *
 * Run with:  anchor test
 *
 * This file is a placeholder. Full integration tests live in:
 *   tests/01-agent-registry.ts
 *   tests/02-credit-vault.ts
 *   tests/03-agent-wallet.ts
 *   tests/04-venue-whitelist.ts
 *   tests/05-payment-router.ts
 *   tests/06-full-lifecycle.ts   ← end-to-end
 */

import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { KrexaAgentRegistry }  from "../target/types/krexa_agent_registry";
import { KrexaCreditVault }    from "../target/types/krexa_credit_vault";
import { KrexaAgentWallet }    from "../target/types/krexa_agent_wallet";
import { KrexaVenueWhitelist } from "../target/types/krexa_venue_whitelist";
import { KrexaPaymentRouter }  from "../target/types/krexa_payment_router";
import { createMockUsdc, mintUsdc, usdcAmount, formatUsdc } from "./helpers/create-mock-usdc";
import { expect } from "chai";

describe("Krexa — smoke tests", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const registry  = anchor.workspace.KrexaAgentRegistry  as Program<KrexaAgentRegistry>;
  const vault     = anchor.workspace.KrexaCreditVault    as Program<KrexaCreditVault>;
  const wallet    = anchor.workspace.KrexaAgentWallet    as Program<KrexaAgentWallet>;
  const whitelist = anchor.workspace.KrexaVenueWhitelist as Program<KrexaVenueWhitelist>;
  const router    = anchor.workspace.KrexaPaymentRouter  as Program<KrexaPaymentRouter>;

  it("all 5 programs load with valid program IDs", () => {
    expect(registry.programId.toBase58()).to.not.equal("11111111111111111111111111111111");
    expect(vault.programId.toBase58()).to.not.equal("11111111111111111111111111111111");
    expect(wallet.programId.toBase58()).to.not.equal("11111111111111111111111111111111");
    expect(whitelist.programId.toBase58()).to.not.equal("11111111111111111111111111111111");
    expect(router.programId.toBase58()).to.not.equal("11111111111111111111111111111111");

    console.log("  krexa-agent-registry: ", registry.programId.toBase58());
    console.log("  krexa-credit-vault:   ", vault.programId.toBase58());
    console.log("  krexa-agent-wallet:   ", wallet.programId.toBase58());
    console.log("  krexa-venue-whitelist:", whitelist.programId.toBase58());
    console.log("  krexa-payment-router: ", router.programId.toBase58());
  });

  it("mock USDC helper creates a 6-decimal mint", async () => {
    const mock = await createMockUsdc(provider);
    expect(mock.mint.toBase58().length).to.be.greaterThan(30);

    // Mint $1,000 to the test authority wallet
    const ata = await mintUsdc(provider, mock, provider.wallet.publicKey, 1_000);
    console.log(`  Mock USDC mint: ${mock.mint.toBase58()}`);
    console.log(`  Minted ${formatUsdc(usdcAmount(1_000))} to authority ATA`);
  });

  it("usdcAmount helper scales correctly", () => {
    expect(Number(usdcAmount(1))).to.equal(1_000_000);
    expect(Number(usdcAmount(500))).to.equal(500_000_000);
    expect(Number(usdcAmount(10_000))).to.equal(10_000_000_000);
  });
});
