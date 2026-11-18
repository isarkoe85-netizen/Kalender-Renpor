# Kalender Tim

Web app (PWA) untuk jadwal kegiatan tim, tersinkron ke Google Calendar (Android) dan Apple Calendar (iOS)
lewat feed iCalendar langganan (`webcal://`).

## Menjalankan
    ruby server.rb          # http://localhost:3000   (PORT=8080 untuk ganti port)

Hanya butuh Ruby (WEBrick bawaan). Data tersimpan di `data.json`.

## Cara kerja
- Buat tim -> dapat **kode tim** (6 karakter) untuk dibagikan ke anggota.
- Anggota membuka web app, memasukkan kode + nama, lalu menambah/ubah/hapus kegiatan.
- Tombol **Sinkronkan ke HP** memberi tautan `.../cal/<token>.ics` + panduan iOS & Android.
- Di HP: "Add to Home Screen" untuk memasang sebagai aplikasi (PWA).

## Deploy (wajib agar sinkron ke HP)
Google/Apple Calendar menarik feed dari server, jadi aplikasi harus di alamat **HTTPS publik**
(VPS, Fly.io, Render, dsb. atau tunnel seperti Cloudflare Tunnel untuk uji coba).

## Keterbatasan MVP
- Tanpa login/password: kode tim = kunci akses; siapa pun yang tahu kode bisa mengedit.
- Sinkronisasi ke kalender HP satu arah (aplikasi -> kalender). Mengedit di kalender HP tidak kembali ke aplikasi.
- Kecepatan refresh ditentukan Apple (~15 menit) / Google (bisa beberapa jam).
