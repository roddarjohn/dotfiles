#!/usr/bin/env sh
set -e

DOTFILES_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"
OS="$(uname -s)"

# ── STOW ───────────────────────────────────────────────────────────────────────
if ! command -v stow >/dev/null 2>&1; then
    echo "✗ Error: stow is required but not installed" >&2
    exit 1
fi

# Never write through a symlinked path component. Historical folds and nested
# runtime links may point outside HOME, and copying through them cannot preserve
# concurrent application state safely. Run this complete preflight before
# legacy cleanup, mkdir, backups, Stow, plugin installation, fonts, or Cosmic.
reject_symlinked_components() (
    checked_path=$1
    case "$checked_path" in
        /*) ;;
        *)
            echo "✗ Refusing non-absolute managed path: $checked_path" >&2
            exit 1
            ;;
    esac
    component=
    remainder=${checked_path#/}
    while [ -n "$remainder" ]; do
        case "$remainder" in
            */*) part=${remainder%%/*}; remainder=${remainder#*/} ;;
            *) part=$remainder; remainder= ;;
        esac
        [ -n "$part" ] || continue
        component="$component/$part"
        [ -L "$component" ] || continue
        target=$(readlink "$component")
        echo "✗ Refusing symlinked managed path component: $component -> $target" >&2
        echo "  Stop applications that own this data, then manually unfold/migrate it into a real directory before rerunning install.sh." >&2
        exit 1
    done
)

COSMIC_TERM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic/com.system76.CosmicTerm/v1"
for write_directory in \
    "$HOME/.config/cosmic/com.system76.CosmicTerm/v1" \
    "$COSMIC_TERM_CONFIG" \
    "$HOME/.local/bin" \
    "$HOME/.local/share" \
    "$HOME/.local/state" \
    "$HOME/.local/share/fonts" \
    "$HOME/.pi/agent" \
    "$HOME/.claude" \
    "$HOME/.emacs.d" \
    "$HOME/.tmux/plugins/tpm" \
    "$HOME/Library/Fonts"
do
    reject_symlinked_components "$write_directory"
done

echo "→ Linking dotfiles with stow..."

# Remove legacy symlinks pointing into the old config/ layout.  Keep traversal
# portable to BSD find by scanning only the configuration roots we manage.
for root in "$HOME/.config" "$HOME/.local" "$HOME/.emacs.d" \
            "$HOME/.pi" "$HOME/.claude"; do
    [ -e "$root" ] || [ -L "$root" ] || continue
    find "$root" -type l 2>/dev/null | while IFS= read -r link; do
        case "$(readlink "$link")" in
            "$DOTFILES_DIR"/config/*) rm "$link" ;;
        esac
    done
done

# Keep runtime targets real so future writes never land in package sources.
mkdir -p "$HOME/.emacs.d"

next_backup_path() {
    source=$1
    candidate="$source.pre-stow.bak"
    suffix=0
    while [ -e "$candidate" ] || [ -L "$candidate" ]; do
        suffix=$((suffix + 1))
        candidate="$source.pre-stow.bak.$suffix"
    done
    printf '%s\n' "$candidate"
}

# Same reasoning for pi: pre-create the real ~/.pi/agent directory so non-folding
# stow links resource files and settings.json individually instead of replacing
# ~/.pi with one big symlink. That
# keeps pi's runtime data (trust.json, auth.json, npm/, sessions) as real files
# inside ~/.pi/agent rather than leaking into the dotfiles repo.
mkdir -p "$HOME/.pi/agent"
# If pi previously wrote its own settings.json, move it aside so stow can place
# the tracked symlink without a conflict. Your old settings are kept as a .bak.
if [ -f "$HOME/.pi/agent/settings.json" ] && [ ! -L "$HOME/.pi/agent/settings.json" ]; then
    pi_backup=$(next_backup_path "$HOME/.pi/agent/settings.json")
    mv "$HOME/.pi/agent/settings.json" "$pi_backup"
    echo "  • existing pi settings.json backed up to $(basename "$pi_backup")"
fi

# macOS ships neither ~/.config nor ~/.local. Pre-create both as real roots and
# use non-folding stow; whole-root symlinks can put yarn, uv/mise, gh, and
# copilot runtime data in this repo. This is a no-op on Linux when the roots
# already exist.
mkdir -p "$HOME/.config" "$HOME/.local/bin" "$HOME/.local/share" "$HOME/.local/state"

# Same reasoning again for Claude Code: pre-create the real ~/.claude directory so
# non-folding stow links tracked entries (CLAUDE.md, skills/, settings.json) into it,
# leaving Claude's own runtime data (sessions, cache, history) as real files. Most of
# the claude/ package is generated from pi/ by scripts/sync-claude-from-pi.sh;
# settings.json is the one hand/Claude-maintained file, edited in place via the symlink.
mkdir -p "$HOME/.claude"
# If Claude previously wrote its own settings.json, move it aside so stow can place
# the tracked symlink without a conflict. Your old settings are kept as a .bak.
if [ -f "$HOME/.claude/settings.json" ] && [ ! -L "$HOME/.claude/settings.json" ]; then
    claude_backup=$(next_backup_path "$HOME/.claude/settings.json")
    mv "$HOME/.claude/settings.json" "$claude_backup"
    echo "  • existing claude settings.json backed up to $(basename "$claude_backup")"
fi

STOW_PACKAGES=${DOTFILES_INSTALL_STOW_PACKAGES:-"zsh tmux emacs bin pi claude"}
# shellcheck disable=SC2086 # Deliberate package-name word splitting.
for pkg in $STOW_PACKAGES; do
    stow --no-folding "$pkg" --target="$HOME" --dir="$DOTFILES_DIR"
    echo "  ✓ $pkg"
done

# Route git hooks at the tracked .githooks/ dir so the pi -> claude sync runs on commit.
git -C "$DOTFILES_DIR" config core.hooksPath .githooks

# Used only by the fast regression test for stow idempotence.  Normal installs
# continue through every remaining setup phase.
if [ "${DOTFILES_INSTALL_STOW_ONLY:-0}" = "1" ]; then
    exit 0
fi

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
    mkdir -p "$COSMIC_TERM_CONFIG"
    echo 'font_name = "MesloLGM Nerd Font"' > "$COSMIC_TERM_CONFIG/font_name"
    echo 'font_size = 12'                   > "$COSMIC_TERM_CONFIG/font_size"
    echo "✓ Cosmic Terminal font configured"
fi

echo ""
echo "✓ All done! Restart your terminal to apply changes."
