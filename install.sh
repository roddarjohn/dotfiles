#!/usr/bin/env sh
set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-config.yaml}"

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq is required" >&2
    exit 1
fi

yq -r '.links[] | .src + "|" + .dst' "$CONFIG" | while IFS='|' read -r src dst; do
    dst="$(eval echo "$dst")"
    src="$DOTFILES_DIR/$src"

    if [ ! -e "$src" ]; then
        echo "Warning: source not found: $src"
        continue
    fi

    mkdir -p "$(dirname "$dst")"

    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        mv "$dst" "${dst}.bak"
        echo "Backed up: $dst -> ${dst}.bak"
    fi

    ln -sf "$src" "$dst"
    echo "Linked: $src -> $dst"
done
