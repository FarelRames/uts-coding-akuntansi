-- =====================================================================
-- SOAL 3.2 — Jejak Audit & Immutability (Supabase RPC / PL/pgSQL)
-- Butuh 01 & 02. Fungsi RPC dipanggil frontend lewat supabase.rpc(...)
-- =====================================================================

-- Identitas pelaku: email dari JWT Supabase Auth bila login, selain itu role/user DB
CREATE OR REPLACE FUNCTION current_actor()
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
        current_user)
$$;

ALTER TABLE journal_headers
    ADD COLUMN created_by    TEXT        NOT NULL DEFAULT current_actor(),
    ADD COLUMN created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN posted_at     TIMESTAMPTZ,
    ADD COLUMN reversal_of   INT UNIQUE REFERENCES journal_headers(header_id) ON DELETE RESTRICT,
    ADD COLUMN hash_checksum CHAR(64);

-- ---------- hash_checksum: SHA-256 atas isi jurnal yang di-POST ----------
-- Format kanonik (tidak bergantung setting TimeZone/DateStyle sesi).
CREATE OR REPLACE FUNCTION journal_hash(h journal_headers)
RETURNS CHAR(64) LANGUAGE sql STABLE AS $$
    SELECT encode(sha256(convert_to(
        concat_ws('|',
            h.header_id,
            to_char(h.trx_date, 'YYYY-MM-DD'),
            h.ref_no,
            h.description,
            h.created_by,
            to_char(h.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
            COALESCE(h.reversal_of::text, ''),
            (SELECT string_agg(l.account_id || ':' || l.debit || ':' || l.credit, ';' ORDER BY l.line_id)
               FROM journal_lines l WHERE l.header_id = h.header_id)),
        'UTF8')), 'hex')
$$;

-- ---------- Kunci jurnal POSTED (header) ---------------------------------
CREATE OR REPLACE FUNCTION fn_lock_posted_header()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.posting_status = 'POSTED' THEN
            RAISE EXCEPTION 'Jurnal % sudah POSTED dan tidak boleh dihapus. Gunakan reverse_journal() (storno).',
                OLD.ref_no USING ERRCODE = 'insufficient_privilege';
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.posting_status = 'POSTED' THEN
            RAISE EXCEPTION 'Jurnal % sudah POSTED dan tidak boleh diubah. Gunakan reverse_journal() (storno).',
                OLD.ref_no USING ERRCODE = 'insufficient_privilege';
        END IF;
        NEW.created_by := OLD.created_by;   -- field audit tidak bisa ditimpa
        NEW.created_at := OLD.created_at;
    ELSE  -- INSERT
        -- shortcut: tanpa login, nama pembuat diisi sendiri oleh pengguna; aktifkan Supabase Auth agar email JWT selalu dipakai
        NEW.created_by := COALESCE(
            NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
            NULLIF(trim(NEW.created_by), ''),
            current_actor());
        NEW.created_at := now();
    END IF;

    IF NEW.posting_status = 'POSTED' THEN          -- transisi DRAFT -> POSTED
        NEW.posted_at     := now();
        NEW.hash_checksum := journal_hash(NEW);
    ELSE
        NEW.posted_at     := NULL;
        NEW.hash_checksum := NULL;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_jh_lock
    BEFORE INSERT OR UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_lock_posted_header();

-- ---------- Kunci baris jurnal milik header POSTED -----------------------
CREATE OR REPLACE FUNCTION fn_lock_posted_lines()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM journal_headers
                WHERE header_id IN (NEW.header_id, OLD.header_id)
                  AND posting_status = 'POSTED') THEN
        RAISE EXCEPTION 'Baris jurnal milik jurnal POSTED tidak boleh di-%', TG_OP
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_jl_lock
    BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_lock_posted_lines();

-- TRUNCATE tidak memicu trigger baris; blokir terpisah
CREATE OR REPLACE FUNCTION fn_block_truncate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE % dilarang (data akuntansi bersifat immutable)', TG_TABLE_NAME;
END $$;

