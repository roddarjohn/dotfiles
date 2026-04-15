#!/usr/bin/env bash
#
# bootstrap.sh — complete first-time setup for this dotfiles repo.
#
# Walks through every step documented in README.md's Prerequisites and
# Install sections:
#
#   1. APT packages (README "System packages" + build deps for 2-4)
#   2. oh-my-zsh
#   3. tree-sitter v0.25.0  (built from source)
#   4. Emacs 30             (built from source with --with-pgtk)
#   5. ./install.sh         (stow, tpm, Meslo Nerd Font, Cosmic terminal)
#   6. jsonnet-language-server                 (optional, prompted)
#   7. syncthing + user service                (optional, prompted)
#
# The Emacs build alone typically takes 15-30 minutes on a laptop, so
# the whole script can run for an hour on a fresh machine. Re-running
# is safe: each phase checks whether its work is already done and
# skips it if so.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Pretty output ─────────────────────────────────────────────────────
bold()    { printf '\033[1m%s\033[0m\n' "$*"; }
step()    { printf '→ %s\n' "$*"; }
ok()      { printf '✓ %s\n' "$*"; }
skip()    { printf '• %s (skipped)\n' "$*"; }
warn()    { printf '! %s\n' "$*" >&2; }
fail()    { printf '✗ %s\n' "$*" >&2; exit 1; }
section() { echo; bold "── $* ──"; }

# ── Platform check ───────────────────────────────────────────────────
if ! command -v apt >/dev/null 2>&1; then
    fail "This bootstrap only supports apt-based systems (Ubuntu/Debian/Pop)."
fi

# ── Sudo keep-alive ───────────────────────────────────────────────────
# The Emacs build will easily outlive sudo's 5-minute credential cache.
# Prime it once up-front, then refresh in the background until we exit.
section "Priming sudo"
sudo -v
(
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done
) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
ok "sudo credentials cached; background refresher PID=$SUDO_KEEPALIVE_PID"

# ── 1. APT packages ───────────────────────────────────────────────────
section "1. APT packages"

# This set is a superset of the README's "System packages" list plus
# the build dependencies needed to build tree-sitter and an Emacs 30
# pgtk binary. apt install is a no-op for already-installed packages,
# so re-running is cheap.
APT_PACKAGES=(
    # README "System packages"
    stow tmux zsh git pandoc wget unzip fontconfig curl
    # tree-sitter build
    build-essential
    # Emacs 30 pgtk build deps
    autoconf automake texinfo
    libgtk-3-dev libjansson-dev libgnutls28-dev libsqlite3-dev
    libjpeg-dev libpng-dev libtiff-dev libgif-dev libxpm-dev
    libncurses-dev libxml2-dev libwebp-dev
)

step "apt update"
sudo apt update
step "Installing ${#APT_PACKAGES[@]} packages (system + build deps)"
sudo apt install -y "${APT_PACKAGES[@]}"
ok "apt packages done"

# ── 2. oh-my-zsh ─────────────────────────────────────────────────────
section "2. oh-my-zsh"
if [ -d "$HOME/.oh-my-zsh" ]; then
    skip "oh-my-zsh already present at ~/.oh-my-zsh"
else
    step "Running the upstream oh-my-zsh installer (non-interactive)"
    # RUNZSH=no prevents it from dropping us into a zsh subshell.
    # CHSH=no prevents it from trying to run chsh (which would prompt
    # for a password and, more importantly, is something the user can
    # decide for themselves later).
    RUNZSH=no CHSH=no sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    ok "oh-my-zsh installed"
fi

# ── 3. tree-sitter (from source) ──────────────────────────────────────
section "3. tree-sitter v0.25.0"
if [ -f /usr/local/include/tree_sitter/api.h ]; then
    skip "tree-sitter headers already present at /usr/local/include/tree_sitter"
else
    BUILD_DIR="$(mktemp -d -t tree-sitter-XXXXXX)"
    step "Cloning tree-sitter v0.25.0 into $BUILD_DIR"
    git clone --depth 1 --branch v0.25.0 \
        https://github.com/tree-sitter/tree-sitter.git "$BUILD_DIR"
    step "Compiling tree-sitter (make -j$(nproc))"
    make -C "$BUILD_DIR" -j"$(nproc)"
    step "Installing tree-sitter to /usr/local (sudo make install + ldconfig)"
    sudo make -C "$BUILD_DIR" install
    sudo ldconfig
    rm -rf "$BUILD_DIR"
    ok "tree-sitter v0.25.0 installed"
fi

# ── 4. Emacs 30 (from source) ─────────────────────────────────────────
section "4. Emacs 30 (pgtk, tree-sitter, sqlite3)"
EMACS_SRC=/opt/emacs

