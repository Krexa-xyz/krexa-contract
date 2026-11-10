// Anchor migrations — runs once on `anchor migrate`.
// Bootstraps all five Krexa programs in the correct dependency order.

const anchor = require("@coral-xyz/anchor");

module.exports = async function (provider: any) {
  anchor.setProvider(provider);

  console.log("Deploying Krexa Solana programs…");
  console.log("Cluster:", provider.connection.rpcEndpoint);
  console.log("Authority:", provider.wallet.publicKey.toBase58());

  // Programs must be initialized in dependency order:
  //   1. krexa-venue-whitelist  (no deps)
  //   2. krexa-agent-registry   (no deps)
  //   3. krexa-credit-vault     (no deps)
  //   4. krexa-agent-wallet     (deps: 1, 2, 3)
  //   5. krexa-payment-router   (deps: 1, 4)

  // TODO: add initialize() calls for each program after deploying.
  // Example:
  //   const registry = anchor.workspace.KrexaAgentRegistry;
  //   await registry.methods.initialize(...).accounts({ ... }).rpc();

  console.log("Migration placeholder — add initialize() calls per program.");
};
