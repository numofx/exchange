/**
 * Addresses and ABI fragments for the cNGN rebalance.
 *
 * Every address here was read back off Base rather than copied: the gateway's `host()` matches the
 * SDK's Base config, and the cNGN escrow's `wrappedAsset()` returns the cNGN token below. A
 * WrappedERC20Asset only ever accepts the exact ERC-20 it wraps, and depositing the wrong one
 * leaves tokens with no ledger credit and no way back, so that check is repeated at runtime.
 */
import type { Hex } from 'viem';

/** Hyperbridge IntentGateway on Base (ERC-1967 proxy). */
export const INTENT_GATEWAY = '0xAe041F7B0CB581876832830baeB6a2Aa2a3C9716' as const;
export const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as const;
export const CNGN = '0x46C85152bFe9f96829aA94755D9f915F9B10EF5F' as const;
/** WrappedERC20Asset escrow for cNGN — the venue's cNGN leg, and the spot market's asset_address. */
export const CNGN_ESCROW = '0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493' as const;
export const SUBACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843' as const;

/** Both tokens are 6dp on Base. SubAccounts reports balances in 18dp regardless. */
export const TOKEN_DECIMALS = 6;
export const LEDGER_DECIMALS = 18;

/** Hyperbridge state machine id for Base, ABI-encoded as the raw ASCII bytes the gateway stores. */
export const STATE_MACHINE_ID = 'EVM-8453';

export const ERC20_ABI = [
  { name: 'balanceOf', type: 'function', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'allowance', type: 'function', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'approve', type: 'function', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
] as const;

export const ESCROW_ABI = [
  { name: 'deposit', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'recipientAccount', type: 'uint256' }, { name: 'assetAmount', type: 'uint256' }], outputs: [] },
  { name: 'wrappedAsset', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const;

export const SUBACCOUNTS_ABI = [{
  name: 'getAccountBalances', type: 'function', stateMutability: 'view',
  inputs: [{ type: 'uint256' }],
  outputs: [{ type: 'tuple[]', components: [{ name: 'asset', type: 'address' }, { name: 'subId', type: 'uint256' }, { name: 'balance', type: 'int256' }] }],
}] as const;

/**
 * The `Order` tuple, matching `placeOrder`'s first parameter exactly.
 *
 * It has to match exactly, in field order and type, because the order commitment is
 * `keccak256(encodeAbiParameters([thisTuple], [order]))` — the same hash the gateway stores. A
 * struct that encodes differently produces a different commitment and cancels nothing.
 */
export const ORDER_TUPLE = {
  name: 'order', type: 'tuple', components: [
    { name: 'user', type: 'bytes32' },
    { name: 'source', type: 'bytes' },
    { name: 'destination', type: 'bytes' },
    { name: 'deadline', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'fees', type: 'uint256' },
    { name: 'session', type: 'address' },
    { name: 'predispatch', type: 'tuple', components: [
      { name: 'assets', type: 'tuple[]', components: [{ name: 'token', type: 'bytes32' }, { name: 'amount', type: 'uint256' }] },
      { name: 'call', type: 'bytes' }] },
    { name: 'inputs', type: 'tuple[]', components: [{ name: 'token', type: 'bytes32' }, { name: 'amount', type: 'uint256' }] },
    { name: 'output', type: 'tuple', components: [
      { name: 'beneficiary', type: 'bytes32' },
      { name: 'assets', type: 'tuple[]', components: [{ name: 'token', type: 'bytes32' }, { name: 'amount', type: 'uint256' }] },
      { name: 'call', type: 'bytes' }] },
  ],
} as const;

/** Second parameter of `cancelOrder`. Omitting it produces a one-argument call that reverts. */
export const CANCEL_OPTIONS_TUPLE = {
  name: 'options', type: 'tuple', components: [
    { name: 'relayerFee', type: 'uint256' },
    { name: 'height', type: 'uint64' },
  ],
} as const;

export const CANCEL_ORDER_ABI = [{
  type: 'function', name: 'cancelOrder', stateMutability: 'payable',
  inputs: [ORDER_TUPLE, CANCEL_OPTIONS_TUPLE], outputs: [],
}] as const;

export type TokenInfo = { token: Hex; amount: bigint };
export type Order = {
  user: Hex; source: Hex; destination: Hex;
  deadline: bigint; nonce: bigint; fees: bigint; session: Hex;
  predispatch: { assets: TokenInfo[]; call: Hex };
  inputs: TokenInfo[];
  output: { beneficiary: Hex; assets: TokenInfo[]; call: Hex };
};