if [ -x /usr/local/bin/emacs ] && \
   /usr/local/bin/emacs --version 2>/dev/null | grep -q '^GNU Emacs 30'; then
    skip "Emacs 30 already installed at /usr/local/bin/emacs"
else
    warn "The Emacs build will take 15-30 minutes. This is a good time for coffee."

    if [ ! -d "$EMACS_SRC" ]; then
        step "Creating $EMACS_SRC (owned by $USER)"
        sudo mkdir -p "$EMACS_SRC"
        sudo chown "$USER:$USER" "$EMACS_SRC"
    fi

    if [ ! -d "$EMACS_SRC/.git" ]; then
        step "Cloning emacs-mirror/emacs (branch emacs-30) into $EMACS_SRC"
        # README uses git@github.com; we use HTTPS so it works without
        # SSH keys on a fresh machine.
        git clone --single-branch --branch emacs-30 \
            https://github.com/emacs-mirror/emacs.git "$EMACS_SRC"
    fi

    cd "$EMACS_SRC"

    if [ ! -f configure ]; then
        step "./autogen.sh"
        ./autogen.sh
    fi

    if [ ! -f Makefile ]; then
        step "./configure --with-tree-sitter --with-pgtk --with-sqlite3"
        ./configure --with-tree-sitter --with-pgtk --with-sqlite3
    fi

    step "make bootstrap -j$(nproc)"
    make bootstrap -j"$(nproc)"

    step "Smoke test: src/emacs -Q --batch"
    if ! ./src/emacs -Q --batch --eval '(message "emacs smoke ok")'; then
        fail "Emacs smoke test failed; refusing to install."
    fi

    step "sudo make install"
    sudo make install
    cd "$DOTFILES_DIR"
    ok "Emacs 30 installed to /usr/local/bin/emacs"
fi

# ── 5. install.sh (stow, tpm, fonts, terminal config) ─────────────────
section "5. Dotfiles install.sh"
step "Running $DOTFILES_DIR/install.sh"
"$DOTFILES_DIR/install.sh"
ok "install.sh complete"

# ── 6. jsonnet-language-server (optional) ─────────────────────────────
section "6. jsonnet-language-server (optional)"
if [ -x "$HOME/.local/bin/jsonnet-language-server" ]; then
    skip "jsonnet-language-server already at ~/.local/bin"
else
    read -r -p "Install jsonnet-language-server from GitHub releases? [y/N] " answer
    case "${answer:-}" in
        [yY]*)
            step "Resolving latest release asset URL"
            JLS_URL=$(curl -fsSL \
                https://api.github.com/repos/grafana/jsonnet-language-server/releases/latest \
                | grep -Eo 'https://[^"]*jsonnet-language-server-linux-amd64' \
                | head -n1)
            if [ -z "${JLS_URL:-}" ]; then
                warn "Could not resolve release URL; skipping"
            else
                mkdir -p "$HOME/.local/bin"
                step "Downloading $JLS_URL"
                curl -fsSL "$JLS_URL" -o "$HOME/.local/bin/jsonnet-language-server"
                chmod +x "$HOME/.local/bin/jsonnet-language-server"
                ok "jsonnet-language-server installed to ~/.local/bin"
                case ":${PATH:-}:" in
                    *":$HOME/.local/bin:"*) ;;
                    *) warn "~/.local/bin is not on your PATH — add it to use the LSP" ;;
                esac
            fi
            ;;
        *) skip "jsonnet-language-server" ;;
    esac
fi

# ── 7. syncthing (optional) ───────────────────────────────────────────
section "7. syncthing (optional)"
if systemctl --user is-enabled syncthing.service >/dev/null 2>&1; then
    skip "syncthing user service already enabled"
else
    read -r -p "Install and enable syncthing for org-file sync? [y/N] " answer
    case "${answer:-}" in
        [yY]*)
            step "Installing syncthing"
            sudo apt install -y syncthing
            step "Enabling syncthing user service"
            systemctl --user enable --now syncthing
            ok "syncthing running; open http://localhost:8384 to configure"
            ;;
        *) skip "syncthing" ;;
    esac
fi

# ── Done ──────────────────────────────────────────────────────────────
section "All done"
cat <<'EOF'

Manual follow-ups (not automated):

  * Restart your terminal (or `source ~/.zshrc`) to pick up zsh config.
  * `chsh -s $(which zsh)` if you want zsh as your login shell.
  * Launch tmux and press `prefix + I` to install plugins via tpm.
  * First Emacs launch will clone and build all straight.el packages
    (a few minutes). Subsequent launches are fast.
  * Syncthing UI is at http://localhost:8384 (only if you enabled it).

EOF
