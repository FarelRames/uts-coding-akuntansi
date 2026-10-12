-- =====================================================================
-- UJI OTOMATIS Soal 1-3. Jalankan sekali setelah 01, 02, 04.
-- Tiap skenario dijalankan dalam sub-transaksi; yang gagal di-rollback
-- dan pesan error-nya dicatat. Output: tabel hasil_uji.
-- =====================================================================

CREATE OR REPLACE FUNCTION pg_temp.uji(p_sql TEXT)
RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;   -- paksa cek trigger DEFERRED sekarang
    SET CONSTRAINTS ALL DEFERRED;
    RETURN 'LOLOS';
EXCEPTION WHEN OTHERS THEN
    RETURN 'DITOLAK: ' || SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.acc(p_code TEXT)
RETURNS INT LANGUAGE sql AS $$
    SELECT account_id FROM chart_of_accounts WHERE account_code = p_code
$$;

DROP TABLE IF EXISTS hasil_uji;
CREATE TEMP TABLE hasil_uji (no SERIAL, kode TEXT, skenario TEXT, ekspektasi TEXT, hasil TEXT);

-- ---------------------------- SOAL 1 ----------------------------------
INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-1',
 'Jurnal seimbang (setoran modal Rp50 jt)', 'LOLOS', pg_temp.uji($q$
  WITH h AS (INSERT INTO journal_headers (trx_date, ref_no, description)
             VALUES ('2026-10-01', 'JU-0001', 'Setoran modal awal pemilik') RETURNING header_id)
  INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT h.header_id, pg_temp.acc(v.c), v.d, v.k FROM h,
         (VALUES ('1102', 50000000, 0), ('3101', 0, 50000000)) v(c, d, k) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-2',
 'Posting jurnal JU-0001', 'LOLOS', pg_temp.uji($q$
  UPDATE journal_headers SET posting_status = 'POSTED' WHERE ref_no = 'JU-0001' $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-3',
 'Jurnal tidak seimbang dikirim langsung (Dr 1 jt, Cr 900 rb)', 'DITOLAK', pg_temp.uji($q$
  WITH h AS (INSERT INTO journal_headers (trx_date, ref_no, description)
             VALUES ('2026-10-02', 'JU-0002', 'Bayar listrik - tidak seimbang') RETURNING header_id)
  INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT h.header_id, pg_temp.acc(v.c), v.d, v.k FROM h,
         (VALUES ('5202', 1000000, 0), ('1102', 0, 900000)) v(c, d, k) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-4',
 'Baris dengan debit negatif', 'DITOLAK', pg_temp.uji($q$
  WITH h AS (INSERT INTO journal_headers (trx_date, ref_no, description)
             VALUES ('2026-10-02', 'JU-0006', 'Debit negatif') RETURNING header_id)
  INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT header_id, pg_temp.acc('5202'), -500, 0 FROM h $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-5',
 'Baris dengan debit = 0 dan kredit = 0', 'DITOLAK', pg_temp.uji($q$
  WITH h AS (INSERT INTO journal_headers (trx_date, ref_no, description)
             VALUES ('2026-10-02', 'JU-0003', 'Baris nol') RETURNING header_id)
  INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT header_id, pg_temp.acc('5202'), 0, 0 FROM h $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-6',
 'Satu baris berisi debit dan kredit sekaligus', 'DITOLAK', pg_temp.uji($q$
  WITH h AS (INSERT INTO journal_headers (trx_date, ref_no, description)
             VALUES ('2026-10-02', 'JU-0004', 'Dua sisi') RETURNING header_id)
  INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT header_id, pg_temp.acc('5202'), 100, 100 FROM h $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-7',
 'Hapus akun COA yang sudah dipakai jurnal (ON DELETE RESTRICT)', 'DITOLAK', pg_temp.uji($q$
  DELETE FROM chart_of_accounts WHERE account_code = '1102' $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S1-8',
 'Header langsung dibuat POSTED tanpa baris', 'DITOLAK', pg_temp.uji($q$
  INSERT INTO journal_headers (trx_date, ref_no, description, posting_status)
  VALUES ('2026-10-02', 'JU-0005', 'Langsung posted', 'POSTED') $q$);

-- ---------------------------- SOAL 2 ----------------------------------
INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-1',
 'PURCHASE BRG-001 qty 10', 'LOLOS', pg_temp.uji($q$
  INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'PURCHASE', 10) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-2',
 'PURCHASE BRG-002 qty 5', 'LOLOS', pg_temp.uji($q$
  INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-002', 'PURCHASE', 5) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-3',
 'SALE BRG-001 qty 4 (stok 10)', 'LOLOS', pg_temp.uji($q$
  INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 4) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-4',
 'SALE BRG-001 qty 7 (stok 6) -> negatif', 'DITOLAK', pg_temp.uji($q$
  INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 7) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-5',
 'ADJUSTMENT BRG-001 qty -1 (barang rusak)', 'LOLOS', pg_temp.uji($q$
  INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'ADJUSTMENT', -1) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-6',
 'SALE dengan qty 0', 'DITOLAK', pg_temp.uji($q$
  INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 0) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-7',
 'Stok akhir BRG-001 = 10 - 4 - 1', 'stok=5',
 'stok=' || stock_qty FROM inventory_items WHERE item_id = 'BRG-001';

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S2-8',
 'Rekonsiliasi nilai fisik gudang = saldo akun Persediaan', 'SAMA',
 CASE WHEN nilai_fisik_gudang = saldo_buku_persediaan THEN 'SAMA' ELSE 'SELISIH' END
 || ' (fisik ' || nilai_fisik_gudang || ' / buku ' || saldo_buku_persediaan || ')'
 FROM v_inventory_reconciliation;

-- ---------------------------- SOAL 3 ----------------------------------
INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-1',
 'RPC voucher kas keluar seimbang (bayar listrik)', 'LOLOS', pg_temp.uji($q$
  SELECT post_cash_voucher('2026-10-05', 'BKK-0001', 'Pembayaran listrik & air September',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acc('5202'), 'debit', 1250000, 'credit', 0),
      jsonb_build_object('account_id', pg_temp.acc('1102'), 'debit', 0, 'credit', 1250000)),
    'Farel (uji)') $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-2',
 'RPC voucher tidak seimbang', 'DITOLAK', pg_temp.uji($q$
  SELECT post_cash_voucher('2026-10-05', 'BKK-0002', 'Tidak seimbang',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acc('5203'), 'debit', 500000, 'credit', 0),
      jsonb_build_object('account_id', pg_temp.acc('1101'), 'debit', 0, 'credit', 450000))) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-3',
 'RPC voucher tanpa akun kas di sisi kredit', 'DITOLAK', pg_temp.uji($q$
  SELECT post_cash_voucher('2026-10-05', 'BKK-0003', 'Bukan kas keluar',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acc('5203'), 'debit', 500000, 'credit', 0),
      jsonb_build_object('account_id', pg_temp.acc('2101'), 'debit', 0, 'credit', 500000))) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-4',
 'RPC voucher bertanggal masa depan', 'DITOLAK', pg_temp.uji($q$
  SELECT post_cash_voucher(current_date + 7, 'BKK-0004', 'Tanggal depan',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acc('5203'), 'debit', 500000, 'credit', 0),
      jsonb_build_object('account_id', pg_temp.acc('1101'), 'debit', 0, 'credit', 500000))) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-12',
 'RPC voucher melebihi saldo Kas Kecil (saldo 0)', 'DITOLAK', pg_temp.uji($q$
  SELECT post_cash_voucher(current_date, 'BKK-0005', 'Beli ATK dari kas kecil kosong',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acc('5204'), 'debit', 100000, 'credit', 0),
      jsonb_build_object('account_id', pg_temp.acc('1101'), 'debit', 0, 'credit', 100000))) $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-5',
 'UPDATE header jurnal POSTED', 'DITOLAK', pg_temp.uji($q$
  UPDATE journal_headers SET description = 'diubah' WHERE ref_no = 'BKK-0001' $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-6',
 'DELETE header jurnal POSTED', 'DITOLAK', pg_temp.uji($q$
  DELETE FROM journal_headers WHERE ref_no = 'BKK-0001' $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-7',
 'UPDATE nominal baris jurnal POSTED', 'DITOLAK', pg_temp.uji($q$
  UPDATE journal_lines SET debit = 1 WHERE debit > 0
     AND header_id = (SELECT header_id FROM journal_headers WHERE ref_no = 'BKK-0001') $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-8',
 'reverse_journal(BKK-0001) membuat storno', 'LOLOS', pg_temp.uji($q$
  SELECT reverse_journal((SELECT header_id FROM journal_headers WHERE ref_no = 'BKK-0001'),
                         'Salah input nominal', 'Farel (uji)') $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-9',
 'reverse_journal(BKK-0001) kedua kali', 'DITOLAK', pg_temp.uji($q$
  SELECT reverse_journal((SELECT header_id FROM journal_headers WHERE ref_no = 'BKK-0001'),
                         'Ulang', 'Farel (uji)') $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-10',
 'Hapus isi audit_log', 'DITOLAK', pg_temp.uji($q$ DELETE FROM audit_log $q$);

INSERT INTO hasil_uji (kode, skenario, ekspektasi, hasil) SELECT 'S3-11',
 'Semua jurnal POSTED: hash tersimpan = hash dihitung ulang', 'VALID',
 CASE WHEN bool_and(hash_valid) THEN 'VALID' ELSE 'TIDAK VALID' END
 || ' (' || count(*) || ' jurnal)' FROM v_journal_integrity;

SELECT kode, skenario, ekspektasi, hasil,
       CASE WHEN hasil LIKE ekspektasi || '%' THEN 'OK' ELSE 'GAGAL' END AS status
FROM hasil_uji ORDER BY no;
