import 'dotenv/config';

import { readFileSync } from 'node:fs';

import {
  createPublicClient,
  defineChain,
  encodeFunctionData,
  encodeAbiParameters,
  getAddress,
  http,
} from 'viem';
import { loadConfig, loadDeploymentAddresses } from '../dist/config.js';
import { loadContractArtifacts } from '../dist/contracts.js';

function buildVerifyAndMatchArgs(request) {
  const actions = request.actions.map((action) => ({
    subaccountId: BigInt(action.subaccount_id),
    nonce: BigInt(action.nonce),
    module: getAddress(action.module),
    data: action.data,
    expiry: BigInt(action.expiry),
    owner: getAddress(action.owner),
    signer: getAddress(action.signer),
  }));

  const signatures = request.signatures;
  const actionData = encodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          { name: 'takerAccount', type: 'uint256' },
          { name: 'takerFee', type: 'uint256' },
          {
            name: 'fillDetails',
            type: 'tuple[]',
            components: [
              { name: 'filledAccount', type: 'uint256' },
              { name: 'amountFilled', type: 'uint256' },
              { name: 'price', type: 'int256' },
              { name: 'fee', type: 'uint256' },
            ],
          },
          { name: 'managerData', type: 'bytes' },
        ],
      },
    ],
    [
      {
        takerAccount: BigInt(request.order_data.taker_account),
        takerFee: BigInt(request.order_data.taker_fee),
        fillDetails: request.order_data.fill_details.map((fill) => ({
          filledAccount: BigInt(fill.filled_account),
          amountFilled: BigInt(fill.amount_filled),
          price: BigInt(fill.price),
          fee: BigInt(fill.fee),
        })),
        managerData: request.order_data.manager_data,
      },
    ],
  );

  return [actions, signatures, actionData];
}

async function main() {
  const payloadPath = process.argv[2];
  if (!payloadPath) throw new Error('usage: node scripts/debug_execute_payload.mjs <payload.json>');

  const config = loadConfig();
  const deploymentAddresses = loadDeploymentAddresses(config.matchingRepoPath, config.chainId);
  const artifacts = loadContractArtifacts(config.matchingRepoPath);
  const matchingAddress = config.matchingAddress ?? deploymentAddresses.matching;

  const chain = defineChain({
    id: config.chainId,
    name: `chain-${config.chainId}`,
    nativeCurrency: { name: 'Native', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [config.rpcUrl] } },
  });

  const client = createPublicClient({ chain, transport: http(config.rpcUrl) });
  const payload = JSON.parse(readFileSync(payloadPath, 'utf8'));
  const args = buildVerifyAndMatchArgs(payload);

  try {
    if (process.env.TRACE === '1') {
      const data = encodeFunctionData({
        abi: artifacts.matchingAbi,
        functionName: 'verifyAndMatch',
        args,
      });

      const trace = await client.request({
        method: 'debug_traceCall',
        params: [
          {
            from: getAddress('0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310'),
            to: matchingAddress,
            data,
          },
          'latest',
          { tracer: 'callTracer' },
        ],
      });

      console.dir(trace, { depth: 10 });
      return;
    }

    await client.simulateContract({
      account: getAddress('0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310'),
      address: matchingAddress,
      abi: artifacts.matchingAbi,
      functionName: 'verifyAndMatch',
      args,
    });
    console.log(JSON.stringify({ ok: true }, null, 2));
  } catch (error) {
    const err = error;
    console.dir(
      {
        name: err?.name,
        message: err?.message,
        shortMessage: err?.shortMessage,
        details: err?.details,
        cause: err?.cause,
        walk: {
          data: err?.data,
          raw: err?.raw,
          metaMessages: err?.metaMessages,
        },
      },
      { depth: 8 },
    );
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
