#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Échec à la ligne $LINENO." >&2' ERR

if [[ "$EUID" -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

echo "[1/3] Mise à jour de la liste des paquets..."
"${SUDO[@]}" apt update

echo "[2/3] Installation de Katana..."
"${SUDO[@]}" apt install -y katana

echo "[3/3] Vérification..."
/usr/bin/katana -version

echo "Installation de Katana terminée."
