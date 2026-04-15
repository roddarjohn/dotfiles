#!/usr/bin/env bash
#
# bootstrap.sh — complete first-time setup for this dotfiles repo.
#
# Supports Linux (apt-based: Ubuntu/Debian/Pop) and macOS (Homebrew).
# Walks every section of README.md in order:
#
#   1. Packages              (apt / brew + build deps where needed)
#   2. oh-my-zsh
#   3. tree-sitter           (pinned; built from source on both OSes)
#   4. Emacs 30              (source build on both: Linux --with-pgtk,
#                             macOS --with-ns into /Applications/Emacs.app)
#   5. ./install.sh          (stow, tpm + auto plugin install, fonts,
#                             Cosmic terminal on Linux)
#   6. jsonnet-language-server            (optional, prompted)
#   7. syncthing                          (optional, prompted)
#
# Re-running is safe: every phase checks for already-done state and
# skips if so. On a fresh machine the Emacs source build dominates the
# runtime — 15-30 min on Linux, 15-30 min on macOS.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Pinned versions ──────────────────────────────────────────────────
TREE_SITTER_VERSION="v0.25.0"   # tag in tree-sitter/tree-sitter
EMACS_BRANCH="emacs-30"         # branch of emacs-mirror/emacs (both OSes)

# ── Pretty output ─────────────────────────────────────────────────────
bold()    { printf '\033[1m%s\033[0m\n' "$*"; }
step()    { printf '→ %s\n' "$*"; }
ok()      { printf '✓ %s\n' "$*"; }
skip()    { printf '• %s (skipped)\n' "$*"; }
warn()    { printf '! %s\n' "$*" >&2; }
fail()    { printf '✗ %s\n' "$*" >&2; exit 1; }
section() { echo; bold "── $* ──"; }

# ── Platform detection ───────────────────────────────────────────────
UNAME="$(uname -s)"
case "$UNAME" in
    Linux)
        PLATFORM=linux
        if ! command -v apt >/dev/null 2>&1; then
            fail "Linux support requires apt (Ubuntu/Debian/Pop)."
        fi
        ;;
    Darwin)
        PLATFORM=darwin
        ;;
    *)
        fail "Unsupported platform: $UNAME"
        ;;
esac

NCPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
bold "Platform: $PLATFORM ($UNAME), $NCPU cpu(s)"

# ── Homebrew + Xcode CLT (macOS only) ────────────────────────────────
if [ "$PLATFORM" = "darwin" ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
        warn "Xcode command-line tools are required but not installed."
        warn "Run 'xcode-select --install', complete the GUI prompt, then re-run this script."
        exit 1
    fi

    if ! command -v brew >/dev/null 2>&1; then
        section "Installing Homebrew"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        ok "Homebrew installed"
    fi

    # Always (re)load brew's shellenv so PATH/HOMEBREW_PREFIX are set
    # whether brew was just installed or already present.
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ── Sudo keep-alive ───────────────────────────────────────────────────
# Both platforms hit sudo: Linux for apt + `make install`, macOS for
# `make install` + copying Emacs.app into /Applications. Source builds
# run long enough to outlive sudo's 5-minute credential cache, so we
# refresh it in the background until the script exits.
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
ok "sudo cached; background refresher PID=$SUDO_KEEPALIVE_PID"

# ── Package abstraction ──────────────────────────────────────────────
pm_update() {
    case "$PLATFORM" in
        linux)  sudo apt update ;;
        darwin) brew update ;;
    esac
}

pm_install() {
    case "$PLATFORM" in
        linux)  sudo apt install -y "$@" ;;
        darwin) brew install "$@" ;;
    esac
}

# ── 1. Packages ───────────────────────────────────────────────────────
section "1. Packages"

if [ "$PLATFORM" = "linux" ]; then
    # README "System packages" + build deps for tree-sitter and Emacs pgtk.
    PACKAGES=(
        stow tmux zsh git pandoc wget unzip fontconfig curl
        build-essential
        autoconf automake texinfo
        libgtk-3-dev libjansson-dev libgnutls28-dev libsqlite3-dev
        libjpeg-dev libpng-dev libtiff-dev libgif-dev libxpm-dev
        libncurses-dev libxml2-dev libwebp-dev
    )
else
    # macOS: zsh/curl/unzip are system-provided; sqlite3 ships in the
    # SDK. Xcode CLT supplies make/clang. The rest of this list is
    # Emacs 30 --with-ns build deps (autoconf/automake/texinfo for
    # bootstrapping the source tree, pkg-config + gnutls/libxml2/jansson
    # for configure's feature detection) plus the user-facing tooling
    # from the README ("System packages" subset that isn't system-
    # provided on macOS).
    PACKAGES=(
        stow tmux git pandoc wget
        autoconf automake texinfo pkg-config
        gnutls libxml2 jansson
    )
