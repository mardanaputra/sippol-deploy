# SIPPOL PP Buleleng - Panduan Deployment

Dokumentasi ini menjelaskan prosedur deployment produksi untuk aplikasi **SIPPOL PP Buleleng** (Sistem Informasi Pelayanan Pengaduan & Operasional Satpol PP Kabupaten Buleleng) menggunakan kontainer Docker atomic dan Docker Compose.

---

## 1. Arsitektur Kontainer

Sistem dideploy dalam dua kontainer terisolasi (*atomic containers*) yang terhubung melalui *bridge network* privat Docker (`sippol-network`):

```
                                      [ Browser / Warga & Admin ]
                                                   │
                        ┌──────────────────────────┴──────────────────────────┐
                        ▼ (Port 3000)                                         ▼ (Port 8000)
            ┌───────────────────────┐                             ┌───────────────────────┐
            │    sippol-frontend    │                             │    sippol-backend     │
            │  (Next.js Standalone) │ ──[ internal proxy /api ]──>│ (Laravel + FrankenPHP)│
            └───────────────────────┘                             └───────────┬───────────┘
                                                                              │
                                                                   ┌──────────┴──────────┐
                                                                   ▼                     ▼
                                                             [DB Volume]          [Storage Volume]
                                                          (database.sqlite)      (foto & berkas BAP)
```

1. **`sippol-frontend` (Port 3000)**:
   - Next.js 16.2.6 dengan kompilasi `output: 'standalone'` pada image minimal `node:20-alpine` (~100 MB).
   - Menjalankan server Node.js non-root (`nextjs`, UID 1001).
   - Memiliki healthcheck otomatis di root `/`.
2. **`sippol-backend` (Port 8000)**:
   - Laravel 12 API berbasis **FrankenPHP** (engine server modern berbasis Caddy & Go) di atas image `dunglas/frankenphp:1-php8.2-alpine`.
   - Menggantikan stack tradisional (Nginx + PHP-FPM + Supervisor) dengan **1 binary atomic** berkinerja tinggi, mendukung HTTP/2, HTTP/3, serta kompresi Zstandard & Brotli secara terintegrasi.
   - Dikonfigurasi untuk menangani payload Base64 besar (foto bukti & PDF) dengan limit `request_body max_size 64MB` dan PHP `post_max_size 64M`.
   - Mengelola lifecycle otomatis via `docker-entrypoint.sh` (pembuatan file SQLite, generate `APP_KEY`, penyesuaian hak akses `storage/`, migrasi, dan seeder).
   - Memiliki healthcheck bawaan Laravel di `/up`.

---

## 2. Persyaratan Sistem

- **Sistem Operasi**: Linux (Ubuntu 22.04/24.04 LTS direkomendasikan), macOS, atau Windows dengan WSL2.
- **Docker Engine**: Versi 24.0+ atau lebih baru.
- **Docker Compose**: Versi v2.20+ (sintaks `docker compose`).
- **RAM**: Minimal 2 GB (Rekomendasi: 4 GB untuk build Next.js).
- **Ruang Disk**: Minimal 5 GB kosong.

---

## 3. Langkah-Langkah Deployment

### Langkah 1: Masuk ke Folder Deployment
Seluruh perintah deployment dijalankan dari folder `sippol-deploy/`:
```bash
cd sippol-deploy
```

### Langkah 2: Buat dan Sesuaikan Berkas `.env`
Salin template konfigurasi:
```bash
cp .env.example .env
```

Buka `.env` dan sesuaikan nilainya:
- `NEXT_PUBLIC_API_URL`: Domain publik backend yang bisa diakses oleh peramban pengguna (misalnya `https://api-sippol.bulelengkab.go.id` atau `http://IP_SERVER:8000`).
- `NEXT_PUBLIC_RECAPTCHA_SITE_KEY` & `RECAPTCHA_SECRET_KEY`: Kunci Google reCAPTCHA v2 / v3.
- `APP_ENV`: Tetap `production`.
- `AUTORUN_MIGRATIONS=true`: Untuk menjalankan migrasi otomatis pada start pertama.
- `RUN_SEEDERS=true`: Menyiapkan akun admin awal dan data referensi Satpol PP Buleleng.

### Langkah 3: Build & Jalankan Kontainer
Jalankan perintah build dan jalankan di latar belakang (*detached mode*):
```bash
docker compose up -d --build
```

