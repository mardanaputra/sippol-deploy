# SIPPOL PP Buleleng - Panduan Deployment

Dokumentasi ini menjelaskan prosedur deployment produksi untuk aplikasi **SIPPOL PP Buleleng** (Sistem Informasi Pelayanan Pengaduan & Operasional Satpol PP Kabupaten Buleleng) menggunakan kontainer Docker atomic (MySQL 8.0, FrankenPHP Laravel 12 API, dan Next.js 16 Standalone) dengan konfigurasi lingkungan terpisah (**`.env.backend`** dan **`.env.frontend`**).

---

## 1. Arsitektur Deployment & Pola `env_file`

Berkas `docker-compose.yml` dirancang bersifat **statik dan *immutable*** (tidak perlu diubah saat melakukan deploy antar server atau lingkungan).

Seluruh variabel konfigurasi disalurkan menggunakan properti `env_file`:
- Layanan **`mysql`**: Mengambil kredensial database (`MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD`) yang diwariskan dari **`.env.backend`**.
- Layanan **`backend`**: Membaca seluruh variabel Laravel dan koneksi database dari **`.env.backend`**.
- Layanan **`frontend`**: Membaca konfigurasi aplikasi peramban & proxy dari **`.env.frontend`**.

```
                                      [ Browser / Warga & Admin ]
                                                   │
                        ┌──────────────────────────┴──────────────────────────┐
                        ▼ (Port 3000)                                         ▼ (Port 8000)
            ┌───────────────────────┐                             ┌───────────────────────┐
            │    sippol-frontend    │                             │    sippol-backend     │
            │  (Next.js Standalone) │ ──[ internal proxy /api ]──>│ (Laravel + FrankenPHP)│
            └───────────┬───────────┘                             └───────────┬───────────┘
                        │ (env_file)                                          │ (env_file)
                 [.env.frontend]                                       [.env.backend]
                                                                              │
                                                                   ┌──────────┴──────────┐
                                                                   ▼                     ▼
                                                             [sippol-mysql]       [Storage Volume]
                                                              (MySQL 8.0)        (foto & berkas BAP)
```

1. **`sippol-mysql` (Database Service)**:
   - MySQL 8.0 dengan volume persisten `sippol_mysql_data`.
   - Menggunakan kredensial yang ditentukan di `.env.backend` (`DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`).
   - Dilengkapi healthcheck `mysqladmin ping` untuk memastikan database siap menerima koneksi sebelum backend memulai migrasi.
2. **`sippol-backend` (Port 8000)**:
   - **Image Publik GHCR**: `ghcr.io/mardanaputra/sippol-backend:latest` (dan alias `ghcr.io/mardanaputra/sippol-backed:latest`).
   - Laravel 12 API ditenagai oleh **FrankenPHP** (engine server modern berbasis Caddy & Go) di atas image `dunglas/frankenphp:1-php8.2-alpine`.
   - Menghilangkan kebutuhan Nginx, PHP-FPM, dan Supervisor terpisah menjadi **1 binary atomic** berkinerja tinggi.
   - Entrypoint otomatis menunggu kesiapan MySQL, menjalankan migrasi, dan menyemai data awal.
   - Healthcheck bawaan Laravel di `/up`.
3. **`sippol-frontend` (Port 3000)**:
   - **Image Publik GHCR**: `ghcr.io/mardanaputra/sippol-frontend:latest`.
   - Next.js 16.2.6 Standalone pada image minimal `node:20-alpine` (~100 MB).
   - Menjalankan server Node.js non-root (`nextjs`, UID 1001).
   - Membaca konfigurasi dari `.env.frontend` (`INTERNAL_BACKEND_URL`, `NEXT_PUBLIC_*`).
   - Healthcheck di root `/`.

---

## 2. Persyaratan Sistem

- **Sistem Operasi**: Linux (Ubuntu 22.04/24.04 LTS), macOS, atau Windows WSL2.
- **Docker Engine**: Versi 24.0+ atau lebih baru.
- **Docker Compose**: Versi v2.20+ (sintaks `docker compose`).
- **RAM**: Minimal 2 GB (Rekomendasi 4 GB untuk MySQL dan build Next.js).
- **Ruang Disk**: Minimal 10 GB kosong.

