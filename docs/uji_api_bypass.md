# Uji Bypass Frontend via REST API (konteks Soal 1)

Masalah di naskah: transaksi yang dikirim **langsung melalui API** lolos tanpa pasangan Debit-Kredit.
Uji ini memakai `curl` dengan *publishable key* (sama seperti yang dipakai browser), tanpa melewati form.

```bash
U=https://vgwvcfqpclewbiymmglv.supabase.co/rest/v1
K=sb_publishable_...   # kunci publik (aman dibagikan bila RLS aktif)

curl -X POST   "$U/journal_headers"                 -H "apikey: $K" -d '{...}'   # 1
curl -X PATCH  "$U/journal_headers?ref_no=eq.BKK-0001" -H "apikey: $K" -d '{...}' # 2
curl -X DELETE "$U/audit_log?log_id=gt.0"           -H "apikey: $K"              # 3
curl -X POST   "$U/rpc/post_cash_voucher"           -H "apikey: $K" -d '{... Dr 100.000 / Cr 90.000 ...}' # 4
curl           "$U/v_trial_balance?saldo=neq.0"     -H "apikey: $K"              # 5
```

| # | Percobaan | Respons server |
|---|---|---|
| 1 | INSERT langsung ke `journal_headers` | `42501 permission denied for table journal_headers` |
| 2 | UPDATE jurnal POSTED | `42501 permission denied for table journal_headers` |
| 3 | DELETE `audit_log` | `42501 permission denied for table audit_log` |
| 4 | RPC voucher tidak seimbang | `P0001 Jurnal API-X tidak dapat di-POST: 2 baris, Debit 100000.00, Kredit 90000.00` |
| 5 | Baca neraca saldo | Diizinkan (read-only) — lihat di bawah |

Neraca saldo setelah seluruh uji (hanya saldo ≠ 0):

| Akun | Nama | Debit | Kredit |
|---|---|---:|---:|
| 1102 | Kas di Bank | 50.000.000 | |
| 1301 | Persediaan Barang Dagang | 325.000 | |
| 5101 | Beban Pokok Pendapatan (HPP) | 292.000 | |
| 5901 | Selisih Persediaan | 193.000 | |
| 2101 | Utang Usaha | | 810.000 |
| 3101 | Modal Disetor | | 50.000.000 |
| | **Total** | **50.810.000** | **50.810.000** |

Kesimpulan: satu-satunya jalan tulis dari luar adalah fungsi RPC yang memvalidasi di dalam database,
sehingga keseimbangan tidak lagi bergantung pada validasi frontend.
