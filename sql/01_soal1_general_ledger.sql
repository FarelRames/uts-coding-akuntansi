-- =====================================================================
-- SOAL 1 — Desain Arsitektur Data, Normalisasi & Penegakan Asas Berpasangan
-- Modul General Ledger (PostgreSQL / Supabase)
-- Urutan eksekusi: 01 -> 02 -> 04 -> tests/*  (03 = demo concurrency)
-- =====================================================================

-- Entitas beroperasi di WIB: current_date harus tanggal lokal, bukan UTC (default server Supabase)
DO $$ BEGIN
    EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'Asia/Jakarta');
END $$;

-- ---------- 1.2 DDL tiga tabel inti ----------------------------------

CREATE TABLE chart_of_accounts (
    account_id      SERIAL       PRIMARY KEY,
    account_code    VARCHAR(10)  NOT NULL UNIQUE,
    account_name    VARCHAR(100) NOT NULL,
    normal_balance  VARCHAR(6)   NOT NULL CHECK (normal_balance IN ('DEBIT', 'KREDIT')),
    report_class    VARCHAR(10)  NOT NULL CHECK (report_class IN ('NERACA', 'LABA_RUGI')),
    -- penanda kas & setara kas (PSAK 207), dipakai validasi voucher kas keluar Soal 3
    is_cash         BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE TABLE journal_headers (
    header_id       SERIAL       PRIMARY KEY,
    trx_date        DATE         NOT NULL,
    ref_no          VARCHAR(40)  NOT NULL UNIQUE,          -- nomor bukti/referensi
    description     TEXT         NOT NULL,
    posting_status  VARCHAR(10)  NOT NULL DEFAULT 'DRAFT'
                    CHECK (posting_status IN ('DRAFT', 'POSTED'))
);

CREATE TABLE journal_lines (
    line_id     SERIAL        PRIMARY KEY,
    header_id   INT           NOT NULL
                REFERENCES journal_headers (header_id)   ON DELETE RESTRICT,
    account_id  INT           NOT NULL
                REFERENCES chart_of_accounts (account_id) ON DELETE RESTRICT,
    debit       NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit      NUMERIC(18,2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_debit_nonneg   CHECK (debit  >= 0),
    CONSTRAINT chk_credit_nonneg  CHECK (credit >= 0),
    CONSTRAINT chk_not_both_zero  CHECK (NOT (debit = 0 AND credit = 0)),
    CONSTRAINT chk_one_side       CHECK (debit = 0 OR credit = 0)  -- satu baris = satu sisi
);

CREATE INDEX idx_lines_header  ON journal_lines (header_id);
CREATE INDEX idx_lines_account ON journal_lines (account_id);

-- ---------- Penegakan asas berpasangan DI DATABASE --------------------
-- CHECK hanya bisa melihat satu baris. Keseimbangan Debit = Kredit per jurnal
-- ditegakkan dengan CONSTRAINT TRIGGER yang ditunda (DEFERRED) sampai COMMIT,
-- sehingga request API yang hanya mengirim satu sisi jurnal pasti ditolak.

CREATE OR REPLACE FUNCTION fn_check_journal_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_id     INT;
    v_debit  NUMERIC;
    v_credit NUMERIC;
BEGIN
    -- UPDATE bisa memindahkan baris antar header: periksa keduanya
    FOREACH v_id IN ARRAY ARRAY[NEW.header_id, OLD.header_id] LOOP
        CONTINUE WHEN v_id IS NULL;
        SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
          INTO v_debit, v_credit
          FROM journal_lines WHERE header_id = v_id;
        IF v_debit <> v_credit THEN
            RAISE EXCEPTION 'Jurnal header_id=% tidak seimbang: Debit % <> Kredit %',
                v_id, v_debit, v_credit
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_journal_balance
    AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_journal_balance();

-- Jurnal hanya boleh POSTED bila punya >= 2 baris dan seimbang.
CREATE OR REPLACE FUNCTION fn_validate_posting()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_cnt INT; v_debit NUMERIC; v_credit NUMERIC;
BEGIN
    IF NEW.posting_status <> 'POSTED' THEN RETURN NEW; END IF;
    IF TG_OP = 'INSERT' THEN
        RAISE EXCEPTION 'Jurnal baru harus DRAFT; isi baris dulu, baru di-POST';
    END IF;
    SELECT COUNT(*), COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
      INTO v_cnt, v_debit, v_credit
      FROM journal_lines WHERE header_id = NEW.header_id;
    IF v_cnt < 2 OR v_debit <> v_credit OR v_debit = 0 THEN
        RAISE EXCEPTION 'Jurnal % tidak dapat di-POST: % baris, Debit %, Kredit %',
            NEW.ref_no, v_cnt, v_debit, v_credit;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_jh_validate_post
    BEFORE INSERT OR UPDATE OF posting_status ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_validate_posting();

-- ---------- Neraca saldo (hanya jurnal POSTED) ------------------------
CREATE OR REPLACE VIEW v_trial_balance WITH (security_invoker = on) AS
SELECT a.account_code, a.account_name, a.normal_balance, a.report_class,
       COALESCE(SUM(l.debit), 0)  AS total_debit,
       COALESCE(SUM(l.credit), 0) AS total_credit,
       CASE a.normal_balance
           WHEN 'DEBIT' THEN COALESCE(SUM(l.debit - l.credit), 0)
           ELSE              COALESCE(SUM(l.credit - l.debit), 0)
       END AS saldo
FROM chart_of_accounts a
LEFT JOIN (journal_lines l
           JOIN journal_headers h ON h.header_id = l.header_id
                                 AND h.posting_status = 'POSTED')
       ON l.account_id = a.account_id
GROUP BY a.account_id
ORDER BY a.account_code;

-- ---------- Data awal Bagan Akun (ritel) ------------------------------
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_class, is_cash) VALUES
 ('1101', 'Kas Kecil',                              'DEBIT',  'NERACA',    TRUE),
 ('1102', 'Kas di Bank',                            'DEBIT',  'NERACA',    TRUE),
 ('1103', 'Deposito Berjangka <= 3 Bulan',          'DEBIT',  'NERACA',    TRUE),
 ('1104', 'Investasi Saham Diperdagangkan',         'DEBIT',  'NERACA',    FALSE),
 ('1201', 'Piutang Usaha',                          'DEBIT',  'NERACA',    FALSE),
 ('1301', 'Persediaan Barang Dagang',               'DEBIT',  'NERACA',    FALSE),
 ('1401', 'Sewa Dibayar di Muka',                   'DEBIT',  'NERACA',    FALSE),
 ('2101', 'Utang Usaha',                            'KREDIT', 'NERACA',    FALSE),
 ('3101', 'Modal Disetor',                          'KREDIT', 'NERACA',    FALSE),
 ('4101', 'Penjualan',                              'KREDIT', 'LABA_RUGI', FALSE),
 ('5101', 'Beban Pokok Pendapatan (HPP)',           'DEBIT',  'LABA_RUGI', FALSE),
 ('5201', 'Beban Gaji',                             'DEBIT',  'LABA_RUGI', FALSE),
 ('5202', 'Beban Listrik, Air & Telepon',           'DEBIT',  'LABA_RUGI', FALSE),
 ('5203', 'Beban Sewa',                             'DEBIT',  'LABA_RUGI', FALSE),
 ('5204', 'Beban Perlengkapan Kantor',              'DEBIT',  'LABA_RUGI', FALSE),
 ('5901', 'Selisih Persediaan',                     'DEBIT',  'LABA_RUGI', FALSE);
