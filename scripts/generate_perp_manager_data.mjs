import 'dotenv/config';

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import {
  createPublicClient,
  encodeAbiParameters,
  getAddress,
  http,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

function requireEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function envFlag(name, defaultValue = false) {
  const value = process.env[name];
  if (value == null) return defaultValue;
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

function resolveMarketDeployment() {
  const exchangeCoreRepoPath = process.env.EXCHANGE_CORE_REPO_PATH || '../exchange-core';
  const chainId = requireEnv('CHAIN_ID');
  const market = process.env.MARKET || 'BTC_SQUARED';
  const deploymentPath = path.resolve(process.cwd(), exchangeCoreRepoPath, 'deployments', chainId, `${market}.json`);
  if (!existsSync(deploymentPath)) throw new Error(`deployment file not found: ${deploymentPath}`);
  return JSON.parse(readFileSync(deploymentPath, 'utf8'));
}

async function main() {
  const rpcUrl = requireEnv('RPC_URL');
  const chainId = Number(requireEnv('CHAIN_ID'));
  const privateKey = process.env.SIGNER1_PRIVATE_KEY || requireEnv('PRIVATE_KEY');
  const account = privateKeyToAccount(privateKey);
  const deployment = resolveMarketDeployment();

  const spotFeedAddress = getAddress(process.env.SPOT_FEED_ADDRESS || deployment.spotFeed);
  const perpFeedAddress = getAddress(process.env.PERP_FEED_ADDRESS || deployment.perpFeed);
  const iapFeedAddress = getAddress(process.env.IAP_FEED_ADDRESS || deployment.iapFeed);
  const ibpFeedAddress = getAddress(process.env.IBP_FEED_ADDRESS || deployment.ibpFeed);
  const stableFeedAddress = getAddress(process.env.STABLE_FEED_ADDRESS || '0x27dBAeE4639C9c14248eC908f691B61cD6056Cbb');

  const client = createPublicClient({ transport: http(rpcUrl) });

  const latestBlock = await client.getBlock({ blockTag: 'latest' });
  const spotPrice = process.env.SPOT_PRICE
    ? BigInt(process.env.SPOT_PRICE)
    : (await client.readContract({
        address: spotFeedAddress,
        abi: [{
          type: 'function',
          name: 'getSpot',
          stateMutability: 'view',
          inputs: [],
          outputs: [{ type: 'uint256' }, { type: 'uint256' }],
        }],
        functionName: 'getSpot',
      }))[0];
  const perpPrice = BigInt(process.env.PERP_PRICE || spotPrice.toString());
  const stablePrice = BigInt(process.env.STABLE_PRICE || '1000000000000000000');
  const confidence = BigInt(process.env.CONFIDENCE || '1000000000000000000');
  const timestamp = BigInt(process.env.FEED_TIMESTAMP || latestBlock.timestamp.toString());
  const deadline = BigInt(process.env.FEED_DEADLINE || (latestBlock.timestamp + 300n).toString());
  const diff = perpPrice - spotPrice;

  const spotPayload = encodeAbiParameters(
    [{ type: 'uint96' }, { type: 'uint64' }],
    [spotPrice, confidence],
  );

  const diffPayload = encodeAbiParameters(
    [{ type: 'int96' }, { type: 'uint64' }],
    [diff, confidence],
  );
  const stablePayload = encodeAbiParameters(
    [{ type: 'uint96' }, { type: 'uint64' }],
    [stablePrice, confidence],
  );

  async function buildFeedUpdate(feedAddress, payload, domainName) {
    const signature = await account.signTypedData({
      domain: {
        name: domainName,
        version: '1',
        chainId,
        verifyingContract: feedAddress,
      },
      primaryType: 'FeedData',
      types: {
        FeedData: [
          { name: 'data', type: 'bytes' },
          { name: 'deadline', type: 'uint256' },
          { name: 'timestamp', type: 'uint64' },
        ],
      },
      message: {
        data: payload,
        deadline,
        timestamp,
      },
    });

    const feedData = encodeAbiParameters(
      [{
        type: 'tuple',
        components: [
          { name: 'data', type: 'bytes' },
          { name: 'deadline', type: 'uint256' },
          { name: 'timestamp', type: 'uint64' },
          { name: 'signers', type: 'address[]' },
          { name: 'signatures', type: 'bytes[]' },
        ],
      }],
      [{
        data: payload,
        deadline,
        timestamp,
        signers: [account.address],
        signatures: [signature],
      }],
    );

    return {
      receiver: feedAddress,
      data: feedData,
    };
  }

  const includeSpotFeed = envFlag('INCLUDE_SPOT_FEED', false);
  const includeStableFeed = envFlag('INCLUDE_STABLE_FEED', true);

  const managerEntries = await Promise.all([
    ...(includeSpotFeed ? [buildFeedUpdate(spotFeedAddress, spotPayload, 'LyraSpotFeed')] : []),
    buildFeedUpdate(perpFeedAddress, diffPayload, 'LyraSpotDiffFeed'),
    buildFeedUpdate(iapFeedAddress, diffPayload, 'LyraSpotDiffFeed'),
    buildFeedUpdate(ibpFeedAddress, diffPayload, 'LyraSpotDiffFeed'),
    ...(includeStableFeed ? [buildFeedUpdate(stableFeedAddress, stablePayload, 'LyraSpotFeed')] : []),
  ]);

  const managerData = encodeAbiParameters(
    [{
      type: 'tuple[]',
      components: [
        { name: 'receiver', type: 'address' },
        { name: 'data', type: 'bytes' },
      ],
    }],
    [managerEntries],
  );

  console.log(JSON.stringify({
    market: process.env.MARKET || 'BTC_SQUARED',
    spot_feed: spotFeedAddress,
    perp_feed: perpFeedAddress,
    iap_feed: iapFeedAddress,
    ibp_feed: ibpFeedAddress,
    stable_feed: stableFeedAddress,
    include_spot_feed: includeSpotFeed,
    include_stable_feed: includeStableFeed,
    signer: account.address,
    spot_price: spotPrice.toString(),
    perp_price: perpPrice.toString(),
    stable_price: stablePrice.toString(),
    diff: diff.toString(),
    confidence: confidence.toString(),
    timestamp: timestamp.toString(),
    deadline: deadline.toString(),
    manager_data: managerData,
  }, null, 2));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
