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

# 1. Cek berkas .env
if [ ! -f .env ]; then
    echo "⚠️  Berkas .env tidak ditemukan. Menyalin dari .env.example..."
    cp .env.example .env
    echo "✅ Berkas .env berhasil dibuat. Silakan tinjau konfigurasinya jika diperlukan."
fi

# 2. Build dan jalankan kontainer
echo "📦 Membangun dan menjalankan kontainer Docker..."
docker compose up -d --build --remove-orphans

# 3. Tunggu hingga kontainer berstatus healthy
echo "⏳ Menunggu status kesehatan layanan..."
sleep 5

docker compose ps

echo "=========================================================="
echo "   🎉 Deployment Selesai!                                "
echo "   Aplikasi Frontend: http://localhost:3000              "
echo "   Backend Health:    http://localhost:8000/up           "
echo "=========================================================="
