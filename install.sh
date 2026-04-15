#!/usr/bin/env sh
set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"

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

# Wipe and recreate target directories before stowing.
# If a target directory doesn't exist, stow replaces it with a single symlink
# (e.g. ~/.emacs.d -> dotfiles/emacs/.emacs.d), causing Emacs runtime data
# (elpa/, straight/, history, etc.) to land inside the dotfiles repo.
# A pre-existing real directory forces stow to symlink individual files instead.
rm -rf "$HOME/.emacs.d"
mkdir -p "$HOME/.emacs.d"

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

# ── TMUX PLUGINS (automatic prefix+I) ──────────────────────────────────────────
# Drives tpm's headless plugin installer so you don't have to open tmux
# and press `prefix + I`. Needs the stowed ~/.tmux.conf to already be
# in place (stow ran above), so tpm can discover which plugins to fetch.
if command -v tmux >/dev/null 2>&1 && [ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]; then
    echo "→ Installing tmux plugins via tpm..."
    if "$HOME/.tmux/plugins/tpm/bin/install_plugins" >/dev/null 2>&1; then
        echo "✓ tmux plugins installed"
    else
        echo "! tpm install_plugins failed — open tmux and press 'prefix + I' to install manually" >&2
    fi
fi

# ── FONTS ──────────────────────────────────────────────────────────────────────
case "$OS" in
    Linux)
        if command -v fc-list >/dev/null 2>&1 && fc-list | grep -qi "meslo"; then
            echo "✓ Meslo Nerd Font already installed, skipping"
        else
            echo "→ Installing Meslo Nerd Font..."
            mkdir -p "$HOME/.local/share/fonts"
            ZIP="$(mktemp)"
            wget -q --show-progress -O "$ZIP" \
                https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip
            unzip -qo "$ZIP" -d "$HOME/.local/share/fonts"
            rm -f "$ZIP"
            fc-cache -fv >/dev/null
            echo "✓ Meslo Nerd Font installed"
        fi
        ;;
    Darwin)
        if ls "$HOME/Library/Fonts"/MesloLG*.ttf >/dev/null 2>&1; then
            echo "✓ Meslo Nerd Font already installed, skipping"
        else
            echo "→ Installing Meslo Nerd Font..."
            mkdir -p "$HOME/Library/Fonts"
            TMP="$(mktemp -d)"
            curl -fsSL -o "$TMP/Meslo.zip" \
                https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip
            unzip -qo "$TMP/Meslo.zip" -d "$TMP/Meslo"
            cp "$TMP/Meslo"/*.ttf "$HOME/Library/Fonts/" 2>/dev/null || true
            rm -rf "$TMP"
            echo "✓ Meslo Nerd Font installed"
        fi
        ;;
esac

# ── COSMIC TERMINAL (Linux only) ───────────────────────────────────────────────
if [ "$OS" = "Linux" ]; then
    echo "→ Configuring Cosmic Terminal font..."
    COSMIC_TERM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicTerm/v1"
    mkdir -p "$COSMIC_TERM_CONFIG"
    echo 'font_name = "MesloLGM Nerd Font"' > "$COSMIC_TERM_CONFIG/font_name"
    echo 'font_size = 12'                   > "$COSMIC_TERM_CONFIG/font_size"
    echo "✓ Cosmic Terminal font configured"
fi

echo ""
echo "✓ All done! Restart your terminal to apply changes."
