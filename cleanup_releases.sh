#!/bin/bash

# Script para eliminar releases creados por el bucle infinito del workflow

OWNER="cvc953"
REPO="TimeLyr"

echo "Este script eliminará todos los releases v1.0.X donde X >= 100"
echo "Mantendrá: v1.0.0 y v1.0.1"
echo ""

# Verificar si existe gh CLI
if ! command -v gh &> /dev/null; then
    echo "ERROR: GitHub CLI (gh) no está instalado"
    echo "Instálalo con: sudo pacman -S github-cli"
    echo ""
    echo "O usa este comando alternativo con curl (necesitarás un token):"
    echo ""
    echo "GITHUB_TOKEN='tu_token_aqui'"
    echo "for tag in \$(git tag -l | grep -E '^v1\.0\.[0-9]{3,}\$'); do"
    echo "  echo \"Eliminando release \$tag...\""
    echo "  curl -X DELETE -H \"Authorization: token \$GITHUB_TOKEN\" \\"
    echo "    \"https://api.github.com/repos/$OWNER/$REPO/releases/tags/\$tag\""
    echo "done"
    exit 1
fi

# Verificar autenticación
if ! gh auth status &> /dev/null; then
    echo "No estás autenticado en GitHub CLI"
    echo "Ejecuta: gh auth login"
    exit 1
fi

# Contar releases a eliminar
echo "Obteniendo lista de releases..."
releases=$(gh release list --repo $OWNER/$REPO --limit 1000 | grep -E 'v1\.0\.[0-9]{3,}' | awk '{print $1}')
count=$(echo "$releases" | wc -l)

echo "Releases a eliminar: $count"
echo ""

read -p "¿Continuar? (y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "Cancelado"
    exit 0
fi

echo ""
echo "Eliminando releases..."

echo "$releases" | while read -r tag; do
    if [ -n "$tag" ]; then
        echo "Eliminando release $tag..."
        gh release delete "$tag" --repo $OWNER/$REPO --yes
    fi
done

echo ""
echo "¡Listo! Releases limpiados."
echo ""
echo "Releases restantes:"
gh release list --repo $OWNER/$REPO
