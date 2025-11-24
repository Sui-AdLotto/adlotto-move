#!/usr/bin/env tsx

import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { loadConfig } from "./config.js";
import {
  RANDOM_OBJECT_ID,
  CLOCK_OBJECT_ID,
  executeTransactionWithRetry,
  parseEvents,
  formatAddress,
  sleep,
} from "./utils.js";

const NETWORK = "testnet";
const MNEMONIC = process.env.MNEMONIC;
const INTERVAL_MINUTES = 60; // Run lottery every 5 minutes
const INTERVAL_MS = INTERVAL_MINUTES * 60 * 1000;

if (!MNEMONIC) {
  console.error("❌ MNEMONIC not found in environment variables");
  process.exit(1);
}

interface LotteryStats {
  totalRuns: number;
  successfulRuns: number;
  failedRuns: number;
  winnersPicked: number;
  epochsFinalized: number;
  lastRunTime: Date | null;
  lastError: string | null;
}

const stats: LotteryStats = {
  totalRuns: 0,
  successfulRuns: 0,
  failedRuns: 0,
  winnersPicked: 0,
  epochsFinalized: 0,
  lastRunTime: null,
  lastError: null,
};

/**
 * Print a beautiful header
 */
function printHeader(): void {
  console.clear();
  console.log("\n");
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log("║                                                              ║");
  console.log("║           🎰  ADLOTTO KEEPER BOT  🎰                        ║");
  console.log("║                                                              ║");
  console.log("║           Automated Lottery & Epoch Management               ║");
  console.log("║                                                              ║");
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("\n");
}

/**
 * Print statistics
 */
function printStats(): void {
  console.log("┌──────────────────────────────────────────────────────────────┐");
  console.log("│ 📊 STATISTICS                                                │");
  console.log("├──────────────────────────────────────────────────────────────┤");
  console.log(`│ Total Runs:        ${stats.totalRuns.toString().padStart(45)} │`);
  console.log(`│ Successful:        ${stats.successfulRuns.toString().padStart(45)} │`);
  console.log(`│ Failed:            ${stats.failedRuns.toString().padStart(45)} │`);
  console.log(`│ Winners Picked:    ${stats.winnersPicked.toString().padStart(45)} │`);
  console.log(`│ Epochs Finalized:  ${stats.epochsFinalized.toString().padStart(45)} │`);
  if (stats.lastRunTime) {
    const lastRun = stats.lastRunTime.toLocaleTimeString();
    console.log(`│ Last Run:          ${lastRun.padStart(45)} │`);
  }
  if (stats.lastError) {
    const errorMsg = stats.lastError.length > 45 
      ? stats.lastError.substring(0, 42) + "..." 
      : stats.lastError;
    console.log(`│ Last Error:        ${errorMsg.padStart(45)} │`);
  }
  console.log("└──────────────────────────────────────────────────────────────┘");
  console.log("\n");
}

/**
 * Print a countdown timer
 */
function printCountdown(seconds: number): void {
  const minutes = Math.floor(seconds / 60);
  const secs = seconds % 60;
  process.stdout.write(
    `\r⏳ Next run in: ${minutes.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}  `
  );
}

/**
 * Run a single lottery cycle
 */