### Langkah 4: Verifikasi Status & Healthcheck
Periksa kontainer yang sedang berjalan:
```bash
docker compose ps
```
Pastikan kolom status menampilkan `Up (healthy)` untuk kedua layanan:
- `sippol-backend` -> `Up (healthy) 0.0.0.0:8000->8000/tcp`
- `sippol-frontend` -> `Up (healthy) 0.0.0.0:3000->3000/tcp`

---

## 4. Akun Admin Bawaan (Default Seeder)

Setelah migrasi dan seeder selesai berjalan, akun admin bawaan yang tersedia:
- **URL Login Admin**: `http://IP_SERVER:3000/admin/login`
- **Username**: `admin`
- **Password**: `admin`
- **Role**: `super_admin`

> ⚠️ **PENTING (KEAMANAN PRODUKSI)**: Segera masuk ke menu **Manajemen User** (`/admin/manajemen-user`) setelah instalasi dan ubah kata sandi akun `admin`!

---

## 5. Konfigurasi Reverse Proxy Host (Nginx & SSL Let's Encrypt)

Di server produksi, pasang Nginx pada host utama untuk mengarahkan domain resmi ke port kontainer:

```nginx
# 1. Frontend: sippol.bulelengkab.go.id -> Port 3000
server {
    server_name sippol.bulelengkab.go.id;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}

# 2. Backend API: api-sippol.bulelengkab.go.id -> Port 8000
server {
    server_name api-sippol.bulelengkab.go.id;
    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Pasang sertifikat SSL gratis dengan Certbot:
```bash
sudo certbot --nginx -d sippol.bulelengkab.go.id -d api-sippol.bulelengkab.go.id
```

---

## 6. Perintah Operasional Harian

| Perintah | Deskripsi |
|---|---|
| `docker compose logs -f` | Memantau seluruh log aplikasi secara langsung |
| `docker compose logs -f backend` | Memantau log backend (Nginx, PHP-FPM, SQL) |
| `docker compose logs -f frontend` | Memantau log frontend Next.js |
| `docker compose restart` | Memulai ulang seluruh kontainer |
| `docker compose stop` | Menghentikan seluruh kontainer tanpa menghapus data |
| `docker compose down` | Mematikan dan melepas kontainer |
| `docker compose down -v` | ⚠️ Menghapus kontainer beserta volume database |
| `docker compose exec backend sh` | Membuka shell interaktif di dalam backend |
| `docker compose exec backend php artisan tinker` | Membuka Laravel Tinker CLI |
| `docker compose exec backend php artisan route:list` | Memeriksa rute backend aktif |

---

## 7. Prosedur Pencadangan (Backup & Restore)

Data persisten disimpan pada dua named volume Docker:
1. `sippol_backend_database`: Menyimpan basis data `database.sqlite`.
2. `sippol_backend_storage`: Menyimpan berkas unggahan di `storage/app/public/`.

### Backup Database SQLite
```bash
docker compose exec backend cp /app/database/database.sqlite /app/storage/backup_$(date +%Y%m%d).sqlite
docker cp sippol-backend:/app/storage/backup_$(date +%Y%m%d).sqlite ./backup_database.sqlite
```

### Restore Database SQLite
```bash
docker cp ./backup_database.sqlite sippol-backend:/app/database/database.sqlite
docker compose exec backend chown www-data:www-data /app/database/database.sqlite
docker compose restart backend
```

---

## 8. Panduan Troubleshooting

1. **Gagal Unggah Gambar / Berkas Bukti (413 Request Entity Too Large)**:
   - Pastikan Reverse Proxy Host (jika ada Nginx di depan Docker) memiliki `client_max_body_size 64M;`.
2. **Error CORS saat Memanggil API**:
   - Periksa `NEXT_PUBLIC_API_URL` di `.env`. Nilai ini harus berupa URL lengkap protokol + domain/IP backend yang dapat diakses oleh browser klien.
   - Konfigurasi `config/cors.php` backend telah diset untuk mengizinkan `allowed_origins => ['*']`.
3. **Peta Leaflet atau Chart Tidak Tampil**:
   - Komponen Leaflet dan Chart.js di frontend menggunakan `dynamic(() => import(...), { ssr: false })` sehingga hanya dirender di sisi client. Pastikan tidak ada script blocker (uBlock/Brave Shields) yang memblokir asset tile peta OpenStreetMap.
