/**
 * Move cNGN from this signer into a venue subaccount — the last leg of the rebalance.
 *
 * The escrow takes the amount in TOKEN units (cNGN is 6dp) while SubAccounts reports balances in
 * 18dp, so the two numbers printed here differ by 1e12 by design.
 *
 * No whitelist and no owner check on this escrow: any wallet can deposit to any subaccount, which
 * is what lets this run without the market maker's key.
 */
import { formatUnits, type Hex } from 'viem';
import { waitFor, type Clients } from './clients.js';
import type { Config } from './config.js';
import { CNGN, CNGN_ESCROW, ERC20_ABI, ESCROW_ABI, LEDGER_DECIMALS, SUBACCOUNTS, SUBACCOUNTS_ABI, TOKEN_DECIMALS } from './venue.js';

export async function deposit(config: Config, clients: Clients, amountArg: bigint | undefined, execute: boolean): Promise<void> {
  const { account, publicClient, walletClient } = clients;
  const sub = config.MM_SUBACCOUNT_ID;

  const ledgerBalance = async (blockNumber?: bigint): Promise<bigint> => {
    const rows = await publicClient.readContract({
      address: SUBACCOUNTS, abi: SUBACCOUNTS_ABI, functionName: 'getAccountBalances',
      args: [sub], ...(blockNumber ? { blockNumber } : {}),
    });
    return rows.find((r) => r.asset.toLowerCase() === CNGN_ESCROW.toLowerCase())?.balance ?? 0n;
  };

  const [held, wrapped] = await Promise.all([
    publicClient.readContract({ address: CNGN, abi: ERC20_ABI, functionName: 'balanceOf', args: [account.address] }),
    publicClient.readContract({ address: CNGN_ESCROW, abi: ESCROW_ABI, functionName: 'wrappedAsset' }),
  ]);
  // A WrappedERC20Asset accepts only the exact token it wraps. Depositing the wrong one leaves
  // tokens with no ledger credit and no way to get them back, so this is checked every time
  // rather than trusted from the constant above.
  if ((wrapped as Hex).toLowerCase() !== CNGN.toLowerCase()) {
    throw new Error(`escrow ${CNGN_ESCROW} wraps ${String(wrapped)}, not ${CNGN}`);
  }

  // Default to the whole balance: this leg exists to leave nothing stranded on the signer.
  const amount = amountArg ?? held;
  const before = await ledgerBalance();
  console.log(`signer      ${account.address}`);
  console.log(`cNGN held   ${formatUnits(held, TOKEN_DECIMALS)}`);
  console.log(`depositing  ${formatUnits(amount, TOKEN_DECIMALS)} cNGN -> subaccount ${sub}`);
  console.log(`sub ${sub}      ${formatUnits(before, LEDGER_DECIMALS)} cNGN (18dp ledger)`);

  if (amount <= 0n) { console.log('nothing to deposit'); return; }
  if (amount > held) throw new Error(`holding ${formatUnits(held, TOKEN_DECIMALS)} cNGN, cannot deposit ${formatUnits(amount, TOKEN_DECIMALS)}`);

  if (!execute) {
    console.log(`\nwould send:\n  1. ${CNGN} approve(${CNGN_ESCROW}, ${amount})\n  2. ${CNGN_ESCROW} deposit(${sub}, ${amount})`);
    console.log('\n(dry run; pass --execute to send)');
    return;
  }

  const allowance = () => publicClient.readContract({ address: CNGN, abi: ERC20_ABI, functionName: 'allowance', args: [account.address, CNGN_ESCROW] });
  if ((await allowance()) < amount) {
    const hash = await walletClient.writeContract({ account, chain: walletClient.chain, address: CNGN, abi: ERC20_ABI, functionName: 'approve', args: [CNGN_ESCROW, amount] });
    console.log(`approve tx  ${hash}`);
    await publicClient.waitForTransactionReceipt({ hash });
    await waitFor(async () => (await allowance()) >= amount, { what: 'cNGN allowance' });
  }

  const { request } = await publicClient.simulateContract({ address: CNGN_ESCROW, abi: ESCROW_ABI, functionName: 'deposit', args: [sub, amount], account });
  const hash = await walletClient.writeContract(request);
  console.log(`deposit tx  ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`${receipt.status} in block ${receipt.blockNumber}`);

  // The deposit is done by this point; a read that cannot answer yet is not a failed deposit.
  try {
    await waitFor(async () => (await ledgerBalance(receipt.blockNumber)) > before, { what: 'ledger credit' });
    const after = await ledgerBalance(receipt.blockNumber);
    console.log(`sub ${sub}      ${formatUnits(before, LEDGER_DECIMALS)} -> ${formatUnits(after, LEDGER_DECIMALS)} cNGN (+${formatUnits(after - before, LEDGER_DECIMALS)})`);
  } catch {
    console.log(`deposit succeeded; subaccount ${sub} not readable back yet (replica lag) — check manually`);
  }
}
