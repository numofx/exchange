import { GetPublicKeyCommand, KMSClient, SignCommand } from '@aws-sdk/client-kms';
import {
  hashMessage,
  hashTypedData,
  keccak256,
  recoverPublicKey,
  serializeTransaction,
  type Hex,
  type LocalAccount,
} from 'viem';
import { publicKeyToAddress, toAccount } from 'viem/accounts';

/**
 * An executor account whose private key never enters this process.
 *
 * The key lives in AWS KMS as an ECC_SECG_P256K1 signing key; this asks KMS for a signature over a
 * digest and turns the answer into the R||S||V Ethereum expects. A raw PRIVATE_KEY in the task
 * definition is readable by anything that can read the task definition or the process's memory,
 * and this key settles every trade on the venue.
 *
 * Ported from the Go signer in numofx/market-maker (internal/exchange/kms_signer.go), which the
 * market maker already uses for its own key. The two departures are forced by viem: `signTransaction`
 * has to serialize the transaction here rather than hand back a digest signature, and `v` is
 * returned as 27/28 rather than 0/1.
 */
const SECP256K1_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const SECP256K1_HALF_N = SECP256K1_N >> 1n;

/** Bounds one Sign round trip; a hung KMS call would otherwise stall the whole serial send queue. */
const KMS_SIGN_TIMEOUT_MS = 5_000;

const OID_EC_PUBLIC_KEY = '1.2.840.10045.2.1';
const OID_SECP256K1 = '1.3.132.0.10';

export type KmsApi = Pick<KMSClient, 'send'>;

export async function createKmsAccount(keyId: string, client?: KmsApi): Promise<LocalAccount> {
  if (!keyId) {
    throw new Error('EXECUTOR_KMS_KEY_ID is required to build a KMS account');
  }
  const kms = client ?? new KMSClient({});

  // Fetched eagerly: the address is needed before anything is sent, and a key that is missing, the
  // wrong spec, or not permitted to the task role should stop the process at boot rather than at
  // the first settlement.
  const pub = await kms.send(new GetPublicKeyCommand({ KeyId: keyId }));
  if (pub.KeySpec && pub.KeySpec !== 'ECC_SECG_P256K1') {
    throw new Error(`kms key ${keyId} has spec ${pub.KeySpec}, want ECC_SECG_P256K1`);
  }
  if (pub.KeyUsage && pub.KeyUsage !== 'SIGN_VERIFY') {
    throw new Error(`kms key ${keyId} has usage ${pub.KeyUsage}, want SIGN_VERIFY`);
  }
  if (!pub.PublicKey) {
    throw new Error(`kms key ${keyId}: GetPublicKey returned no key material`);
  }
  const publicKey = secp256k1PointFromSpki(Buffer.from(pub.PublicKey));
  const address = publicKeyToAddress(`0x${publicKey.toString('hex')}` as Hex);

  async function signDigest(hash: Hex): Promise<Hex> {
    const digest = Buffer.from(hash.slice(2), 'hex');
    if (digest.length !== 32) {
      throw new Error(`hash is required to be exactly 32 bytes (${digest.length})`);
    }
    const out = await kms.send(
      new SignCommand({
        KeyId: keyId,
        Message: digest,
        MessageType: 'DIGEST',
        SigningAlgorithm: 'ECDSA_SHA_256',
      }),
      { requestTimeout: KMS_SIGN_TIMEOUT_MS },
    );
    if (!out.Signature) {
      throw new Error('kms Sign returned no signature');
    }
    return await ethereumSignatureFromDer(digest, Buffer.from(out.Signature), publicKey);
  }

  return toAccount({
    address,
    sign: ({ hash }) => signDigest(hash),
    signMessage: ({ message }) => signDigest(hashMessage(message)),
    signTypedData: (parameters) => signDigest(hashTypedData(parameters as never)),
    // viem wants a serialized signed transaction, not a digest signature, so the unsigned form is
    // serialized here, hashed, signed, and re-serialized with the signature attached.
    async signTransaction(transaction, options) {
      const serializer = options?.serializer ?? serializeTransaction;
      const unsigned = await serializer(transaction);
      const signature = await signDigest(keccak256(unsigned));
      const r = `0x${signature.slice(2, 66)}` as Hex;
      const s = `0x${signature.slice(66, 130)}` as Hex;
      const v = BigInt(`0x${signature.slice(130, 132)}`);
      return await serializer(transaction, { r, s, v, yParity: Number(v - 27n) });
    },
  }) as LocalAccount;
}

/**
 * Normalizes a DER (r, s) to low-s and appends the recovery id that makes it recover to publicKey.
 *
 * Two things KMS does not do:
 *   - low-s. About half of its signatures land in the upper half of the curve order, which EIP-2
 *     and OpenZeppelin's ECDSA.recover both reject — so a raw KMS signature would fail on-chain
 *     roughly half the time, intermittently, which is the worst way to fail.
 *   - v. DER carries only (r, s); the recovery id is found by trying both and keeping the one that
 *     recovers this key's own public key. If neither does, the signature is not ours.
 */
