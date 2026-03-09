#!/usr/bin/env sh
set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── STOW ───────────────────────────────────────────────────────────────────────
if ! command -v stow >/dev/null 2>&1; then
    echo "✗ Error: stow is required but not installed" >&2
    exit 1
fi

echo "→ Linking dotfiles with stow..."

# Remove any existing symlinks pointing into the old config/ layout
find "$HOME" -maxdepth 4 -type l 2>/dev/null | while read -r link; do
    case "$(readlink "$link")" in
        "$DOTFILES_DIR"/config/*) rm "$link" ;;
    esac
done

for pkg in zsh tmux emacs; do
    stow "$pkg" --target="$HOME" --dir="$DOTFILES_DIR"
    echo "  ✓ $pkg"
done

# ── TPM ────────────────────────────────────────────────────────────────────────
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "→ Installing tpm..."
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    echo "✓ tpm installed"
else
    echo "✓ tpm already installed, skipping"
fi

# ── FONTS ──────────────────────────────────────────────────────────────────────
if fc-list | grep -qi "meslo"; then
    echo "✓ Meslo Nerd Font already installed, skipping"
else
    echo "→ Installing Meslo Nerd Font..."
    mkdir -p ~/.local/share/fonts
    cd ~/.local/share/fonts
    wget -q --show-progress https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip
    unzip -qo Meslo.zip
    rm -f Meslo.zip
    fc-cache -fv >/dev/null
    echo "✓ Meslo Nerd Font installed"
fi

# ── COSMIC TERMINAL ────────────────────────────────────────────────────────────
echo "→ Configuring Cosmic Terminal font..."
COSMIC_TERM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicTerm/v1"
mkdir -p "$COSMIC_TERM_CONFIG"
echo 'font_name = "MesloLGM Nerd Font"' > "$COSMIC_TERM_CONFIG/font_name"
echo 'font_size = 12'                   > "$COSMIC_TERM_CONFIG/font_size"
echo "✓ Cosmic Terminal font configured"

echo ""
echo "✓ All done! Restart your terminal to apply changes."
