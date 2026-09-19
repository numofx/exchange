import { getAddress } from 'viem';

/**
 * Every action this executor submits must be signed by the account's own owner.
 *
 * On-chain, `ActionVerifier._verifySignerPermission` already allows `signer != owner` when
 * `sessionKeys[signer][owner] >= block.timestamp`. That registry is live on the deployed Matching
 * (`registerSessionKey`/`deregisterSessionKey` are in its runtime bytecode) and **no session key has
 * ever been registered** — `SessionKeyRegistered` has zero logs across the contract's whole history.
 * So today the chain rejects a non-owner signer for us, and this guard is a no-op: an action with
 * `signer != owner` would revert in `verifyAndMatch` anyway. It refuses earlier, for free, instead
 * of paying gas to discover it.
 *
 * It exists because that is an accident of configuration, not a property of this service. The
 * moment any owner registers a session key, actions signed by it become chain-valid on EVERY module
 * this executor can reach — trade, rfq, transfer, liquidate, deposit, withdrawal — and nothing here
 * would have objected. `assertWithdrawalPolicy` covers only withdrawals, and the settlement path's
 * own signer check (`assertPayloadConsistency`) is conditional on `EXPECTED_ACTION_SIGNER`, which is
 * set nowhere in `infra/`. So the settlement path has never checked this at all.
 *
 * Deliberately absolute: no allowlist, no per-module exception, no config escape. Relaxing it for a
 * specific delegated signer is a separate, reviewable change — the point of this one is that the
 * relaxation has to be deliberate rather than discovered.
 *
 * This binds the service, not the key. Anything else holding `kms:Sign` on the executor key can call
 * `Matching.verifyAndMatch` (or `AtomicSigningExecutor`) directly and never pass through here.
 */

/** The fields of a built action this guard reads. Both builders produce checksummed addresses. */
export type SubmittedAction = {
  subaccountId: bigint;
  module: `0x${string}`;
  owner: `0x${string}`;
  signer: `0x${string}`;
};

/** Distinct from WithdrawalRejectedError: this refuses a submission on any path, not just a withdrawal. */
export class SignerNotOwnerError extends Error {
  constructor(
    readonly index: number,
    readonly owner: `0x${string}`,
    readonly signer: `0x${string}`,
    readonly module: `0x${string}`,
  ) {
    super(
      `actions[${index}] is signed by ${signer} for owner ${owner} on module ${module}: ` +
        'this executor submits only owner-signed actions',
    );
    this.name = 'SignerNotOwnerError';
  }
}

export type GuardLog = (level: 'info' | 'error', message: string, fields: Record<string, unknown>) => void;

/** Same shape index.ts gives the canary, so a refusal is one JSON line in the task's logs. */
const defaultLog: GuardLog = (level, message, fields) => {
  process.stdout.write(`${JSON.stringify({ level, msg: message, ...fields })}\n`);
};

/**
 * @throws SignerNotOwnerError on the first action whose signer is not its owner.
 */
export function assertSignerIsOwner(actions: readonly SubmittedAction[], log: GuardLog = defaultLog): void {
  for (const [index, action] of actions.entries()) {
    const owner = getAddress(action.owner);
    const signer = getAddress(action.signer);
    if (owner === signer) continue;

    const module = getAddress(action.module);
    log('error', 'action_signer_not_owner', {
      index,
      owner,
      signer,
      module,
      subaccount_id: action.subaccountId.toString(),
    });
    throw new SignerNotOwnerError(index, owner, signer, module);
  }
}
