#!/usr/bin/env bash
set -e

# ==============================================================================
# SIPPOL PP Buleleng - One-Click Deployment Script
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================================="
echo "   🚀 Memulai Deployment SIPPOL PP Buleleng               "
echo "=========================================================="

# 1. Pastikan .env.backend ada
if [ ! -f .env.backend ]; then
    if [ -f .env.backend.example ]; then
        echo "⚠️  .env.backend tidak ditemukan. Menyalin dari .env.backend.example..."
        cp .env.backend.example .env.backend
    elif [ -f ../sippol-backend/.env.example ]; then
        echo "⚠️  .env.backend tidak ditemukan. Mengambil dari ../sippol-backend/.env.example..."
        cp ../sippol-backend/.env.example .env.backend
    else
        touch .env.backend
    fi
    echo "✅ Berkas .env.backend telah disiapkan."
fi

# 2. Pastikan .env.frontend ada
if [ ! -f .env.frontend ]; then
    if [ -f .env.frontend.example ]; then
        echo "⚠️  .env.frontend tidak ditemukan. Menyalin dari .env.frontend.example..."
        cp .env.frontend.example .env.frontend
    elif [ -f ../sippol-frontend/.env.example ]; then
        echo "⚠️  .env.frontend tidak ditemukan. Mengambil dari ../sippol-frontend/.env.example..."
        cp ../sippol-frontend/.env.example .env.frontend
    else
        touch .env.frontend
    fi
    echo "✅ Berkas .env.frontend telah disiapkan."
fi

# 3. Pull image dari GHCR jika tersedia, lalu jalankan
echo "📦 Menarik image dari GHCR dan menjalankan layanan..."
docker compose pull 2>/dev/null || true
docker compose up -d --build --remove-orphans

# 4. Tunggu hingga kontainer berstatus healthy
echo "⏳ Menunggu status kesehatan layanan..."
sleep 5

docker compose ps

echo "=========================================================="
echo "   🎉 Deployment Selesai!                                "
echo "   Aplikasi Frontend: http://localhost:3000              "
echo "   Backend Health:    http://localhost:8000/up           "
echo ""
echo "   ℹ️  Database migration bersifat manual:"
echo "   Jalankan: docker compose exec backend php artisan migrate --force"
echo "   (Opsional) Seeder: docker compose exec backend php artisan db:seed --force"
echo "=========================================================="