async function runLotteryCycle(): Promise<void> {
  stats.totalRuns++;
  stats.lastRunTime = new Date();
  stats.lastError = null;

  console.log("\n");
  console.log("┌──────────────────────────────────────────────────────────────┐");
  console.log(`│ 🎲 LOTTERY CYCLE #${stats.totalRuns} - ${new Date().toLocaleString()}  │`);
  console.log("└──────────────────────────────────────────────────────────────┘");
  console.log("\n");

  // Load deployment configuration
  const config = loadConfig();
  if (!config) {
    throw new Error("Deployment config not found. Run `npm run deploy` first.");
  }

  console.log(`📦 Package: ${formatAddress(config.packageId)}`);
  console.log(`🌐 Network: ${config.network}\n`);

  // Initialize client
  const client = new SuiClient({ url: getFullnodeUrl(NETWORK) });

  // Admin keypair
  const adminKeypair = Ed25519Keypair.deriveKeypair(MNEMONIC as string);
  const adminAddress = adminKeypair.getPublicKey().toSuiAddress();

  console.log(`👤 Admin: ${formatAddress(adminAddress)}`);

  // Check admin balance
  const adminBalance = await client.getBalance({ owner: adminAddress });
  const balanceSui = Number(adminBalance.totalBalance) / 1_000_000_000;
  console.log(`💰 Balance: ${balanceSui.toFixed(4)} SUI\n`);

  if (balanceSui < 0.1) {
    console.log("⚠️  Warning: Low balance! Consider requesting from faucet.\n");
  }

  try {
    // Check current state first
    console.log("📋 Checking current lottery state...\n");

    const currentConfig = await client.getObject({
      id: config.lotteryConfigId,
      options: {
        showContent: true,
      },
    });

    if (
      !currentConfig.data?.content ||
      "fields" in currentConfig.data.content === false
    ) {
      throw new Error("Failed to fetch LotteryConfig");
    }

    const configFields = currentConfig.data.content.fields as any;
    const existingPendingWinnerId = configFields.pending_winner_id;
    const currentEpoch = configFields.current_epoch || 0;

    console.log(`📊 Current Epoch: ${currentEpoch}`);
    console.log(
      `🕐 Last Draw: ${new Date(Number(configFields.last_draw_time || 0)).toLocaleString()}\n`
    );

    // If there's a pending winner, finalize it first
    if (existingPendingWinnerId && existingPendingWinnerId !== null) {
      console.log("┌──────────────────────────────────────────────────────────────┐");
      console.log("│ ⚠️  PENDING WINNER DETECTED - FINALIZING EPOCH FIRST        │");
      console.log("└──────────────────────────────────────────────────────────────┘");
      console.log(`\n📌 Pending Winner: ${formatAddress(existingPendingWinnerId)}\n`);

      // Step 1: Rotate Verification Session (before finalizing)
      if (!config.verificationSessionId) {
        throw new Error("VerificationSession ID not found in config");
      }

      console.log("🔄 Step 1: Rotating verification session...");

      const rotateTx = new Transaction();
      rotateTx.moveCall({
        target: `${config.packageId}::verification::rotate_session`,
        arguments: [
          rotateTx.object(config.verificationSessionId),
          rotateTx.object(config.lotteryConfigId),
          rotateTx.object(config.treasuryId),
          rotateTx.object(RANDOM_OBJECT_ID),
        ],
      });

      const rotateResult = await executeTransactionWithRetry(
        client,
        adminKeypair,
        rotateTx
      );

      if (rotateResult.effects?.status?.status !== "success") {
        throw new Error(
          `Rotate session failed: ${rotateResult.effects?.status?.error}`
        );
      }

      console.log("   ✅ Session rotated!");
      console.log(`   📝 TX: ${formatAddress(rotateResult.digest)}\n`);

      // Parse SessionRotated event
      const sessionRotatedEvents = parseEvents(rotateResult, "SessionRotated");
      if (sessionRotatedEvents.length > 0) {
        const eventData = sessionRotatedEvents[0].parsedJson;
        console.log("   📊 Session Details:");
        console.log(`      Old Ad: ${formatAddress(eventData.old_ad_id)}`);
        console.log(`      New Ad: ${formatAddress(eventData.new_ad_id)}`);
        console.log(`      Viewers Paid: ${eventData.viewers_paid}\n`);
      }

      await sleep(2000);

      // Step 2: Finalize Epoch
      console.log("🏆 Step 2: Finalizing epoch...");

      const finalizeTx = new Transaction();
      finalizeTx.moveCall({
        target: `${config.packageId}::lottery::finalize_epoch`,
        arguments: [
          finalizeTx.object(config.lotteryConfigId),
          finalizeTx.object(existingPendingWinnerId),
          finalizeTx.object(CLOCK_OBJECT_ID),
        ],
      });

      const finalizeResult = await executeTransactionWithRetry(
        client,
        adminKeypair,
        finalizeTx
      );

      if (finalizeResult.effects?.status?.status !== "success") {
        throw new Error(
          `Finalize epoch failed: ${finalizeResult.effects?.status?.error}`
        );
      }

      console.log("   ✅ Epoch finalized!");
      console.log(`   📝 TX: ${formatAddress(finalizeResult.digest)}\n`);

      // Parse EpochFinalized event
      const epochFinalizedEvents = parseEvents(
        finalizeResult,
        "EpochFinalized"
      );
      if (epochFinalizedEvents.length > 0) {
        const eventData = epochFinalizedEvents[0].parsedJson;
        console.log("   🎉 Epoch Details:");
        console.log(`      Winner: ${formatAddress(eventData.winner_ad_id)}`);
        console.log(`      Epoch: ${eventData.epoch}\n`);
      }

      stats.epochsFinalized++;
      await sleep(2000);
    }

    // Step 1: Pick Winner
    console.log("┌──────────────────────────────────────────────────────────────┐");
    console.log("│ 🎯 STEP 1: PICKING WINNER                                     │");
    console.log("└──────────────────────────────────────────────────────────────┘");
    console.log("\n");

    const pickTx = new Transaction();
    pickTx.moveCall({
      target: `${config.packageId}::lottery::pick_winner`,
      arguments: [
        pickTx.object(config.lotteryConfigId),
        pickTx.object(config.adRegistryId),
        pickTx.object(RANDOM_OBJECT_ID),
        pickTx.object(CLOCK_OBJECT_ID),
      ],
    });

    const pickResult = await executeTransactionWithRetry(
      client,
      adminKeypair,
      pickTx
    );

    if (pickResult.effects?.status?.status !== "success") {
      throw new Error(
        `Pick winner failed: ${pickResult.effects?.status?.error}`
      );
    }

    console.log("   ✅ Winner picked successfully!");
    console.log(`   📝 TX: ${formatAddress(pickResult.digest)}\n`);

    // Parse WinnerPicked event
    const winnerPickedEvents = parseEvents(pickResult, "WinnerPicked");
    if (winnerPickedEvents.length > 0) {
      const eventData = winnerPickedEvents[0].parsedJson;
      console.log("   🏆 Winner Details:");
      console.log(`      Ad ID: ${formatAddress(eventData.winner_ad_id)}`);
      console.log(`      Epoch: ${eventData.epoch}`);
      console.log(
        `      Time: ${new Date(Number(eventData.timestamp)).toLocaleString()}\n`
      );
    }

    stats.winnersPicked++;
    await sleep(2000);

    // Get pending winner ID from config
    const updatedConfig = await client.getObject({
      id: config.lotteryConfigId,
      options: {
        showContent: true,
      },
    });

    if (
      !updatedConfig.data?.content ||
      "fields" in updatedConfig.data.content === false
    ) {
      throw new Error("Failed to fetch updated LotteryConfig");
    }

    const updatedConfigFields = updatedConfig.data.content.fields as any;
    const pendingWinnerId = updatedConfigFields.pending_winner_id;

    if (!pendingWinnerId || pendingWinnerId === null) {
      throw new Error("No pending winner found after pick_winner");
    }

    console.log(`📌 Pending Winner: ${formatAddress(pendingWinnerId)}\n`);

    // Step 2: Rotate Verification Session
    console.log("┌──────────────────────────────────────────────────────────────┐");
    console.log("│ 🔄 STEP 2: ROTATING VERIFICATION SESSION                     │");
    console.log("└──────────────────────────────────────────────────────────────┘");
    console.log("\n");

    if (!config.verificationSessionId) {
      throw new Error("VerificationSession ID not found in config");
    }

    const rotateTx2 = new Transaction();
    rotateTx2.moveCall({
      target: `${config.packageId}::verification::rotate_session`,
      arguments: [
        rotateTx2.object(config.verificationSessionId),
        rotateTx2.object(config.lotteryConfigId),
        rotateTx2.object(config.treasuryId),
        rotateTx2.object(RANDOM_OBJECT_ID),
      ],
    });

    const rotateResult2 = await executeTransactionWithRetry(
      client,
      adminKeypair,
      rotateTx2
    );

    if (rotateResult2.effects?.status?.status !== "success") {
      throw new Error(
        `Rotate session failed: ${rotateResult2.effects?.status?.error}`
      );
    }

    console.log("   ✅ Session rotated successfully!");
    console.log(`   📝 TX: ${formatAddress(rotateResult2.digest)}\n`);

    // Parse SessionRotated event
    const sessionRotatedEvents2 = parseEvents(rotateResult2, "SessionRotated");
    if (sessionRotatedEvents2.length > 0) {
      const eventData = sessionRotatedEvents2[0].parsedJson;
      console.log("   📊 Session Details:");
      console.log(`      Old Ad: ${formatAddress(eventData.old_ad_id)}`);
      console.log(`      New Ad: ${formatAddress(eventData.new_ad_id)}`);
      console.log(`      Viewers Paid: ${eventData.viewers_paid}\n`);
    }

    await sleep(2000);

    // Step 3: Finalize Epoch
    console.log("┌──────────────────────────────────────────────────────────────┐");
    console.log("│ 🏁 STEP 3: FINALIZING EPOCH                                  │");
    console.log("└──────────────────────────────────────────────────────────────┘");
    console.log("\n");

    const finalizeTx2 = new Transaction();
    finalizeTx2.moveCall({
      target: `${config.packageId}::lottery::finalize_epoch`,
      arguments: [
        finalizeTx2.object(config.lotteryConfigId),
        finalizeTx2.object(pendingWinnerId),
        finalizeTx2.object(CLOCK_OBJECT_ID),
      ],
    });

    const finalizeResult2 = await executeTransactionWithRetry(
      client,
      adminKeypair,
      finalizeTx2
    );

    if (finalizeResult2.effects?.status?.status !== "success") {
      throw new Error(
        `Finalize epoch failed: ${finalizeResult2.effects?.status?.error}`
      );
    }

    console.log("   ✅ Epoch finalized successfully!");
    console.log(`   📝 TX: ${formatAddress(finalizeResult2.digest)}\n`);

    // Parse EpochFinalized event
    const epochFinalizedEvents2 = parseEvents(
      finalizeResult2,
      "EpochFinalized"
    );
    if (epochFinalizedEvents2.length > 0) {
      const eventData = epochFinalizedEvents2[0].parsedJson;
      console.log("   🎉 Epoch Details:");
      console.log(`      Winner: ${formatAddress(eventData.winner_ad_id)}`);
      console.log(`      Epoch: ${eventData.epoch}\n`);
    }

    stats.epochsFinalized++;
    await sleep(2000);

    // Get final config state
    const finalConfig = await client.getObject({
      id: config.lotteryConfigId,
      options: {
        showContent: true,
      },
    });

    if (finalConfig.data?.content && "fields" in finalConfig.data.content) {
      const finalFields = finalConfig.data.content.fields as any;
      console.log("┌──────────────────────────────────────────────────────────────┐");
      console.log("│ 📊 FINAL STATE                                               │");
      console.log("├──────────────────────────────────────────────────────────────┤");
      console.log(`│ Current Epoch:     ${finalFields.current_epoch.toString().padStart(45)} │`);
      console.log(
        `│ Last Draw Time:     ${new Date(Number(finalFields.last_draw_time)).toLocaleString().padStart(45)} │`
      );
      console.log("└──────────────────────────────────────────────────────────────┘");
      console.log("\n");
    }

    console.log("┌──────────────────────────────────────────────────────────────┐");
    console.log("│ 🔗 TRANSACTION LINKS                                          │");
    console.log("├──────────────────────────────────────────────────────────────┤");
    console.log(
      `│ Pick Winner:        https://testnet.suivision.xyz/txblock/${pickResult.digest} │`
    );
    console.log(
      `│ Rotate Session:     https://testnet.suivision.xyz/txblock/${rotateResult2.digest} │`
    );
    console.log(
      `│ Finalize Epoch:     https://testnet.suivision.xyz/txblock/${finalizeResult2.digest} │`
    );
    console.log("└──────────────────────────────────────────────────────────────┘");
    console.log("\n");

    stats.successfulRuns++;
    console.log("✅ Lottery cycle completed successfully!\n");
  } catch (error: any) {
    stats.failedRuns++;
    stats.lastError = error.message || String(error);

    console.log("\n");
    console.log("┌──────────────────────────────────────────────────────────────┐");
    console.log("│ ❌ ERROR OCCURRED                                             │");
    console.log("└──────────────────────────────────────────────────────────────┘");
    console.log(`\n${error.message || error}\n`);

    if (error.message?.includes("EWinnerAlreadyPicked")) {
      console.log("💡 A winner has already been picked. This is normal if the bot");
      console.log("   is running multiple instances or was recently executed.\n");
    } else if (error.message?.includes("ENoPendingWinner")) {
      console.log("💡 No pending winner found. This may happen if the epoch was");
      console.log("   already finalized.\n");
    } else if (error.message?.includes("EWrongWinnerObject")) {
      console.log("💡 The winner object doesn't match. This should not happen");
      console.log("   in normal operation.\n");
    } else if (error.message?.includes("ENoActiveAds")) {
      console.log("💡 No active ads found. Submit some ads first.\n");
    }
  }
}

/**
 * Main keeper bot loop
 */
async function main(): Promise<void> {
  printHeader();

  console.log("🚀 Starting keeper bot...\n");
  console.log(`⏰ Interval: ${INTERVAL_MINUTES} minutes\n`);
  console.log("Press Ctrl+C to stop\n");

  // Run immediately on start
  await runLotteryCycle();
  printStats();

  // Then run on interval
  let countdown = INTERVAL_MS / 1000;

  while (true) {
    for (let i = countdown; i > 0; i--) {
      printCountdown(i);
      await sleep(1000);
    }

    console.log("\n");
    await runLotteryCycle();
    printStats();
    countdown = INTERVAL_MS / 1000;
  }
}

// Handle graceful shutdown
process.on("SIGINT", () => {
  console.log("\n\n");
  console.log("┌──────────────────────────────────────────────────────────────┐");
  console.log("│ 🛑 SHUTTING DOWN KEEPER BOT                                   │");
  console.log("└──────────────────────────────────────────────────────────────┘");
  console.log("\n");
  printStats();
  console.log("👋 Goodbye!\n");
  process.exit(0);
});

main().catch((error) => {
  console.error("❌ Fatal error:", error);
  process.exit(1);
});