---

## 3. Panduan untuk Tim Deployment (Inisialisasi Environment)

Tim deployment **tidak perlu mengubah berkas `docker-compose.yml`**. Cukup siapkan dua berkas `.env` berikut:

### Langkah 1: Siapkan Konfigurasi Backend (`.env.backend`)
Salin template konfigurasi dari `sippol-deploy/.env.backend.example` atau langsung dari repositori backend (`sippol-backend/.env.example`):
```bash
# Opsi A: Salin dari template deploy
cp .env.backend.example .env.backend

# Opsi B: Ambil langsung dari source backend
cp ../sippol-backend/.env.example .env.backend
```

**Variabel database di `.env.backend` (otomatis diwariskan ke kontainer MySQL):**
```ini
DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=sippol
DB_USERNAME=sippol_user
DB_PASSWORD=rahasia_aman_anda

# Opsional: Password root MySQL (bila tidak diset, menggunakan nilai DB_PASSWORD)
MYSQL_ROOT_PASSWORD=rahasia_root_anda
```

---

### Langkah 2: Siapkan Konfigurasi Frontend (`.env.frontend`)
Salin template konfigurasi dari `sippol-deploy/.env.frontend.example` atau langsung dari repositori frontend (`sippol-frontend/.env.example`):
```bash
# Opsi A: Salin dari template deploy
cp .env.frontend.example .env.frontend

# Opsi B: Ambil langsung dari source frontend
cp ../sippol-frontend/.env.example .env.frontend
```

**Variabel penting di `.env.frontend`:**
- `INTERNAL_BACKEND_URL`: URL internal kontainer Docker (`http://backend:8000`). Next.js server menggunakan nilai ini untuk meneruskan pemanggilan `/api/*`.
- `NEXT_PUBLIC_API_URL`: Dikosongkan secara default agar peramban menggunakan proxy relatif `/api/*` secara otomatis, atau diisi domain API publik jika backend diakses secara cross-origin langsung (misal: `https://api-sippol.bulelengkab.go.id`).
- `NEXT_PUBLIC_RECAPTCHA_SITE_KEY`: Kunci publik Google reCAPTCHA v2 / v3 di sisi client.

---

### Langkah 3: Jalankan Deployment

Gunakan skrip otomatisasi satu klik:
```bash
./deploy.sh
```

Atau jalankan perintah docker compose standar:
```bash
docker compose up -d --build
```

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
| `docker compose logs -f` | Memantau seluruh log aplikasi (MySQL, Backend, Frontend) |
| `docker compose logs -f mysql` | Memantau log database MySQL |
| `docker compose logs -f backend` | Memantau log FrankenPHP / Laravel |
| `docker compose logs -f frontend` | Memantau log frontend Next.js |
| `docker compose restart` | Memulai ulang seluruh kontainer |
| `docker compose stop` | Menghentikan seluruh kontainer tanpa menghapus data |
| `docker compose down` | Mematikan dan melepas kontainer |
| `docker compose down -v` | ⚠️ Menghapus kontainer beserta volume data database MySQL |
| `docker compose exec mysql mysql -u sippol_user -p sippol` | Membuka MySQL CLI di kontainer database |
| `docker compose exec backend php artisan tinker` | Membuka Laravel Tinker CLI |

---

## 7. Prosedur Pencadangan (Backup & Restore MySQL)

Data persisten disimpan pada named volume Docker:
1. `sippol_mysql_data`: Menyimpan seluruh tabel basis data MySQL di `/var/lib/mysql`.
2. `sippol_backend_storage`: Menyimpan berkas unggahan di `/app/storage/app/public/`.

### Backup Database MySQL (mysqldump)
```bash
docker compose exec mysql mysqldump -u root -p${MYSQL_ROOT_PASSWORD:-sippol_secret} sippol > backup_sippol_$(date +%Y%m%d).sql
```

### Restore Database MySQL
```bash
cat backup_sippol_20261105.sql | docker compose exec -T mysql mysql -u root -p${MYSQL_ROOT_PASSWORD:-sippol_secret} sippol
```
