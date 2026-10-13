-- =====================================================================
-- DEMO deteksi manipulasi (Soal 3.2): superuser mematikan trigger kunci lalu
-- mengubah jurnal POSTED. Kunci bisa dibobol oleh pemilik DB, tetapi
-- hash_checksum membuat perubahan itu TERDETEKSI (v_journal_integrity.hash_valid = false)
-- dan audit_log tetap mencatat UPDATE-nya.
-- =====================================================================
SELECT post_cash_voucher(current_date, 'DEMO-TAMPER', 'Beli ATK (jurnal demo manipulasi)',
    jsonb_build_array(
      jsonb_build_object('account_id', (SELECT account_id FROM chart_of_accounts WHERE account_code = '5204'), 'debit', 50000, 'credit', 0),
      jsonb_build_object('account_id', (SELECT account_id FROM chart_of_accounts WHERE account_code = '1102'), 'debit', 0, 'credit', 50000)),
    'Demo Auditor');

ALTER TABLE journal_headers DISABLE TRIGGER trg_jh_lock;
UPDATE journal_headers SET description = 'Beli ATK (diubah diam-diam jadi Rp500rb)' WHERE ref_no = 'DEMO-TAMPER';
ALTER TABLE journal_headers ENABLE TRIGGER trg_jh_lock;

SELECT ref_no, description, hash_valid FROM v_journal_integrity WHERE ref_no = 'DEMO-TAMPER';
