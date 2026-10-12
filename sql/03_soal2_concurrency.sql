-- =====================================================================
-- SOAL 2.2 — Race condition: dua kasir menjual item yang sama, stok tinggal 1
-- =====================================================================
-- Masalah: kedua sesi membaca stok = 1 pada saat yang sama, keduanya lolos
-- validasi, stok menjadi -1 (overselling / phantom stock).

-- ---------- Teknik 1: Pessimistic locking (SELECT ... FOR UPDATE) -------
-- Sudah dipasang di dalam trg_update_stock_and_journal(). Pola manualnya:
--
--   Kasir A                                   Kasir B
--   BEGIN;                                    BEGIN;
--   SELECT stock_qty FROM inventory_items
--    WHERE item_id = 'BRG-002' FOR UPDATE;    -- stok 1, baris terkunci
--                                             SELECT stock_qty FROM inventory_items
--                                              WHERE item_id = 'BRG-002' FOR UPDATE;
--                                             -- MENUNGGU kunci milik A ...
--   INSERT INTO inventory_transactions
--     (item_id, trx_type, qty)
--   VALUES ('BRG-002', 'SALE', 1);            -- stok -> 0
--   COMMIT;                                   -- kunci dilepas, B membaca stok = 0
--                                             INSERT ... SALE 1
--                                             -- ERROR: Stok BRG-002 tidak cukup
--                                             ROLLBACK;

-- ---------- Demo nyata di Supabase SQL Editor (dua tab) ------------------
-- Siapkan stok tepat 1 unit:
--   INSERT INTO inventory_transactions (item_id, trx_type, qty)
--   SELECT 'BRG-002', 'ADJUSTMENT', 1 - stock_qty FROM inventory_items
--    WHERE item_id = 'BRG-002' AND stock_qty <> 1;
--
-- TAB A (jalankan dulu; kunci ditahan 15 detik):
BEGIN;
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-002', 'SALE', 1);
SELECT pg_sleep(15);
COMMIT;
--
-- TAB B (jalankan dalam 15 detik; tertahan, lalu gagal setelah A COMMIT):
--   INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-002', 'SALE', 1);
--   -> ERROR: Stok BRG-002 tidak cukup: tersedia 0, diminta 1

-- ---------- Teknik 2: Isolasi SERIALIZABLE (optimistic) ------------------
-- Tanpa kunci eksplisit; PostgreSQL membatalkan salah satu transaksi yang
-- saling bertabrakan dengan SQLSTATE 40001, dan aplikasi wajib mengulang (retry).
--
--   BEGIN ISOLATION LEVEL SERIALIZABLE;
--   SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG-002';
--   UPDATE inventory_items SET stock_qty = stock_qty - 1 WHERE item_id = 'BRG-002';
--   COMMIT;   -- transaksi kedua: ERROR 40001 could not serialize access
--
-- Pola retry di sisi aplikasi (Node.js / supabase-js):
--   for (let i = 0; i < 3; i++) {
--     const { error } = await supabase.from('inventory_transactions')
--       .insert({ item_id: 'BRG-002', trx_type: 'SALE', qty: 1 });
--     if (!error || error.code !== '40001') break;   // selain konflik serialisasi: berhenti
--   }
--
-- Pilihan: FOR UPDATE untuk stok "panas" (antre, tidak perlu retry);
-- SERIALIZABLE bila logika membaca banyak baris dan konflik jarang.
