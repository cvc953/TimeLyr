#!/bin/bash

# Script para limpiar tags creados por el bucle infinito del workflow

echo "Este script eliminará todos los tags v1.0.X donde X >= 100"
echo "Mantendrá: v1.0.0 y v1.0.1"
echo ""

# Contar cuántos tags se eliminarán
count=$(git tag -l | grep -E '^v1\.0\.[0-9]{3,}$' | wc -l)
echo "Tags a eliminar: $count"
echo ""

read -p "¿Continuar? (y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "Cancelado"
    exit 0
fi

echo ""
echo "Eliminando tags localmente..."

# Eliminar tags localmente (v1.0.100 en adelante)
git tag -l | grep -E '^v1\.0\.[0-9]{3,}$' | xargs git tag -d

echo ""
echo "Eliminando tags del remoto..."

# Eliminar tags del remoto
git tag -l | grep -E '^v1\.0\.[0-9]{3,}$' | xargs -I {} git push origin :refs/tags/{}

echo ""
echo "¡Listo! Tags limpiados."
echo ""
echo "Tags restantes:"
git tag -l