CREATE TRIGGER trg_jh_no_truncate BEFORE TRUNCATE ON journal_headers
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_truncate();
CREATE TRIGGER trg_jl_no_truncate BEFORE TRUNCATE ON journal_lines
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_truncate();

-- ---------- Audit log (append-only) --------------------------------------
CREATE TABLE audit_log (
    log_id      BIGSERIAL   PRIMARY KEY,
    table_name  TEXT        NOT NULL,
    record_id   TEXT        NOT NULL,
    action      TEXT        NOT NULL,
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT        NOT NULL DEFAULT current_actor(),
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION fn_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_old JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_new JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
    VALUES (TG_TABLE_NAME, COALESCE(v_new, v_old) ->> TG_ARGV[0], TG_OP, v_old, v_new);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_audit_headers AFTER INSERT OR UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('header_id');
CREATE TRIGGER trg_audit_lines AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('line_id');
CREATE TRIGGER trg_audit_coa AFTER INSERT OR UPDATE OR DELETE ON chart_of_accounts
    FOR EACH ROW EXECUTE FUNCTION fn_audit_log('account_id');

CREATE OR REPLACE FUNCTION fn_block_audit_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log bersifat append-only: % dilarang', TG_OP;
END $$;

CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION fn_block_audit_change();
CREATE TRIGGER trg_audit_no_truncate BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION fn_block_truncate();

-- ---------- RPC: posting voucher kas keluar ------------------------------
-- p_lines: [{"account_id": 12, "debit": 150000, "credit": 0}, ...]
CREATE OR REPLACE FUNCTION post_cash_voucher(
    p_trx_date    DATE,
    p_ref_no      TEXT,
    p_description TEXT,
    p_lines       JSONB,
    p_created_by  TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'Asia/Jakarta' AS $$
DECLARE
    v_id      INT;
    v_cash_cr NUMERIC;
    v_cash_dr NUMERIC;
    v_acc     RECORD;
    v_saldo   NUMERIC;
BEGIN
    IF p_trx_date IS NULL OR p_trx_date > current_date THEN
        RAISE EXCEPTION 'Tanggal transaksi wajib dan tidak boleh di masa depan (kas diakui saat dibayar)';
    END IF;
    IF COALESCE(trim(p_ref_no), '') = '' OR COALESCE(trim(p_description), '') = '' THEN
        RAISE EXCEPTION 'Nomor bukti dan keterangan wajib diisi';
    END IF;
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'Voucher minimal berisi 2 baris jurnal';
    END IF;

    INSERT INTO journal_headers (trx_date, ref_no, description, created_by)
    VALUES (p_trx_date, trim(p_ref_no), trim(p_description), p_created_by)
    RETURNING header_id INTO v_id;

    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_id, (e ->> 'account_id')::int,
           COALESCE((e ->> 'debit')::numeric, 0),
           COALESCE((e ->> 'credit')::numeric, 0)
      FROM jsonb_array_elements(p_lines) e;

    -- aturan bisnis kas keluar
    SELECT COALESCE(SUM(l.credit), 0), COALESCE(SUM(l.debit), 0)
      INTO v_cash_cr, v_cash_dr
      FROM journal_lines l JOIN chart_of_accounts a USING (account_id)
     WHERE l.header_id = v_id AND a.is_cash;
    IF v_cash_cr = 0 THEN
        RAISE EXCEPTION 'Voucher kas keluar wajib mengkredit akun kas/setara kas';
    END IF;
    IF v_cash_dr > 0 THEN
        RAISE EXCEPTION 'Akun kas/setara kas tidak boleh didebit pada voucher kas keluar';
    END IF;

    -- Rekomendasi verifikasi NotebookLM: saldo kas tidak boleh minus (cerukan) setelah posting.
    -- FOR UPDATE pada akun kas menyerialkan voucher yang memakai akun kas yang sama.
    FOR v_acc IN
        SELECT a.account_id, a.account_code, a.account_name
          FROM journal_lines l JOIN chart_of_accounts a USING (account_id)
         WHERE l.header_id = v_id AND a.is_cash AND l.credit > 0
         ORDER BY a.account_id
           FOR UPDATE OF a
    LOOP
        SELECT COALESCE(SUM(x.debit - x.credit), 0) INTO v_saldo
          FROM journal_lines x JOIN journal_headers hx USING (header_id)
         WHERE x.account_id = v_acc.account_id
           AND (hx.posting_status = 'POSTED' OR hx.header_id = v_id);
        IF v_saldo < 0 THEN
            RAISE EXCEPTION 'Saldo % % tidak mencukupi (akan menjadi %)',
                v_acc.account_code, v_acc.account_name, v_saldo;
        END IF;
    END LOOP;

    -- memicu validasi keseimbangan + hash_checksum
    UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_id;
    RETURN v_id;
END $$;

-- ---------- RPC: jurnal pembalik (storno) --------------------------------
CREATE OR REPLACE FUNCTION reverse_journal(
    p_header_id  INT,
    p_reason     TEXT,
    p_created_by TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public SET timezone = 'Asia/Jakarta' AS $$
DECLARE
    v_orig journal_headers;
    v_id   INT;
BEGIN
    SELECT * INTO v_orig FROM journal_headers WHERE header_id = p_header_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Jurnal % tidak ditemukan', p_header_id;
    ELSIF v_orig.posting_status <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya jurnal POSTED yang dibalik; DRAFT cukup diperbaiki';
    ELSIF v_orig.reversal_of IS NOT NULL THEN
        RAISE EXCEPTION 'Jurnal pembalik tidak dapat dibalik lagi';
    ELSIF EXISTS (SELECT 1 FROM journal_headers WHERE reversal_of = p_header_id) THEN
        RAISE EXCEPTION 'Jurnal % sudah pernah dibalik', v_orig.ref_no;
    ELSIF COALESCE(trim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'Alasan pembalikan wajib diisi';
    END IF;

    INSERT INTO journal_headers (trx_date, ref_no, description, created_by, reversal_of)
    VALUES (current_date, 'REV-' || v_orig.ref_no,
            'Storno ' || v_orig.ref_no || ': ' || trim(p_reason), p_created_by, p_header_id)
    RETURNING header_id INTO v_id;

    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_id, account_id, credit, debit           -- sisi ditukar
      FROM journal_lines WHERE header_id = p_header_id ORDER BY line_id;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_id;
    RETURN v_id;
END $$;

-- ---------- Verifikasi integritas: hash disimpan vs dihitung ulang -------
CREATE OR REPLACE VIEW v_journal_integrity WITH (security_invoker = on) AS
SELECT h.header_id, h.ref_no, h.trx_date, h.description, h.created_by, h.created_at,
       h.posted_at, h.reversal_of,
       r.header_id                             AS reversed_by,
       h.hash_checksum,
       h.hash_checksum = journal_hash(h)       AS hash_valid,
       (SELECT SUM(debit) FROM journal_lines l WHERE l.header_id = h.header_id) AS total
FROM journal_headers h
LEFT JOIN journal_headers r ON r.reversal_of = h.header_id
WHERE h.posting_status = 'POSTED';

-- ---------- Hak akses API (anon / authenticated) -------------------------
-- Tulis langsung ke tabel via REST API ditutup; satu-satunya jalan masuk = RPC.
ALTER TABLE chart_of_accounts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_headers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines          ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log              ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY read_all ON chart_of_accounts FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY read_all ON journal_headers   FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY read_all ON journal_lines     FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY read_all ON audit_log         FOR SELECT TO anon, authenticated USING (true);

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON
    chart_of_accounts, journal_headers, journal_lines, audit_log,
    inventory_items, inventory_transactions
FROM anon, authenticated;

-- shortcut: RPC terbuka untuk anon agar purwarupa bisa dicoba tanpa login; produksi: hanya authenticated
GRANT EXECUTE ON FUNCTION post_cash_voucher(DATE, TEXT, TEXT, JSONB, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION reverse_journal(INT, TEXT, TEXT)                 TO anon, authenticated;
