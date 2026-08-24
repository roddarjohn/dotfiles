# Dotfiles

Configuration files for my machines, managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Quick start (fresh machine)

```bash
git clone https://github.com/roddarjohn/dotfiles.git ~/dotfiles
cd ~/dotfiles
./bootstrap.sh
```

`bootstrap.sh` automates everything under Prerequisites and Install below:
apt packages, oh-my-zsh, building tree-sitter and Emacs 30 from source,
running `install.sh`, installing the pinned Python LSP stack (uv,
rassumfrassum, BasedPyright, and a cached Zuban fallback), and (optionally,
with prompts) installing
`jsonnet-language-server`, `regal`, `tofu-ls`, `terragrunt-ls`,
`copilot-language-server`, `mise`, `syncthing`, and the `pi` coding agent
CLI. Each phase is idempotent, so
re-running is safe. Expect ~1 hour on a fresh machine (most of it
waiting on the Emacs build).

The rest of this README is the manual breakdown of what `bootstrap.sh`
does — read it if you want to run individual steps yourself or
understand what's being installed.

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

1. Refuse any symlinked component of a managed write path before making
   changes, including nested paths such as `~/.local/bin` and `~/.pi/agent` as
   well as managed roots. Stop the applications that own those paths and
   manually migrate historical folds or foreign links to real directories
   first. With real paths, link tracked files via non-folding stow
   (`zsh`, `tmux`, `emacs`, `bin`, `pi`, `claude`)
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
status line theme. Uses tpm for plugin management. Also enables extended key
reporting (`extended-keys on` / `extended-keys-format csi-u`) so modified keys
like `Shift+Enter` survive inside the [pi](https://pi.dev) coding agent.

### pi

Config and resources for the [pi](https://pi.dev) coding agent, symlinked into
`~/.pi/agent/` via stow. The `pi/.pi/agent/{skills,extensions,prompts,themes}/`
directories are the drop-in points for installing skills, extensions, prompt
templates, and themes — add a file or directory there and it's live. See
[docs/pi.md](docs/pi.md) for the layout and how to add a skill or extension.

## Docs

Additional guides live in `docs/`:

- [`my-org-*` modules](docs/my-org-modules.md) — custom org layer for category-scoped capture/agenda, projects, and interview notes
- [pi](docs/pi.md) — coding-agent config plus the symlink framework for installing skills, extensions, prompts, and themes
- [Syncthing setup](docs/syncthing-setup.md) — peer-to-peer file sync across machines and Android

### LSP servers

#### Python: BasedPyright + Zuban

Python buffers use a single Eglot connection multiplexed by
[rassumfrassum](https://pypi.org/project/rassumfrassum/). BasedPyright owns
completion, resolve, and auto-import edits; Zuban is the only diagnostic
provider. The routing policy is tracked at
`emacs/.emacs.d/lsp/rass_zuban.py`, while `init.org` remains the authoritative
Emacs configuration.

`bootstrap.sh` installs `rassumfrassum==0.3.4` and
`basedpyright==1.39.10` from public PyPI, installing uv `0.11.26` into
`~/.local/bin` when uv is absent or a different version is found. It also caches the `zuban==0.9.1` fallback. A project can own a
different server version by installing `basedpyright-langserver` or `zuban` in
its `.venv/bin`. Eglot searches upward from the current buffer for the nearest
`.venv/bin/python`, activates that environment for the whole composite process,
and prefers either server executable found there. Missing executables use the
bootstrapped BasedPyright or pinned `uvx --no-config` Zuban fallback while still
resolving editable and related imports from the activated workspace venv.
Bootstrap and Eglot remove inherited uv/pip index, no-index, strategy, and
find-links variables before every pinned operation, force uv's `first-index`
strategy with public PyPI, and give Rass only the tracked routing directory on
`PYTHONPATH`.

Run the local gate after changing the router, contact, bootstrap, or tests:

```bash
scripts/test-python-lsp.sh
```

The gate runs standard-library Python/ERT tests plus an Emacs tangle/read
syntax check through the installed `rassumfrassum==0.3.4` uv-tool interpreter,
without resolving packages during the gate, and enforces a two-second budget. The tracked
pre-commit hook invokes it only when a relevant file is staged, then rejects
unstaged or untracked drift across every gate input before testing.

Run the slower real-server Emacs smoke manually after changing server behavior:

```bash
scripts/test-python-lsp-live.sh
```

It requires Emacs 30 or newer plus the bootstrapped tools, prints the tested
Emacs version, builds a project venv containing `.pth`-linked editable
dependencies but no language servers, poisons the inherited virtualenv and
`PATH`, and verifies both servers resolve the workspace venv, Path completion
resolve plus its `pathlib` auto-import edit, Zuban-only Flymake diagnostics,
clean Rass shutdown, and absence of orphan child servers. This manual smoke is the
Emacs-30 acceptance;
CI may use its distro Emacs only for fast ERT compatibility. Shutdown warnings,
forced termination, and non-zero process status fail the smoke. It is
intentionally outside the sub-two-second pre-commit gate.

#### jsonnet-language-server

Download a pre-built binary from the [releases page](https://github.com/grafana/jsonnet-language-server/releases):

```bash
chmod +x jsonnet-language-server
mv jsonnet-language-server ~/.local/bin/
```

Make sure `~/.local/bin` is on your `PATH`.

#### regal (Rego)

Eglot drives `.rego` files with [Regal](https://github.com/open-policy-agent/regal)'s
language server. Download a pre-built binary from the
[releases page](https://github.com/open-policy-agent/regal/releases):

```bash
chmod +x regal
mv regal ~/.local/bin/
```

Make sure `~/.local/bin` is on your `PATH`.

#### tofu-ls (OpenTofu / Terraform / HCL)

Eglot drives Terraform `.tf` / `.tfvars` files (via `terraform-mode`) with
OpenTofu's [tofu-ls](https://github.com/opentofu/tofu-ls); format on save
uses `tofu fmt`, so install OpenTofu (e.g. via `mise`). Terragrunt and
other `*.hcl` files (except `.terraform.lock.hcl` / `.tflint.hcl`) use
`terragrunt-mode` (an `hcl-mode` derivative) with Gruntwork's
[terragrunt-ls](https://github.com/gruntwork-io/terragrunt-ls). Download
pre-built archives from the releases pages
([tofu-ls](https://github.com/opentofu/tofu-ls/releases),
[terragrunt-ls](https://github.com/gruntwork-io/terragrunt-ls/releases)),
then extract the binaries:

```bash
tar -xzf tofu-ls_*.tar.gz -C ~/.local/bin/ tofu-ls
tar -xzf terragrunt-ls_*.tar.gz -C ~/.local/bin/ terragrunt-ls
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
