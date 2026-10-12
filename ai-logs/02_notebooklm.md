# Log AI #2 — NotebookLM / Gemini Notebook (Soal 3.1b)

* **Tool**: NotebookLM (kini bernama *Gemini Notebook*, notebook.google.com)
* **Tanggal**: 13 Oktober 2026
* **Notebook**: "Kas, Piutang, dan Laporan Arus Kas Perusahaan" (judul otomatis)

## Sumber yang dimasukkan

1. **Riset Cepat web** dengan kueri: *"PSAK 207 (PSAK 2) Laporan Arus Kas definisi kas dan setara kas, investasi jangka pendek jatuh tempo 3 bulan, cerukan bank; PSAK 201 penyajian laporan keuangan dasar akrual"* → 10 sumber ditemukan, **8 berhasil diimpor**, antara lain:
   * PSAK 207 Laporan Arus Kas — Ikatan Akuntan Indonesia (web.iaiglobal.or.id)
   * PSAK 201 Penyajian Laporan Keuangan — Ikatan Akuntan Indonesia
   * Laporan Arus Kas — Repository UNIKOM; BAB II Tinjauan Pustaka — Repository STEI; dll.
   * (gagal diimpor: dokumen Scribd PSAK 2 dan pengumuman IDX)
2. **Teks yang disalin**: "KODE SISTEM: Modul Voucher Kas Keluar (BKK)" — bagan akun dengan flag `is_cash`,
   logika `post_cash_voucher`, constraint baris jurnal, kunci POSTED + `reverse_journal`, dan 5 contoh transaksi uji.

## Prompt (verbatim)

> Bertindaklah sebagai auditor internal. Uji kepatuhan logika pada sumber "KODE SISTEM: Modul Voucher Kas Keluar (BKK)" terhadap PSAK 207 Laporan Arus Kas dan PSAK 201 Penyajian Laporan Keuangan. Untuk setiap aturan berikut beri status SESUAI / PERLU PERBAIKAN / TIDAK DIATUR, alasan singkat, dan kutip paragraf/definisi sumber yang relevan: (a) klasifikasi is_cash: Kas Kecil, Kas di Bank, Deposito <= 3 bulan = kas & setara kas, sedangkan Investasi Saham Diperdagangkan bukan; (b) voucher kas keluar wajib mengkredit akun kas/setara kas; (c) akun kas/setara kas tidak boleh didebit pada voucher kas keluar, termasuk contoh pembelian deposito 2 bulan dari Kas di Bank yang ditolak; (d) tanggal transaksi tidak boleh di masa depan; (e) koreksi jurnal POSTED hanya lewat jurnal pembalik, bukan edit/hapus. Akhiri dengan daftar celah atau rekomendasi perbaikan aturan bisnis.

## Ringkasan jawaban NotebookLM

| Aturan | Status dari NotebookLM | Dasar yang dikutip |
|---|---|---|
| (a) Klasifikasi `is_cash` | **SESUAI** | PSAK 207 ¶06 (definisi kas & setara kas), ¶07 (jatuh tempo ≤ 3 bulan; investasi ekuitas **bukan** setara kas) |
| (b) Wajib kredit akun kas | **SESUAI** | PSAK 207 ¶06 "arus kas adalah arus masuk dan arus keluar kas dan setara kas" |
| (c) Kas tidak boleh didebit | **PERLU PERBAIKAN** | PSAK 207 ¶09: perpindahan antar pos kas/setara kas **bukan arus kas** (bagian pengelolaan kas) |
| (d) Tanggal tidak di masa depan | **SESUAI** | PSAK 207 ¶06; PSAK 201: laporan disusun atas dasar akrual **kecuali** informasi arus kas |
| (e) Koreksi via jurnal pembalik | **SESUAI** | Keandalan & jejak audit; koreksi resmi, bukan manipulasi data historis |

Celah/rekomendasi yang diberikan:
1. **Mutasi internal kas terkunci** — isi kas kecil dari bank / penempatan deposito ≤ 3 bulan tidak bisa diinput di mana pun → buat modul *Mutasi Kas* terpisah dan eliminasi dari Laporan Arus Kas (¶09).
2. **Belum ada tag aktivitas arus kas** (operasi/investasi/pendanaan, ¶10) → tambah atribut `cash_flow_activity`.
3. **Valuta asing** belum didukung (¶28).
4. **Tanggal storno** dipatok `current_date` → izinkan tanggal dalam periode akuntansi yang masih terbuka, kunci periode tertutup.
5. **Kecukupan saldo kas** belum dicek; belum ada penanda kas yang dibatasi penggunaannya (¶48–49).

## Evaluasi kritis atas jawaban AI (verifikasi manusia)

* **(c) disetujui sebagian.** Menolak transfer kas→setara kas *di modul BKK* justru konsisten dengan ¶09
  (transaksi itu memang bukan kas keluar). Yang benar dari NotebookLM: sistem butuh **modul mutasi kas** terpisah.
  Aturan BKK tetap dipertahankan; modul mutasi dicatat sebagai pengembangan lanjutan.
* **(e)** NotebookLM menyebut "koreksi kesalahan mendasar" — itu istilah PSAK lama. Rujukan yang tepat
  untuk koreksi kesalahan periode lalu adalah PSAK 208 (ex-PSAK 25). Untuk kesalahan **periode berjalan**,
  jurnal pembalik + jurnal benar adalah praktik yang lazim, jadi kesimpulan "SESUAI" tetap diterima.
* **(d)** Frasa "berbasis cash basis" dalam jawaban AI kurang tepat; dasar pengakuan BKK adalah **tanggal
  pembayaran kas terjadi**. Aturan "tidak boleh di masa depan" tetap valid sebagai pengendalian internal.

## Tindak lanjut yang diimplementasikan

* **Rekomendasi #5 (cek saldo kas)** → diimplementasikan di `post_cash_voucher`: saldo setiap akun kas yang
  dikredit tidak boleh negatif setelah posting; baris akun dikunci `FOR UPDATE` agar dua voucher bersamaan
  tidak bisa sama-sama lolos. Diuji sebagai **S3-12** → ditolak "Saldo 1101 Kas Kecil tidak mencukupi".
* Saat menguji S3-12 lewat REST API ditemukan **bug zona waktu** (server UTC vs WIB) → diperbaiki
  (lihat `docs/hasil_uji.md`).
* Rekomendasi #1–#4 → dicatat sebagai pengembangan lanjutan di README.
