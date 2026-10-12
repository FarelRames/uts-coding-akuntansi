-- =====================================================================
-- SOAL 2 — Otomasi Bisnis: Trigger Persediaan Perpetual
-- PT Diponegoro Logistik Utama. Butuh 01_soal1_general_ledger.sql (COA & jurnal).
-- =====================================================================

-- Struktur tabel sesuai naskah soal
CREATE TABLE inventory_items (
    item_id   VARCHAR(10) PRIMARY KEY,
    item_name VARCHAR(100),
    stock_qty INT NOT NULL DEFAULT 0,
    unit_cost NUMERIC(15, 2) NOT NULL
);

CREATE TABLE inventory_transactions (
    trx_id   SERIAL PRIMARY KEY,
    item_id  VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type VARCHAR(10) CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty      INT NOT NULL,
    trx_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Lapis pertahanan terakhir: stok tidak pernah boleh negatif walau trigger dimatikan
ALTER TABLE inventory_items ADD CONSTRAINT chk_stock_nonneg CHECK (stock_qty >= 0);

-- ---------- 2.1 Trigger function ---------------------------------------
-- Konvensi qty: PURCHASE & SALE > 0; ADJUSTMENT bertanda (+ tambah, - kurang).
-- Setiap mutasi langsung menghasilkan jurnal POSTED di buku besar (perpetual):
--   PURCHASE    Dr 1301 Persediaan      Cr 2101 Utang Usaha
--   SALE        Dr 5101 HPP             Cr 1301 Persediaan
--   ADJUSTMENT+ Dr 1301 Persediaan      Cr 5901 Selisih Persediaan
--   ADJUSTMENT- Dr 5901 Selisih Persed. Cr 1301 Persediaan
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_stock  INT;
    v_cost   NUMERIC(15,2);
    v_delta  INT;
    v_amount NUMERIC(18,2);
    v_header INT;
    v_dr     VARCHAR(10);
    v_cr     VARCHAR(10);
BEGIN
    IF NEW.trx_type IN ('PURCHASE', 'SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'Qty % tidak valid: % harus > 0', NEW.qty, NEW.trx_type;
    ELSIF NEW.trx_type = 'ADJUSTMENT' AND NEW.qty = 0 THEN
        RAISE EXCEPTION 'Qty ADJUSTMENT tidak boleh 0';
    END IF;

    -- 2.2: kunci baris item (row-level lock). Transaksi lain atas item yang sama
    -- menunggu di sini sampai transaksi ini COMMIT/ROLLBACK, lalu membaca stok terbaru.
    SELECT stock_qty, unit_cost INTO v_stock, v_cost
      FROM inventory_items
     WHERE item_id = NEW.item_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % tidak ditemukan', NEW.item_id;
    END IF;

    v_delta := CASE NEW.trx_type WHEN 'SALE' THEN -NEW.qty ELSE NEW.qty END;

    -- (b) anti-negative inventory: batalkan seluruh transaksi
    IF v_stock + v_delta < 0 THEN
        RAISE EXCEPTION 'Stok % tidak cukup: tersedia %, diminta %',
            NEW.item_id, v_stock, -v_delta
            USING ERRCODE = 'check_violation';
    END IF;

    -- (a) mutakhirkan saldo fisik
    UPDATE inventory_items SET stock_qty = v_stock + v_delta
     WHERE item_id = NEW.item_id;

    -- mutakhirkan nilai di buku besar pada transaksi yang sama (tidak ada jeda)
    v_amount := ABS(v_delta) * v_cost;
    IF v_amount > 0 THEN
        v_dr := CASE WHEN NEW.trx_type = 'SALE' THEN '5101'
                     WHEN v_delta > 0           THEN '1301'
                     ELSE                            '5901' END;
        v_cr := CASE WHEN NEW.trx_type = 'PURCHASE' THEN '2101'
                     WHEN NEW.trx_type = 'SALE'     THEN '1301'
                     WHEN v_delta > 0               THEN '5901'
                     ELSE                                '1301' END;

        INSERT INTO journal_headers (trx_date, ref_no, description)
        VALUES (COALESCE(NEW.trx_date, now())::date,
                'INV-' || NEW.trx_id,
                format('Otomatis %s %s qty %s @ %s', NEW.trx_type, NEW.item_id, NEW.qty, v_cost))
        RETURNING header_id INTO v_header;

        INSERT INTO journal_lines (header_id, account_id, debit, credit)
        SELECT v_header, account_id, v_amount, 0 FROM chart_of_accounts WHERE account_code = v_dr
        UNION ALL
        SELECT v_header, account_id, 0, v_amount FROM chart_of_accounts WHERE account_code = v_cr;

        UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_header;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_update_stock_and_journal
    AFTER INSERT ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_update_stock_and_journal();

-- Rekonsiliasi: nilai fisik gudang vs saldo akun Persediaan di buku besar
CREATE OR REPLACE VIEW v_inventory_reconciliation WITH (security_invoker = on) AS
SELECT (SELECT COALESCE(SUM(stock_qty * unit_cost), 0) FROM inventory_items) AS nilai_fisik_gudang,
       (SELECT saldo FROM v_trial_balance WHERE account_code = '1301')       AS saldo_buku_persediaan;

-- Data awal barang (stok 0, diisi lewat transaksi PURCHASE agar jurnal tercipta)
INSERT INTO inventory_items (item_id, item_name, stock_qty, unit_cost) VALUES
 ('BRG-001', 'Beras Premium 5 kg',  0, 65000),
 ('BRG-002', 'Minyak Goreng 2 L',   0, 32000);
