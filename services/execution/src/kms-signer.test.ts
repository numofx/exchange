import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';

import { recoverAddress, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { secp256k1 } from '@noble/curves/secp256k1';

import { createKmsAccount, ethereumSignatureFromDer, secp256k1PointFromSpki } from './kms-signer.js';

/** A known key, so the address the signer derives can be checked against one computed independently. */
const PRIVATE_KEY = `0x${'11'.repeat(32)}` as const;
const EXPECTED = privateKeyToAccount(PRIVATE_KEY);
const PUBLIC_KEY = Buffer.from(secp256k1.getPublicKey(PRIVATE_KEY.slice(2), false));

/** KMS returns the public key as a DER SubjectPublicKeyInfo; this is that wrapper. */
function spki(point: Buffer): Buffer {
  const algorithm = Buffer.from('301006072a8648ce3d020106052b8104000a', 'hex');
  const bitString = Buffer.concat([Buffer.from([0x03, point.length + 1, 0x00]), point]);
  const body = Buffer.concat([algorithm, bitString]);
  return Buffer.concat([Buffer.from([0x30, body.length]), body]);
}

function der(r: bigint, s: bigint): Buffer {
  const int = (v: bigint) => {
    let bytes = Buffer.from(v.toString(16).padStart(64, '0'), 'hex');
    if (bytes[0]! > 0x7f) bytes = Buffer.concat([Buffer.from([0x00]), bytes]);
    return Buffer.concat([Buffer.from([0x02, bytes.length]), bytes]);
  };
  const body = Buffer.concat([int(r), int(s)]);
  return Buffer.concat([Buffer.from([0x30, body.length]), body]);
}

function fakeKms(point: Buffer) {
  return {
    async send(command: { constructor: { name: string }; input: Record<string, unknown> }) {
      if (command.constructor.name === 'GetPublicKeyCommand') {
        return { PublicKey: point, KeySpec: 'ECC_SECG_P256K1', KeyUsage: 'SIGN_VERIFY' };
      }
      const digest = command.input.Message as Buffer;
      const sig = secp256k1.sign(digest, PRIVATE_KEY.slice(2), { lowS: false });
      return { Signature: der(sig.r, sig.s) };
    },
  } as never;
}

test('the address comes from the KMS public key, not from any local key', async () => {
  const account = await createKmsAccount('alias/test', fakeKms(spki(PUBLIC_KEY)));
  assert.equal(account.address, EXPECTED.address);
});

test('a signature over a digest recovers to the KMS address', async () => {
  const account = await createKmsAccount('alias/test', fakeKms(spki(PUBLIC_KEY)));
  const hash = `0x${createHash('sha256').update('numo').digest('hex')}` as Hex;

  const signature = await account.sign!({ hash });
  assert.equal(await recoverAddress({ hash, signature }), EXPECTED.address);
});

// KMS returns whichever s the math produced. EIP-2 and OpenZeppelin's ECDSA.recover both reject the
// upper half of the curve order, so a raw KMS signature would fail on-chain about half the time --
// intermittently, which is the worst way to fail.
test('a high-s signature is normalised to low-s and still recovers', async () => {
  const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
  const halfN = N >> 1n;
  const digest = createHash('sha256').update('high-s').digest();
  const low = secp256k1.sign(digest, PRIVATE_KEY.slice(2), { lowS: true });
  const highS = N - low.s;
  assert.ok(highS > halfN, 'the fixture must actually be high-s');

  const signature = await ethereumSignatureFromDer(digest, der(low.r, highS), PUBLIC_KEY);

  const s = BigInt(`0x${signature.slice(66, 130)}`);
  assert.ok(s <= halfN, `s must be normalised into the lower half, got ${s}`);
  assert.equal(
    await recoverAddress({ hash: `0x${digest.toString('hex')}` as Hex, signature }),
    EXPECTED.address,
  );
});

test('a signature from a different key is refused rather than returned with a wrong v', async () => {
  const digest = createHash('sha256').update('other').digest();
  const other = secp256k1.sign(digest, `0x${'22'.repeat(32)}`.slice(2), { lowS: true });

  await assert.rejects(
    () => ethereumSignatureFromDer(digest, der(other.r, other.s), PUBLIC_KEY),
    /does not recover/,
  );
});

// A P-256 key would otherwise parse into an address that no signature can ever recover to.
test('a key on the wrong curve is refused', () => {
  const p256 = Buffer.from('301306072a8648ce3d020106082a8648ce3d030107', 'hex');
  const point = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 1)]);
  const bitString = Buffer.concat([Buffer.from([0x03, point.length + 1, 0x00]), point]);
  const body = Buffer.concat([p256, bitString]);
  const wrongCurve = Buffer.concat([Buffer.from([0x30, body.length]), body]);

  assert.throws(() => secp256k1PointFromSpki(wrongCurve), /is not secp256k1/);
});

test('a key with the wrong KMS spec is refused at construction', async () => {
  const kms = {
    async send() {
      return { PublicKey: spki(PUBLIC_KEY), KeySpec: 'ECC_NIST_P256', KeyUsage: 'SIGN_VERIFY' };
    },
  } as never;

  await assert.rejects(() => createKmsAccount('alias/test', kms), /want ECC_SECG_P256K1/);
});