fi

step "Updating package index"
pm_update
step "Installing ${#PACKAGES[@]} packages"
pm_install "${PACKAGES[@]}"
ok "packages done"

# ── 2. oh-my-zsh ─────────────────────────────────────────────────────
section "2. oh-my-zsh"
if [ -d "$HOME/.oh-my-zsh" ]; then
    skip "oh-my-zsh already present at ~/.oh-my-zsh"
else
    step "Installing oh-my-zsh (non-interactive)"
    # RUNZSH=no prevents it from dropping into a zsh subshell, CHSH=no
    # prevents it from trying to change the login shell (you can do
    # that yourself later with `chsh`).
    RUNZSH=no CHSH=no sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    ok "oh-my-zsh installed"
fi

# ── 3. tree-sitter ────────────────────────────────────────────────────
section "3. tree-sitter $TREE_SITTER_VERSION"
if [ -f /usr/local/include/tree_sitter/api.h ] || \
   [ -f /opt/homebrew/include/tree_sitter/api.h ]; then
    skip "tree-sitter headers already installed"
else
    # Plain `mktemp -d` works identically on Linux and macOS; the `-t`
    # flag has incompatible semantics between the two.
    BUILD_DIR="$(mktemp -d)/tree-sitter"
    mkdir -p "$BUILD_DIR"
    step "Cloning tree-sitter $TREE_SITTER_VERSION into $BUILD_DIR"
    git clone --depth 1 --branch "$TREE_SITTER_VERSION" \
        https://github.com/tree-sitter/tree-sitter.git "$BUILD_DIR"
    step "Compiling tree-sitter (make -j$NCPU)"
    make -C "$BUILD_DIR" -j"$NCPU"
    step "Installing tree-sitter"
    sudo make -C "$BUILD_DIR" install
    # ldconfig is Linux-only; macOS's dyld cache doesn't need it.
    if command -v ldconfig >/dev/null 2>&1; then
        sudo ldconfig
    fi
    rm -rf "$BUILD_DIR"
    ok "tree-sitter $TREE_SITTER_VERSION installed"
fi

# ── 4. Emacs 30 ───────────────────────────────────────────────────────
section "4. Emacs 30"

have_emacs_30_plus() {
    command -v emacs >/dev/null 2>&1 || return 1
    local ver
    ver="$(emacs --version 2>/dev/null | head -n1 | awk '{print $3}')"
    # Accept 30.x and anything newer (31, 32, ...).
    case "$ver" in
        3[0-9].*|[4-9][0-9].*) return 0 ;;
        *) return 1 ;;
    esac
}

if have_emacs_30_plus; then
    skip "Emacs >=30 already present: $(command -v emacs)"
