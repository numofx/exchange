import { z } from 'zod';

const hexSchema = z.string().regex(/^0x[0-9a-fA-F]*$/, 'expected hex string');
const addressSchema = z.string().regex(/^0x[0-9a-fA-F]{40}$/, 'expected address');
const decimalStringSchema = z.string().regex(/^[0-9]+$/, 'expected unsigned decimal string');
const signedDecimalStringSchema = z.string().regex(/^-?[0-9]+$/, 'expected signed decimal string');

export const actionSchema = z.object({
  subaccount_id: decimalStringSchema,
  nonce: decimalStringSchema,
  module: addressSchema,
  data: hexSchema,
  expiry: decimalStringSchema,
  owner: addressSchema,
  signer: addressSchema,
});

export const fillDetailSchema = z.object({
  filled_account: decimalStringSchema,
  amount_filled: decimalStringSchema,
  price: signedDecimalStringSchema,
  fee: decimalStringSchema,
});

export const orderDataSchema = z.object({
  taker_account: decimalStringSchema,
  taker_fee: decimalStringSchema,
  fill_details: z.array(fillDetailSchema).min(1),
  manager_data: hexSchema,
});

export const executeMatchRequestSchema = z
  .object({
    market: z.string().min(1),
    asset_address: addressSchema,
    module_address: addressSchema,
    maker_order_id: z.string().min(1),
    taker_order_id: z.string().min(1),
    actions: z.array(actionSchema).min(2),
    signatures: z.array(hexSchema).min(2),
    order_data: orderDataSchema,
  })
  .superRefine((value, ctx) => {
    if (value.actions.length !== value.signatures.length) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'actions and signatures length must match',
        path: ['signatures'],
      });
    }

    if (value.actions[0]?.subaccount_id !== value.order_data.taker_account) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'actions[0].subaccount_id must match order_data.taker_account',
        path: ['order_data', 'taker_account'],
      });
    }

    for (const [index, action] of value.actions.entries()) {
      if (action.module.toLowerCase() !== value.module_address.toLowerCase()) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: 'every action.module must match module_address',
          path: ['actions', index, 'module'],
        });
      }
    }
  });

export type ExecuteMatchRequest = z.infer<typeof executeMatchRequestSchema>;

export type ExecuteMatchResponse = {
  accepted: true;
  tx_hash: `0x${string}` | 'dry-run';
  receipt_status?: 'success' | 'reverted';
  block_number?: string;
};