export async function ethereumSignatureFromDer(
  digest: Buffer,
  der: Buffer,
  publicKey: Buffer,
): Promise<Hex> {
  const { r, s } = parseDerSignature(der);
  if (r <= 0n || s <= 0n || r >= SECP256K1_N || s >= SECP256K1_N) {
    throw new Error('kms signature (r, s) out of range');
  }
  const normalized = s > SECP256K1_HALF_N ? SECP256K1_N - s : s;

  for (const parity of [0, 1] as const) {
    const candidate = `0x${r.toString(16).padStart(64, '0')}${normalized
      .toString(16)
      .padStart(64, '0')}${(parity + 27).toString(16).padStart(2, '0')}` as Hex;
    if (await recoversTo(digest, candidate, publicKey)) {
      return candidate;
    }
  }
  throw new Error('kms signature does not recover to the key\'s public key');
}

async function recoversTo(digest: Buffer, signature: Hex, publicKey: Buffer): Promise<boolean> {
  try {
    const recovered = await recoverPublicKey({
      hash: `0x${digest.toString('hex')}` as Hex,
      signature,
    });
    return recovered.toLowerCase() === `0x${publicKey.toString('hex')}`.toLowerCase();
  } catch {
    return false;
  }
}

/** Minimal DER: SEQUENCE { INTEGER r, INTEGER s }. */
function parseDerSignature(der: Buffer): { r: bigint; s: bigint } {
  let i = 0;
  if (der[i++] !== 0x30) throw new Error('parse kms signature: expected SEQUENCE');
  const seqLen = der[i++] as number;
  if (seqLen + 2 !== der.length) throw new Error('parse kms signature: bad length');
  const readInt = (): bigint => {
    if (der[i++] !== 0x02) throw new Error('parse kms signature: expected INTEGER');
    const len = der[i++] as number;
    const value = BigInt(`0x${der.subarray(i, i + len).toString('hex')}`);
    i += len;
    return value;
  };
  const r = readInt();
  const s = readInt();
  if (i !== der.length) throw new Error(`parse kms signature: ${der.length - i} trailing bytes`);
  return { r, s };
}

/**
 * Extracts the uncompressed point from the DER SubjectPublicKeyInfo KMS returns.
 *
 * Parsed by hand and with the curve OID checked explicitly: standard parsers refuse secp256k1 as an
 * unknown curve, and a P-256 key would otherwise parse into an address no signature can recover to.
 */
export function secp256k1PointFromSpki(der: Buffer): Buffer {
  let i = 0;
  if (der[i++] !== 0x30) throw new Error('parse SubjectPublicKeyInfo: expected SEQUENCE');
  i += lengthBytes(der, i).consumed;
  if (der[i++] !== 0x30) throw new Error('parse SubjectPublicKeyInfo: expected AlgorithmIdentifier');
  const alg = lengthBytes(der, i);
  i += alg.consumed;
  const algEnd = i + alg.length;
  const algorithm = readOid(der, i);
  if (algorithm.oid !== OID_EC_PUBLIC_KEY) {
    throw new Error(`public key algorithm ${algorithm.oid} is not ecPublicKey`);
  }
  const curve = readOid(der, algorithm.next);
  if (curve.oid !== OID_SECP256K1) {
    throw new Error(`curve ${curve.oid} is not secp256k1`);
  }
  i = algEnd;
  if (der[i++] !== 0x03) throw new Error('parse SubjectPublicKeyInfo: expected BIT STRING');
  const bits = lengthBytes(der, i);
  i += bits.consumed;
  if (der[i++] !== 0x00) throw new Error('parse SubjectPublicKeyInfo: unexpected unused bits');
  const point = der.subarray(i, i + bits.length - 1);
  if (point.length !== 65 || point[0] !== 0x04) {
    throw new Error(`public key is not an uncompressed secp256k1 point (${point.length} bytes)`);
  }
  return Buffer.from(point);
}

function lengthBytes(der: Buffer, offset: number): { length: number; consumed: number } {
  const first = der[offset] as number;
  if (first < 0x80) return { length: first, consumed: 1 };
  const count = first & 0x7f;
  let length = 0;
  for (let k = 1; k <= count; k++) length = (length << 8) | (der[offset + k] as number);
  return { length, consumed: count + 1 };
}

function readOid(der: Buffer, offset: number): { oid: string; next: number } {
  if (der[offset] !== 0x06) throw new Error('parse SubjectPublicKeyInfo: expected OBJECT IDENTIFIER');
  const len = der[offset + 1] as number;
  const body = der.subarray(offset + 2, offset + 2 + len);
  const first = body[0] as number;
  const parts = [Math.floor(first / 40), first % 40];
  let value = 0;
  for (const byte of body.subarray(1)) {
    value = (value << 7) | (byte & 0x7f);
    if ((byte & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return { oid: parts.join('.'), next: offset + 2 + len };
}
