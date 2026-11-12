#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Échec de l’installation à la ligne $LINENO." >&2' ERR

if [[ "$EUID" -eq 0 ]]; then
    echo "Lance ce script avec ton utilisateur habituel, sans sudo."
    exit 1
fi

if ! command -v dnf >/dev/null 2>&1; then
    echo "Ce script est prévu pour Fedora avec DNF."
    exit 1
fi

echo "[1/4] Installation des dépendances..."
sudo dnf install -y golang gcc git

echo "[2/4] Installation de Katana..."
mkdir -p "$HOME/.local/bin"

GOTOOLCHAIN=auto \
CGO_ENABLED=1 \
GOBIN="$HOME/.local/bin" \
go install github.com/projectdiscovery/katana/cmd/katana@latest

echo "[3/4] Configuration du PATH pour Bash..."
touch "$HOME/.bashrc"

path_line='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$path_line" "$HOME/.bashrc"; then
    printf '\n%s\n' "$path_line" >> "$HOME/.bashrc"
fi

echo "[4/4] Vérification..."
"$HOME/.local/bin/katana" -version

echo
echo "Katana est installé."
echo "Dans ton terminal actuel, lance : source ~/.bashrc"
