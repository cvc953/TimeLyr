#!/bin/bash

# Script para eliminar releases usando curl (sin necesidad de gh CLI)

OWNER="cvc953"
REPO="TimeLyr"

if [ -z "$GITHUB_TOKEN" ]; then
    echo "ERROR: Variable GITHUB_TOKEN no está configurada"
    echo ""
    echo "Pasos:"
    echo "1. Ve a: https://github.com/settings/tokens/new"
    echo "2. Crea un token con permisos: 'repo' y 'delete_repo'"
    echo "3. Copia el token"
    echo "4. Ejecuta: export GITHUB_TOKEN='tu_token_aqui'"
    echo "5. Vuelve a ejecutar este script"
    exit 1
fi

echo "Este script eliminará todos los releases v1.0.X donde X >= 100"
echo "Mantendrá: v1.0.0 y v1.0.1"
echo ""

# Obtener lista de releases
echo "Obteniendo lista de releases..."
page=1
all_releases=""

while true; do
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$OWNER/$REPO/releases?per_page=100&page=$page")
    
    releases=$(echo "$response" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"\(.*\)"/\1/')
    
    if [ -z "$releases" ]; then
        break
    fi
    
    all_releases="$all_releases
$releases"
    ((page++))
done

# Filtrar releases a eliminar (v1.0.100 en adelante)
to_delete=$(echo "$all_releases" | grep -E '^v1\.0\.[0-9]{3,}$' | sort -u)
count=$(echo "$to_delete" | grep -v '^$' | wc -l)

if [ $count -eq 0 ]; then
    echo "No hay releases para eliminar"
    exit 0
fi

echo "Releases a eliminar: $count"
echo ""
echo "Primeros 10 releases a eliminar:"
echo "$to_delete" | head -10
echo ""

read -p "¿Continuar? (y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "Cancelado"
    exit 0
fi

echo ""
echo "Eliminando releases..."

echo "$to_delete" | while read -r tag; do
    if [ -n "$tag" ]; then
        # Primero obtener el ID del release
        release_id=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/$OWNER/$REPO/releases/tags/$tag" | \
            grep -o '"id": *[0-9]*' | head -1 | sed 's/"id": *//')
        
        if [ -n "$release_id" ]; then
            echo "Eliminando release $tag (ID: $release_id)..."
            curl -s -X DELETE -H "Authorization: token $GITHUB_TOKEN" \
                "https://api.github.com/repos/$OWNER/$REPO/releases/$release_id"
        else
            echo "No se pudo obtener ID para $tag, omitiendo..."
        fi
    fi
done

echo ""
echo "¡Listo! Releases eliminados."
