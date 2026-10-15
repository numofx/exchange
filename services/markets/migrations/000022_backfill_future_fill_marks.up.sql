-- The marks of the future fills recorded before 000021, read from chain the way the matcher now reads
-- them (futures.Reader.MarkAtFill): the series' mark at the end of the fill's block, or the old mark
-- of the first MarkSet later in that block. Read 2026-10-15 from Base for USDC-cNGN-30NOV26
-- (FutureAsset 0xdcfa4ee0772647abd24e8592596b5fe4f001bc19, sub_id 1796047200), trades 427-442.
--
-- Each row is matched on its trade id, transaction and series and only where no mark is recorded, so
-- on any other database this changes nothing.
update trade_fills as tf
set mark_price = marks.mark_price
from (values
  (427, '0x9b2933623a65674d25a76782942f82c8ed13e0078e4466b8a818c48805aa6f08', '1381.878533970887258648'),
  (429, '0x247ccaf41791b194540b843c2b8f75c49b30dc0af8cb7f396d7272ad3229ab17', '1381.504545246972882398'),
  (430, '0xc68afa188e8deb5b0d63cb85f039ace829b950447f46eb0938630ec729950157', '1381.344581212262239468'),
  (431, '0x6cc8daade0e97110af1a5a2f5dadf9430318afa462eb723fac6d08620b304d9f', '1381.714986469089592237'),
  (432, '0x63ff6633e70c661ec5a6d8aa639c5181c9dc9ce96247cb3fac068ee23be427d7', '1382.264441537313791761'),
  (433, '0x9674c8931ca2c4f251d65b43f555707f6a694ee0a748697d4b5d35cbdcba476b', '1382.264441537313791761'),
  (434, '0xa97ac6ac95644175eced97a82a96a895ab6805611a7780da970cab25d7a401c4', '1381.41718156044809072'),
  (435, '0x84c7a0ee1640ebc751e0b178c3afd07362e395e402f8f99363fd8fd28843b350', '1381.41718156044809072'),
  (436, '0xb405ac8a35ce3951c4d9a5e3e4df6ce2a899874490a34dc1cce3882817ee9e93', '1381.41718156044809072'),
  (437, '0x92058a2541e3e77d55622f1dd1656206fdf65f851cc1dbfea5f5a851735fe0a7', '1381.41718156044809072'),
  (438, '0xa8856b5340af8256d09647924a748d728e4c0f5858cb92f67b3013ab668d4922', '1381.41718156044809072'),
  (439, '0x56239a4f66417223a91a7253a25f5fb065d1ee56190a528726342c399e31bfad', '1381.41718156044809072'),
  (440, '0xc38f1314395728baa9d5e623d52049e7755dd3526004943c93d413d3dfa728c0', '1381.41718156044809072'),
  (441, '0x12889c8e5f971b33a9e4a126ed32da5f761c4a44c15912d002bd3b5738eb10e4', '1381.41718156044809072'),
  (442, '0x9905dd7ea2c992e9f034d81a5bebb248528b68171e4a2ee0fd2f40c0ccc761ab', '1381.41718156044809072')
) as marks (trade_id, tx_hash, mark_price)
where tf.trade_id = marks.trade_id
  and lower(tf.tx_hash) = marks.tx_hash
  and lower(tf.asset_address) = '0xdcfa4ee0772647abd24e8592596b5fe4f001bc19'
  and tf.sub_id = 1796047200
  and tf.mark_price is null;
