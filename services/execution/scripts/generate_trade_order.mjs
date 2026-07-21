import 'dotenv/config';

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import {
  encodeAbiParameters,
  formatUnits,
  getAddress,
  createPublicClient,
  http,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function envBigInt(name, fallback) {
  const value = process.env[name] ?? fallback;
  if (value == null) {
    throw new Error(`${name} is required`);
  }
  return BigInt(value);
}

function envString(name, fallback) {
  const value = process.env[name] ?? fallback;
  if (value == null || value === '') {
    throw new Error(`${name} is required`);
  }
  return value;
}

function resolveAddress(name, fallbackKey) {
  if (process.env[name]) {
    return getAddress(process.env[name]);
  }

  const repoPath = process.env.MATCHING_REPO_PATH;
  const chainId = process.env.CHAIN_ID;
  if (!repoPath || !chainId) {
    throw new Error(`${name} is required`);
  }

  const deploymentPath = path.resolve(process.cwd(), repoPath, 'deployments', chainId, 'matching.json');
  if (!existsSync(deploymentPath)) {
    throw new Error(`${name} is required and deployment file was not found at ${deploymentPath}`);
  }

  const deployment = JSON.parse(readFileSync(deploymentPath, 'utf8'));
  const value = deployment[fallbackKey];
  if (!value) {
    throw new Error(`${name} is required and ${fallbackKey} was not found in ${deploymentPath}`);
  }
  return getAddress(value);
}

async function main() {
  const rpcUrl = requireEnv('RPC_URL');
  const chainId = Number(requireEnv('CHAIN_ID'));
  const matchingAddress = resolveAddress('MATCHING_ADDRESS', 'matching');
  const tradeModuleAddress = resolveAddress('TRADE_MODULE_ADDRESS', 'trade');

  const ownerPrivateKey = process.env.OWNER_PRIVATE_KEY || requireEnv('PRIVATE_KEY');
  const signerPrivateKey = process.env.SIGNER_PRIVATE_KEY || ownerPrivateKey;

  const ownerAccount = privateKeyToAccount(ownerPrivateKey);
  const signerAccount = privateKeyToAccount(signerPrivateKey);

  const ownerAddress = getAddress(process.env.OWNER_ADDRESS || ownerAccount.address);
  const signerAddress = getAddress(process.env.SIGNER_ADDRESS || signerAccount.address);

  const orderId = envString('ORDER_ID', `order-${Date.now()}`);
  const subaccountId = envBigInt('SUBACCOUNT_ID');
  const recipientId = envBigInt('RECIPIENT_ID', String(subaccountId));
  const nonce = envBigInt('NONCE');
  const expiry = envBigInt('EXPIRY');

  const assetAddress = getAddress(requireEnv('ASSET_ADDRESS'));
  const subId = envBigInt('SUB_ID', '0');
  const limitPrice = envBigInt('LIMIT_PRICE');
  const desiredAmount = envBigInt('DESIRED_AMOUNT');
  const worstFee = envBigInt('WORST_FEE', '0');

  const side = envString('SIDE');
  const isBid = side.toLowerCase() === 'buy';
  if (!isBid && side.toLowerCase() !== 'sell') {
    throw new Error(`SIDE must be "buy" or "sell", got ${side}`);
  }

  const filledAmount = envString('FILLED_AMOUNT', '0');
  const assetSubId = process.env.BACKEND_SUB_ID || String(subId);

  const publicClient = createPublicClient({
    transport: http(rpcUrl),
  });

  const domainSeparator = await publicClient.readContract({
    address: matchingAddress,
    abi: [
      {
        type: 'function',
        name: 'domainSeparator',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ name: '', type: 'bytes32' }],
      },
    ],
    functionName: 'domainSeparator',
  });

  const actionData = encodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          { name: 'asset', type: 'address' },
          { name: 'subId', type: 'uint256' },
          { name: 'limitPrice', type: 'int256' },
          { name: 'desiredAmount', type: 'int256' },
          { name: 'worstFee', type: 'uint256' },
          { name: 'recipientId', type: 'uint256' },
          { name: 'isBid', type: 'bool' },
        ],
      },
    ],
    [
      {
        asset: assetAddress,
        subId,
        limitPrice,
        desiredAmount,
        worstFee,
        recipientId,
        isBid,
      },
    ],
  );

  const signature = await signerAccount.signTypedData({
    domain: {
      name: 'Matching',
      version: '1.0',
      chainId,
      verifyingContract: matchingAddress,
    },
    primaryType: 'Action',
    types: {
      Action: [
        { name: 'subaccountId', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'module', type: 'address' },
        { name: 'data', type: 'bytes' },
        { name: 'expiry', type: 'uint256' },
        { name: 'owner', type: 'address' },
        { name: 'signer', type: 'address' },
      ],
    },
    message: {
      subaccountId,
      nonce,
      module: tradeModuleAddress,
      data: actionData,
      expiry,
      owner: ownerAddress,
      signer: signerAddress,
    },
  });

  const payload = {
    order_id: orderId,
    owner_address: ownerAddress,
    signer_address: signerAddress,
    subaccount_id: subaccountId.toString(),
    recipient_id: recipientId.toString(),
    nonce: nonce.toString(),
    side: isBid ? 'buy' : 'sell',
    asset_address: assetAddress,
    sub_id: assetSubId,
    // The order body carries the HUMAN-DECIMAL contract amount; markets-service normalizes it to
    // atomic units (÷ MinSize for futures). The SIGNED action (action_json.data) keeps the raw
    // on-chain wei amount. DESIRED_AMOUNT / FILLED_AMOUNT are supplied in wei (1e18 per contract).
    desired_amount: formatUnits(desiredAmount, 18),
    filled_amount: filledAmount === '0' ? '0' : formatUnits(BigInt(filledAmount), 18),
    limit_price: limitPrice.toString(),
    worst_fee: worstFee.toString(),
    expiry: Number(expiry),
    action_json: {
      subaccount_id: subaccountId.toString(),
      nonce: nonce.toString(),
      module: tradeModuleAddress,
      data: actionData,
      expiry: expiry.toString(),
      owner: ownerAddress,
      signer: signerAddress,
    },
    signature,
    debug: {
      matching_address: matchingAddress,
      trade_module_address: tradeModuleAddress,
      domain_separator: domainSeparator,
      executor_expected_owner: ownerAddress,
      executor_expected_signer: signerAddress,
    },
  };

  console.log(JSON.stringify(payload, null, 2));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
