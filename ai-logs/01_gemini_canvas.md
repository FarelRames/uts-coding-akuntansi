# Log AI #1 — Gemini Canvas (Soal 3.1a)

* **Tool**: Google Gemini (mode *Otomatis*) + fitur **Canvas**
* **Tanggal**: 13 Oktober 2026
* **Judul percakapan yang dibuat Gemini**: "Purwarupa Modul BKK Supabase"
* **Output**: satu file HTML ±42.500 karakter (Tailwind CDN + Lucide + supabase-js)

## Prompt (verbatim, satu kali kirim)

> Kamu adalah front-end developer untuk sistem akuntansi. Buatkan SATU file HTML (Tailwind CSS via CDN + JavaScript vanilla, tanpa build tool) berjudul "Voucher Kas Keluar (BKK)" untuk purwarupa modul General Ledger yang terhubung ke Supabase. Ketentuan: (1) Header voucher: tanggal (default hari ini, tidak boleh tanggal masa depan), nomor bukti (default BKK-YYYYMMDD-HHmm), keterangan, dan nama penyusun. (2) Tabel baris jurnal dinamis: tombol tambah/hapus baris; tiap baris berisi dropdown akun (account_code - account_name), input Debit, input Kredit; bila Debit diisi maka Kredit otomatis 0 dan sebaliknya; nominal tidak boleh negatif; format Rupiah. (3) Live balanced indicator di footer tabel: Total Debit, Total Kredit, Selisih, dan badge hijau "SEIMBANG" atau merah "TIDAK SEIMBANG" yang berubah real-time setiap ketikan. (4) Tombol Submit HANYA aktif jika: total debit = total kredit > 0, minimal 2 baris valid, ada minimal satu akun kas/setara kas (is_cash = true) di sisi KREDIT, dan tidak ada akun kas di sisi DEBIT; tampilkan daftar alasan kenapa tombol masih nonaktif. (5) Data akun dimuat dari tabel Supabase chart_of_accounts(account_id, account_code, account_name, is_cash). Submit memanggil supabase.rpc('post_cash_voucher', {p_trx_date, p_ref_no, p_description, p_lines: [{account_id, debit, credit}], p_created_by}) yang mengembalikan header_id; tampilkan pesan error dari server apa adanya. Gunakan konstanta SUPABASE_URL dan SUPABASE_KEY di bagian atas script. (6) Di bawah form: tabel "Jurnal Terposting" dari view v_journal_integrity(header_id, ref_no, trx_date, description, created_by, created_at, reversal_of, reversed_by, hash_checksum, hash_valid, total) dengan ikon status hash valid/tidak, dan tombol "Buat Jurnal Pembalik" yang meminta alasan lalu memanggil supabase.rpc('reverse_journal', {p_header_id, p_reason, p_created_by}); tombol disembunyikan bila jurnal sudah dibalik atau merupakan jurnal pembalik. Tidak ada tombol edit/hapus karena jurnal POSTED bersifat immutable. (7) Panel "Audit Log" 20 entri terbaru dari tabel audit_log(log_id, table_name, record_id, action, changed_by, changed_at). Desain bersih, profesional, responsif, bahasa Indonesia.

**Strategi prompt**: peran (*role*) + batasan teknis (satu file, tanpa build) + kontrak data persis
(nama tabel, kolom, signature RPC yang sudah ada di database) + aturan bisnis yang dapat diuji
(kapan tombol aktif) + larangan eksplisit (tidak ada edit/hapus). Dengan kontrak yang persis,
UI langsung cocok dengan backend tanpa tebak-tebakan nama kolom.

## Ringkasan output Gemini

Gemini menjawab: *"Saya akan membuatkan file HTML lengkap untuk purwarupa modul Voucher Kas Keluar (BKK) yang terintegrasi dengan Supabase, lengkap dengan validasi akuntansi ketat, live balance indicator, tabel jurnal terposting dengan cek integritas hash, fitur jurnal pembalik, dan panel audit log terbaru."*

Komponen yang dihasilkan: header + status koneksi, form header voucher, tabel baris dinamis,
4 kartu (Total Debit, Total Kredit, Selisih, Status), kotak "Syarat Submit Belum Terpenuhi",
tabel Jurnal Terposting dengan badge hash, modal Jurnal Pembalik, panel Audit Log, sistem toast.

## Verifikasi manusia — bug yang ditemukan & perbaikannya

| # | Temuan pada kode Canvas | Dampak | Perbaikan di `index.html` |
|---|---|---|---|
| 1 | `acc.account_id === row.account_id` membandingkan **number** (dari Supabase) dengan **string** (nilai `<select>`) | Cek `is_cash` selalu gagal → tombol Submit **tidak pernah aktif**; pilihan akun hilang saat render ulang | `Number(select.value)` sebelum dibandingkan |
| 2 | Tabel di-render ulang setiap ketikan lalu `setSelectionRange()` dipanggil pada `<input type="number">` | Chrome melempar `InvalidStateError` → kalkulasi total berhenti setelah ketikan pertama | Tidak render ulang; hanya kosongkan sisi lawan di baris yang sama |
| 3 | Data DB (keterangan, nama) dimasukkan via `innerHTML` tanpa escape | **Stored XSS** — siapa pun bisa memasukkan `<script>` lewat RPC | Fungsi `esc()` untuk semua data dari server |
| 4 | Penjumlahan `parseFloat` biasa | Galat float (0,1 + 0,2 ≠ 0,3) bisa membuat "tidak seimbang" palsu | Hitung dalam **sen (integer)** |
| 5 | `lucide@latest`, `supabase-js@2` tidak dipin; tag `<span>…</i>` rusak | Build tidak reprodusibel | Versi dipin, ikon dihapus |
| 6 | Mode "offline" dengan akun dummy & "Simulasi Berhasil" | Bisa menyesatkan auditor (seolah tersimpan) | Dihapus; gagal koneksi ditampilkan apa adanya |

Kesimpulan: AI mempercepat rancangan UI, tetapi **validasi aturan bisnis tetap harus diuji manusia**.
Validasi di frontend hanya kenyamanan pengguna; penegakan sesungguhnya ada di database
(lihat `sql/04_soal3_audit_trail.sql` dan `docs/uji_api_bypass.md`).