else
    warn "The Emacs source build will take 15-30 minutes. Good time for coffee."

    EMACS_SRC=/opt/emacs

    if [ ! -d "$EMACS_SRC" ]; then
        step "Creating $EMACS_SRC (owned by $USER)"
        sudo mkdir -p "$EMACS_SRC"
        sudo chown "$USER:$USER" "$EMACS_SRC"
    fi

    if [ ! -d "$EMACS_SRC/.git" ]; then
        step "Cloning emacs-mirror/emacs ($EMACS_BRANCH) over HTTPS"
        # README uses git@github.com; HTTPS works without SSH keys.
        git clone --single-branch --branch "$EMACS_BRANCH" \
            https://github.com/emacs-mirror/emacs.git "$EMACS_SRC"
    fi

    cd "$EMACS_SRC"

    # Platform-specific configure flags: --with-pgtk on Linux (the
    # README's reason for source-building), --with-ns on macOS (Cocoa
    # / NextStep GUI, which builds a self-contained Emacs.app).
    case "$PLATFORM" in
        linux)
            EMACS_CONFIGURE_FLAGS=(--with-tree-sitter --with-pgtk --with-sqlite3)
            ;;
        darwin)
            EMACS_CONFIGURE_FLAGS=(--with-tree-sitter --with-ns --with-sqlite3)
            # macOS needs help finding everything configure looks for:
            #   * tree-sitter lives under /usr/local (sudo make install)
            #   * brew-installed libs (gnutls, libxml2, jansson) live
            #     under $HOMEBREW_PREFIX
            #   * texinfo from brew is keg-only, so `makeinfo` isn't on
            #     PATH until we prepend it
            HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /usr/local)}"
            export CPPFLAGS="-I/usr/local/include -I${HOMEBREW_PREFIX}/include ${CPPFLAGS:-}"
            export LDFLAGS="-L/usr/local/lib -L${HOMEBREW_PREFIX}/lib ${LDFLAGS:-}"
            export PKG_CONFIG_PATH="${HOMEBREW_PREFIX}/lib/pkgconfig:${HOMEBREW_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"
            if TEXINFO_PREFIX="$(brew --prefix texinfo 2>/dev/null)"; then
                export PATH="${TEXINFO_PREFIX}/bin:$PATH"
            fi
            ;;
    esac

    [ -f configure ] || { step "./autogen.sh"; ./autogen.sh; }
    [ -f Makefile  ] || {
        step "./configure ${EMACS_CONFIGURE_FLAGS[*]}"
        ./configure "${EMACS_CONFIGURE_FLAGS[@]}"
    }

    step "make bootstrap -j$NCPU"
    make bootstrap -j"$NCPU"

    step "Smoke test: src/emacs -Q --batch"
    if ! ./src/emacs -Q --batch --eval '(message "emacs smoke ok")'; then
        fail "Emacs smoke test failed; refusing to install."
    fi

    step "sudo make install"
    sudo make install

    if [ "$PLATFORM" = "darwin" ]; then
        # --with-ns produces nextstep/Emacs.app inside the source tree.
        # `make install` populates /usr/local/share/info etc. but leaves
        # the .app bundle where it was built — we copy it into
        # /Applications and symlink the CLI binary to /usr/local/bin.
        step "Copying nextstep/Emacs.app → /Applications/Emacs.app"
        sudo rm -rf /Applications/Emacs.app
        sudo cp -R nextstep/Emacs.app /Applications/Emacs.app

        step "Symlinking CLI: /usr/local/bin/emacs → Emacs.app"
        sudo mkdir -p /usr/local/bin
        sudo ln -sf /Applications/Emacs.app/Contents/MacOS/Emacs /usr/local/bin/emacs
    fi

    cd "$DOTFILES_DIR"
    ok "Emacs 30 installed"
fi

# ── 5. install.sh (stow, tpm+plugins, fonts, terminal) ────────────────
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
            ARCH="$(uname -m)"
            case "$PLATFORM-$ARCH" in
                linux-x86_64)        JLS_ASSET="jsonnet-language-server-linux-amd64" ;;
                linux-aarch64)       JLS_ASSET="jsonnet-language-server-linux-arm64" ;;
                darwin-x86_64)       JLS_ASSET="jsonnet-language-server-darwin-amd64" ;;
                darwin-arm64)        JLS_ASSET="jsonnet-language-server-darwin-arm64" ;;
                *)                   JLS_ASSET="" ;;
            esac
            if [ -z "$JLS_ASSET" ]; then
                warn "No matching release asset for $PLATFORM/$ARCH; skipping"
            else
                step "Resolving latest release URL for $JLS_ASSET"
                JLS_URL=$(curl -fsSL \
                    https://api.github.com/repos/grafana/jsonnet-language-server/releases/latest \
                    | grep -Eo "https://[^\"]*${JLS_ASSET}" \
                    | head -n1)
                if [ -z "${JLS_URL:-}" ]; then
                    warn "Could not find $JLS_ASSET in latest release; skipping"
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
            fi
            ;;
        *) skip "jsonnet-language-server" ;;
    esac
fi

# ── 7. syncthing (optional) ───────────────────────────────────────────
section "7. syncthing (optional)"
syncthing_already_enabled() {
    if [ "$PLATFORM" = "linux" ]; then
        systemctl --user is-enabled syncthing.service >/dev/null 2>&1
    else
        brew services list 2>/dev/null | grep -qE '^syncthing[[:space:]]+(started|running)'
    fi
}

if syncthing_already_enabled; then
    skip "syncthing already enabled"
else
    read -r -p "Install and enable syncthing for org-file sync? [y/N] " answer
    case "${answer:-}" in
        [yY]*)
            if [ "$PLATFORM" = "linux" ]; then
                step "apt install syncthing"
                sudo apt install -y syncthing
                step "Enabling syncthing user service"
                systemctl --user enable --now syncthing
            else
                step "brew install syncthing"
                brew install syncthing
                step "brew services start syncthing"
                brew services start syncthing
            fi
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
  * First Emacs launch will clone and build all straight.el packages
    (a few minutes). Subsequent launches are fast.
  * Syncthing UI is at http://localhost:8384 (only if you enabled it).

EOF
