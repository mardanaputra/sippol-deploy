# SIPPOL PP Buleleng - Panduan Deployment Produksi

Dokumentasi komprehensif ini merupakan panduan resmi (*Production Runbook*) untuk tim operasional dan DevOps dalam melakukan deployment, pemeliharaan, serta mitigasi insiden sistem **SIPPOL PP Buleleng** (Sistem Informasi Pelayanan Pengaduan & Operasional Satpol PP Kabupaten Buleleng).

---

## Daftar Isi
1. [Arsitektur Sistem & Topologi Jaringan](#1-arsitektur-sistem--topologi-jaringan)
2. [Matriks Port & Komponen Kontainer](#2-matriks-port--komponen-kontainer)
3. [Kamus Konfigurasi Lingkungan (Environment Dictionary)](#3-kamus-konfigurasi-lingkungan-environment-dictionary)
   - [Konfigurasi Backend (.env.backend)](#a-konfigurasi-backend-envbackend)
   - [Konfigurasi Frontend (.env.frontend)](#b-konfigurasi-frontend-envfrontend)
4. [Prosedur Deployment](#4-prosedur-deployment)
   - [Metode 1: Fast Path via GHCR Image (Direkomendasikan untuk Server Produksi)](#metode-1-fast-path-via-ghcr-image-direkomendasikan-untuk-server-produksi)
   - [Metode 2: Skrip Otomatisasi Satu-Klik (./deploy.sh)](#metode-2-skrip-otomatisasi-satu-klik-deploysh)
   - [Metode 3: Build Lokal dari Kode Sumber](#metode-3-build-lokal-dari-kode-sumber)
5. [Validasi Deployment & Health Check](#5-validasi-deployment--health-check)
6. [Hardening Keamanan Produksi](#6-hardening-keamanan-produksi)
7. [Konfigurasi Host Reverse Proxy & SSL](#7-konfigurasi-host-reverse-proxy--ssl)
   - [Opsi A: Nginx Reverse Proxy (Umum)](#opsi-a-nginx-reverse-proxy-umum)
   - [Opsi B: Caddy Server (Modern & Otomatis SSL)](#opsi-b-caddy-server-modern--otomatis-ssl)
8. [Prosedur Update Aplikasi & Rollback](#8-prosedur-update-aplikasi--rollback)
9. [Prosedur Pencadangan & Pemulihan (Backup & Restore)](#9-prosedur-pencadangan--pemulihan-backup--restore)
10. [Panduan Operasional Harian & Pemantauan](#10-panduan-operasional-harian--pemantauan)
11. [Matriks Penanganan Masalah (Troubleshooting Guide)](#11-matriks-penanganan-masalah-troubleshooting-guide)

---

## 1. Arsitektur Sistem & Topologi Jaringan

SIPPOL dideploy dalam 3 kontainer terisolasi (*atomic containers*) di dalam jaringan *bridge* privat Docker (`sippol-network`). Desain deployment bersifat **statik dan *immutable***: berkas `docker-compose.yml` tidak perlu diubah antar server karena seluruh parameter disalurkan via properti `env_file`.

```
                              [ Internet / Browser Warga & Admin ]
                                               │
                                      (Port 80 / Port 443 SSL)
                                               │
                                  ┌────────────▼───────────┐
                                  │   Host Reverse Proxy   │
                                  │    (Nginx / Caddy)     │
                                  └────────────┬───────────┘
                                               │
                        ┌──────────────────────┴──────────────────────┐
                        ▼ (HTTP 127.0.0.1:3000)                       ▼ (HTTP 127.0.0.1:8000)
            ┌───────────────────────┐                     ┌───────────────────────┐
            │    sippol-frontend    │                     │    sippol-backend     │
            │  (Next.js Standalone) │ ──[ internal proxy ]──>│ (Laravel + FrankenPHP)│
            └───────────┬───────────┘    http://backend:8000 └───────────┬───────────┘
                        │ (env_file)                                  │ (env_file)
                 [.env.frontend]                               [.env.backend]
                                                                      │
                                                           ┌──────────┴──────────┐
                                                           │ (sippol-network)    │
                                                           ▼ (Internal: 3306)    ▼
                                                     ┌───────────┐         ┌───────────┐
                                                     │sippol-mysql│         │  storage  │
                                                     │(MySQL 8.0)│         │ (uploads) │
                                                     └───────────┘         └───────────┘
                                                           │                     │
                                                    [mysql_data vol]     [backend_storage vol]
```

### Karakteristik Arsitektur:
1. **Frontend (Next.js 16 Standalone)**:
   - Dijalankan sebagai non-root user (`nextjs`, UID 1001) di atas `node:20-alpine`.
   - Ukuran image minimalis (~100 MB).
   - Pemanggilan API relatif `/api/*` secara otomatis diproxy oleh server Next.js ke backend melalui internal Docker bridge (`INTERNAL_BACKEND_URL=http://backend:8000`), sehingga tidak memerlukan konfigurasi CORS rumit di sisi peramban.
2. **Backend (Laravel 12 API + FrankenPHP)**:
   - Ditenagai oleh **FrankenPHP** (engine server berbasis Caddy & Go) di atas image `dunglas/frankenphp:1-php8.2-alpine`.
   - Menggantikan Nginx, PHP-FPM, dan Supervisor menjadi **1 binary atomic** dengan performa tinggi, mendukung HTTP/2, HTTP/3, serta kompresi otomatis Zstandard, Brotli, dan Gzip.
   - Konfigurasi Caddyfile telah di-hardened dengan batasan body size 64MB untuk menangani unggahan foto bukti & berkas PDF Base64.
   - **Local Bind Mount `.env.backend:/app/.env`**: Berkas `.env.backend` pada host di-mount langsung ke `/app/.env` di dalam kontainer backend. Hal ini memungkinkan perintah seperti `php artisan key:generate` langsung menimpa kunci pada berkas host secara persisten.
   - **Tanpa Cache Konfigurasi Kaku**: Sistem sengaja **tidak** menjalankan `php artisan optimize` atau `config:cache` pada saat build maupun boot kontainer. Ini memastikan perubahan nilai di `.env.backend` langsung terbaca secara dinamis tanpa perlu membersihkan cache berulang kali.
3. **Database (MySQL 8.0)**:
   - Beroperasi secara privat dalam jaringan internal Docker (port 3306 tidak diekspos ke publik host untuk keamanan maksimal).
   - Dilengkapi healthcheck native `mysqladmin ping`.

---

## 2. Matriks Port & Komponen Kontainer

| Layanan | Nama Kontainer | Port Host | Port Internal | Image Registry | Deskripsi |
|---|---|---|---|---|---|
| **Frontend** | `sippol-frontend` | `3000` | `3000/tcp` | `ghcr.io/mardanaputra/sippol-frontend:latest` | Next.js 16 App Router (UI Warga & Admin Portal) |
| **Backend** | `sippol-backend` | `8000` | `8000/tcp` | `ghcr.io/mardanaputra/sippol-backend:latest` | Laravel 12 API ditenagai FrankenPHP |
| **Database** | `sippol-mysql` | *Tidak diekspos* | `3306/tcp` | `mysql:8.0` | Basis data relasional produksi |

---

## 3. Kamus Konfigurasi Lingkungan (Environment Dictionary)

Tim deployment **tidak perlu memodifikasi `docker-compose.yml`**. Seluruh konfigurasi diatur melalui dua berkas berikut:

### A. Konfigurasi Backend (`.env.backend`)
Salin berkas template: `cp .env.backend.example .env.backend`

| Variabel | Tipe | Default / Rekomendasi | Deskripsi & Catatan |
|---|---|---|---|
| `APP_NAME` | String | `"SIPPOL PP Buleleng"` | Nama aplikasi untuk email dan logging. |
| `APP_ENV` | String | `production` | Wajib `production` pada server rilis untuk menonaktifkan debug display. |
| `APP_KEY` | String | *(Dibuat otomatis)* | Kunci enkripsi 32-karakter. Otomatis dibuat jika dikosongkan pada start pertama. |
| `APP_DEBUG` | Boolean | `false` | Wajib `false` di lingkungan produksi untuk mencegah kebocoran stack trace. |
| `APP_URL` | URL | `https://api-sippol.bulelengkab.go.id` | URL publik backend API. |
| `SERVER_NAME` | String | `:8000` | Port listen engine FrankenPHP Caddy. |
| `APP_TIMEZONE` | String | `Asia/Makassar` | Zona waktu operasional (WITA untuk Kabupaten Buleleng). |
| `DB_CONNECTION` | String | `mysql` | Driver koneksi database. |
| `DB_HOST` | Hostname | `mysql` | Nama layanan kontainer database dalam jaringan Docker. |
| `DB_PORT` | Integer | `3306` | Port internal MySQL. |
| `DB_DATABASE` | String | `sippol` | Nama skema database yang dibuat. |
| `DB_USERNAME` | String | `sippol_user` | Akun database untuk operasional Laravel. |
| `DB_PASSWORD` | String | *Rahasia Aman* | Kata sandi akun database `sippol_user`. |
| `MYSQL_ROOT_PASSWORD` | String | *Rahasia Aman* | Kata sandi superuser root MySQL di kontainer `sippol-mysql`. |
| `AUTORUN_MIGRATIONS` | Boolean | `false` | **Manual (Default)**: Migrasi database tidak dijalankan otomatis saat boot demi keamanan skema produksi. |
| `RUN_SEEDERS` | Boolean | `false` | **Manual (Default)**: Seeder hanya dijalankan manual saat inisialisasi awal server baru. |
| `RECAPTCHA_SECRET_KEY` | String | *Kunci Google Secret* | Kunci server-side untuk memvalidasi token reCAPTCHA dari halaman login admin. |

---

### B. Konfigurasi Frontend (`.env.frontend`)
Salin berkas template: `cp .env.frontend.example .env.frontend`

| Variabel | Tipe | Default / Rekomendasi | Deskripsi & Catatan |
|---|---|---|---|
| `NODE_ENV` | String | `production` | Mengaktifkan optimasi runtime Next.js production. |
| `PORT` | Integer | `3000` | Port internal aplikasi Next.js. |
| `HOSTNAME` | String | `0.0.0.0` | Mengikat server Node.js ke seluruh interface kontainer. |
| `INTERNAL_BACKEND_URL` | URL | `http://backend:8000` | **Kritis**: Alamat internal kontainer backend untuk proxy server-side Next.js. |
| `NEXT_PUBLIC_API_URL` | URL | *Kosongkan (default)* | Dikosongkan agar peramban menggunakan relative proxy `/api/*`. Jika diisi, peramban akan memanggil URL tersebut secara cross-origin. |
| `NEXT_PUBLIC_RECAPTCHA_SITE_KEY` | String | *Kunci Google Public* | Kunci publik Google reCAPTCHA v2 / v3 di formulir login admin. |

---

## 4. Prosedur Deployment

Pastikan Anda berada di direktori `sippol-deploy/`:
```bash
cd /path/to/sippol/sippol-deploy
```

### Metode 1: Fast Path via GHCR Image (Direkomendasikan untuk Server Produksi)
Metode ini adalah cara tercepat di server VPS tanpa memerlukan instalasi Node.js, PHP, atau dependensi build pada host:

1. **Siapkan berkas environment:**
   ```bash
   cp .env.backend.example .env.backend
   cp .env.frontend.example .env.frontend
   nano .env.backend   # Sesuaikan kata sandi database dan reCAPTCHA
   nano .env.frontend  # Sesuaikan site key reCAPTCHA
   ```

2. **Tarik image terbaru dari GitHub Container Registry:**
   ```bash
   docker compose pull
   ```

3. **Jalankan seluruh layanan:**
   ```bash
   docker compose up -d --remove-orphans
   ```

---

### Metode 2: Skrip Otomatisasi Satu-Klik (`./deploy.sh`)
Skrip ini akan memeriksa kelengkapan berkas `.env`, menarik image pre-built jika ada, menjalankan kompilasi jika diperlukan, dan menunggu hingga seluruh kontainer berstatus `healthy`:

```bash
chmod +x deploy.sh
./deploy.sh
```

---

### Metode 3: Build Lokal dari Kode Sumber
Jika Anda melakukan kustomisasi kode sumber lokal dan ingin mem-build ulang kontainer secara mandiri:
```bash
docker compose up -d --build --remove-orphans
```

---

### Langkah Lanjutan Wajib: Migrasi Database Manual
Demi keamanan skema produksi, migrasi database sengaja **tidak dijalankan otomatis saat boot kontainer** (`AUTORUN_MIGRATIONS=false`). Jalankan migrasi secara eksplisit setelah kontainer berstatus `healthy`:

```bash
# 1. Jalankan migrasi tabel database
docker compose exec backend php artisan migrate --force

# 2. (Khusus inisialisasi awal server baru) Jalankan seeder akun & data referensi
docker compose exec backend php artisan db:seed --force
```

*(Opsional)* Jika Anda ingin men-generate atau me-refresh `APP_KEY` secara manual di server:
```bash
docker compose exec backend php artisan key:generate
```
*Karena berkas `.env.backend` di-mount ke `/app/.env`, perintah di atas akan langsung menimpa dan menyimpan kunci baru di berkas host `.env.backend`.*

---

## 5. Validasi Deployment & Health Check

Setelah kontainer menyala, lakukan verifikasi status:

### 1. Periksa Status Kontainer Docker
```bash
docker compose ps
```
**Ekspektasi Output:**
```text
NAME              IMAGE                                         COMMAND                  STATUS                   PORTS
sippol-backend    ghcr.io/mardanaputra/sippol-backend:latest    "docker-entrypoint.s…"   Up (healthy)             0.0.0.0:8000->8000/tcp
sippol-frontend   ghcr.io/mardanaputra/sippol-frontend:latest   "docker-entrypoint.s…"   Up (healthy)             0.0.0.0:3000->3000/tcp
sippol-mysql      mysql:8.0                                     "docker-entrypoint.s…"   Up (healthy)             3306/tcp, 33060/tcp
```
> Pastikan ketiga layanan memiliki label `(healthy)`.

### 2. Uji Kesehatan Backend API
```bash
curl -i http://localhost:8000/up
```
**Respon yang Diharapkan:**
```http
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
...
Application up
```

### 3. Uji Ketersediaan Frontend
```bash
curl -I http://localhost:3000/
```
**Respon yang Diharapkan:**
```http
HTTP/1.1 200 OK
X-Powered-By: Next.js
...
```

### 4. Uji Integrasi End-to-End (Proxy Frontend ke Backend via MySQL)
```bash
curl -s http://localhost:3000/api/pengaduan/TKT-2026-99991
```
**Respon yang Diharapkan:** Objek JSON tiket pengaduan yang berasal dari seeder database MySQL.

---

## 6. Hardening Keamanan Produksi

Sebelum mempublikasikan sistem ke jaringan publik/internet:

1. **Ubah Kredensial Admin Bawaan**:
   - Akun default dari seeder: Username `admin` / Password `admin` (Role `super_admin`).
   - Masuk ke portal `/admin/login`, buka menu **Manajemen User** (`/admin/manajemen-user`), dan ganti kata sandi akun default dengan kombinasi kuat (minimal 12 karakter).
2. **Kunci Akses Berkas Environment**:
   Pastikan berkas konfigurasi tidak dapat dibaca oleh pengguna non-root di host:
   ```bash
   chmod 600 .env.backend .env.frontend
   ```
3. **Konfigurasi Firewall Host (UFW)**:
   Hanya port 80 dan 443 yang boleh dibuka ke internet publik. Port kontainer (3000, 8000) dan database (3306) tidak boleh diakses langsung dari luar:
   ```bash
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow 22/tcp    # SSH
   sudo ufw allow 80/tcp    # HTTP
   sudo ufw allow 443/tcp   # HTTPS
   sudo ufw enable
   ```

---

## 7. Konfigurasi Host Reverse Proxy & SSL

Pasang Reverse Proxy pada host utama untuk menangani terminasi SSL, HTTP/2, dan perutean domain.

### Opsi A: Nginx Reverse Proxy (Umum)

Buat file konfigurasi `/etc/nginx/sites-available/sippol.conf`:

```nginx
# 1. Frontend Web & Portal: sippol.bulelengkab.go.id
server {
    listen 80;
    server_name sippol.bulelengkab.go.id;

    client_max_body_size 64M;

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

# 2. Backend REST API: api-sippol.bulelengkab.go.id (Opsional / Direct API)
server {
    listen 80;
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

Aktifkan konfigurasi dan terbitkan sertifikat SSL gratis via Certbot:
```bash
sudo ln -s /etc/nginx/sites-available/sippol.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d sippol.bulelengkab.go.id -d api-sippol.bulelengkab.go.id
```

---

### Opsi B: Caddy Server (Modern & Otomatis SSL)

Jika host menggunakan Caddy, buat file `/etc/caddy/Caddyfile`:

```caddy
sippol.bulelengkab.go.id {
    request_body {
        max_size 64MB
    }
    reverse_proxy 127.0.0.1:3000
}

api-sippol.bulelengkab.go.id {
    request_body {
        max_size 64MB
    }
    reverse_proxy 127.0.0.1:8000
}
```
*Caddy akan secara otomatis menerbitkan dan memperbarui sertifikat SSL Let's Encrypt tanpa konfigurasi tambahan.*

---

## 8. Prosedur Update Aplikasi & Rollback

### Alur Update ke Rilis Terbaru
Setiap ada push ke branch `main`, GitHub Actions secara otomatis mem-build image baru ke GHCR. Untuk menerapkan rilis terbaru di server produksi:

```bash
cd /path/to/sippol/sippol-deploy

# 1. Tarik image terbaru dari GHCR
docker compose pull

# 2. Terapkan kontainer baru tanpa downtime lama
docker compose up -d --remove-orphans

# 3. Bersihkan image usang dari disk host
docker image prune -f
```

### Prosedur Rollback Cepat
Jika versi terbaru memiliki anomali, Anda dapat mengarahkan ke tag SHA commit sebelumnya di `docker-compose.yml`:
```yaml
backend:
  image: ghcr.io/mardanaputra/sippol-backend:sha-<commit_sebelumnya>
frontend:
  image: ghcr.io/mardanaputra/sippol-frontend:sha-<commit_sebelumnya>
```
Lalu jalankan:
```bash
docker compose up -d
```

---

## 9. Prosedur Pencadangan & Pemulihan (Backup & Restore)

### A. Backup Database MySQL
Jalankan pencadangan SQL dump secara terjadwal (misal via Cron):
```bash
docker compose exec -T mysql mysqldump -u root -p${MYSQL_ROOT_PASSWORD} sippol > /var/backups/sippol_$(date +%Y%m%d_%H%M%S).sql
gzip /var/backups/sippol_*.sql
```

### B. Restore Database MySQL
Untuk memulihkan database dari file backup SQL:
```bash
# Pastikan kontainer mysql aktif
gunzip -k /var/backups/sippol_20261105.sql.gz
cat /var/backups/sippol_20261105.sql | docker compose exec -T mysql mysql -u root -p${MYSQL_ROOT_PASSWORD} sippol
```

### C. Backup Berkas Media & Dokumen Storage (`/app/storage`)
```bash
tar -czvf /var/backups/sippol_storage_$(date +%Y%m%d).tar.gz -C $(docker volume inspect --format '{{ .Mountpoint }}' sippol_backend_storage) .
```

---

## 10. Panduan Operasional Harian & Pemantauan

| Kebutuhan | Perintah |
|---|---|
| Memantau seluruh log aktif | `docker compose logs -f` |
| Memantau log backend saja | `docker compose logs -f backend` |
| Memantau log database saja | `docker compose logs -f mysql` |
| Memantau log frontend saja | `docker compose logs -f frontend` |
| Memeriksa penggunaan CPU & Memori | `docker stats` |
| Masuk ke terminal backend | `docker compose exec backend sh` |
| Menjalankan CLI Laravel Tinker | `docker compose exec backend php artisan tinker` |
| Memeriksa daftar rute aktif | `docker compose exec backend php artisan route:list` |
| Membersihkan cache Laravel | `docker compose exec backend php artisan optimize:clear` |
| Menghentikan layanan sementara | `docker compose stop` |
| Memulai ulang layanan | `docker compose restart` |
| Mematikan kontainer | `docker compose down` |

---

## 11. Matriks Penanganan Masalah (Troubleshooting Guide)

| Gejala / Error | Kemungkinan Penyebab | Langkah Solusi |
|---|---|---|
| **Backend loop restart (`unhealthy`)** | MySQL belum siap atau kredensial di `.env.backend` salah. | Periksa log dengan `docker compose logs backend`. Pastikan `DB_HOST=mysql`, `DB_USERNAME`, dan `DB_PASSWORD` sama persis dengan kredensial MySQL. |
| **Error `413 Request Entity Too Large`** | Ukuran file bukti melampaui batas reverse proxy host. | Tambahkan direktif `client_max_body_size 64M;` pada blok Nginx host di `/etc/nginx/sites-available/sippol.conf`. |
| **Validasi Captcha Gagal pada Login Admin** | `RECAPTCHA_SECRET_KEY` atau `NEXT_PUBLIC_RECAPTCHA_SITE_KEY` belum diset atau salah domain. | Daftarkan domain resmi di [Google reCAPTCHA Admin Console](https://www.google.com/recaptcha/admin) untuk tipe v2/v3 Checkbox, lalu perbarui `.env.backend` dan `.env.frontend`. |
| **Peta Leaflet / Chart Kosong atau Crash** | Render sisi server (*SSR*) mengakses objek `window`. | Komponen peta Leaflet dan Chart di frontend dirancang dengan `dynamic(() => import(...), { ssr: false })`. Pastikan koneksi internet peramban mengizinkan pemuatan tile OpenStreetMap. |
| **Izin Tulis Storage Gagal (Permission Denied)** | Hak akses folder storage belum dimiliki user `www-data`. | Jalankan: `docker compose exec backend chown -R www-data:www-data /app/storage /app/bootstrap/cache && chmod -R 775 /app/storage`. |
| **MySQL Gagal Start (Port Conflict)** | Port 3306 pada host sudah digunakan oleh MySQL lokal. | Kontainer `sippol-mysql` pada `docker-compose.yml` sengaja tidak mengekspos port 3306 ke host untuk menghindari konflik. Bila ada mapping manual ke host, matikan MySQL lokal atau ubah binding port. |
