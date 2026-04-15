# Dotfiles

Configuration files for my machines, managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Prerequisites

Install these before running the install script:

### System packages

```bash
sudo apt install \
  stow \
  tmux \
  zsh \
  git \
  pandoc \
  wget \
  unzip \
  fontconfig
```

### oh-my-zsh

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

### tree-sitter (from source)

Due to ABI grammar issues, tree-sitter often needs to be built from source:

```bash
git clone https://github.com/tree-sitter/tree-sitter.git
cd tree-sitter
git checkout v0.25.0
make
sudo make install
sudo ldconfig
```

### Emacs (from source)

Due to issues with Emacs on COSMIC, Emacs is built from source with `--with-pgtk`:

```bash
cd /opt/
sudo mkdir emacs
sudo chown $USER:$USER emacs/
git clone git@github.com:emacs-mirror/emacs.git --single-branch --branch emacs-30
cd emacs/

./autogen.sh
sudo apt install libsqlite3-dev
./configure --with-tree-sitter --with-pgtk --with-sqlite3

make bootstrap -j$(nproc)

# quick test before install
src/emacs -Q

sudo make install
```

## Install

```bash
git clone https://github.com/roddarjohn/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

The install script will:

1. Symlink all config files into `$HOME` via stow (`zsh`, `tmux`, `emacs`)
2. Install [tpm](https://github.com/tmux-plugins/tpm) (tmux plugin manager)
3. Install the Meslo Nerd Font
4. Configure the COSMIC Terminal font

After install, open tmux and press `prefix + I` to install tmux plugins via tpm.

## What's included

### Emacs

The Emacs configuration uses literate programming via `org-babel`. The main
config lives in `emacs/.emacs.d/init.org`, which tangles to `emacs-config.el`.

Key packages: straight.el (package manager), magit, forge, corfu, vertico,
consult, embark, eglot, casual-suite, copilot, org-mode, mu4e.

The custom `my-org-*` modules under `emacs/.emacs.d/lisp/` are documented in
[docs/my-org-modules.md](docs/my-org-modules.md).

### ZSH

Minimal `.zshrc` — sets Emacs as the editor and configures oh-my-zsh.

### tmux

Configures key bindings and the [tmux-nova](https://github.com/o0th/tmux-nova)
status line theme. Uses tpm for plugin management.

## Docs

Additional guides live in `docs/`:

- [`my-org-*` modules](docs/my-org-modules.md) — custom org layer for category-scoped capture/agenda, projects, and interview notes
- [Syncthing setup](docs/syncthing-setup.md) — peer-to-peer file sync across machines and Android

### LSP servers

#### jsonnet-language-server

Download a pre-built binary from the [releases page](https://github.com/grafana/jsonnet-language-server/releases):

```bash
chmod +x jsonnet-language-server
mv jsonnet-language-server ~/.local/bin/
```

Make sure `~/.local/bin` is on your `PATH`.


## Post-install

### First Emacs launch

On first launch, straight.el will clone and build all packages. This takes a few
minutes. Subsequent launches are fast.

### Syncthing (optional)

For Dropbox-like sync of org files across machines and mobile (Android/Orgzly
Revived), see [docs/syncthing-setup.md](docs/syncthing-setup.md).

Install:

```bash
sudo apt install syncthing
systemctl --user enable --now syncthing
```

Then open http://localhost:8384 to configure.
