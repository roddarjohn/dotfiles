export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="bira"
plugins=(git)

source $ZSH/oh-my-zsh.sh  # intentionally fails if not found

# if on ssh, use emacs -nw; if not, use emacs
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='emacs -nw'
else
  export EDITOR='emacs'
fi

# important for emacs
export PATH=/usr/local/bin:$PATH
# important for claude
export PATH="$HOME/.local/bin:$PATH"

# Homebrew (mac): put its bin on PATH for non-login shells too, so the
# tool-manager checks below (mise, nvm, ...) can find brew-installed tools.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$_brew" ] && eval "$("$_brew" shellenv)" && break
done
unset _brew

# pyenv setup
export PATH="$HOME/.pyenv/bin:$PATH"
if command -v pyenv &>/dev/null; then
  eval "$(pyenv init -)"
  eval "$(pyenv virtualenv-init -)"
else
  echo "zshrc: pyenv not found, skipping"
fi

# nvm setup. nvm.sh lives in ~/.nvm on linux, under homebrew on mac; NVM_DIR
# is always ~/.nvm (where node versions get installed) and must exist.
export NVM_DIR="$HOME/.nvm"
for _nvm_sh in "$NVM_DIR/nvm.sh" "$HOMEBREW_PREFIX/opt/nvm/nvm.sh"; do
  if [ -s "$_nvm_sh" ]; then
    mkdir -p "$NVM_DIR"
    \. "$_nvm_sh"
    _nvm_bc="${_nvm_sh%/nvm.sh}/etc/bash_completion.d/nvm"
    [ -s "$_nvm_bc" ] && \. "$_nvm_bc"
    break
  fi
done
unset _nvm_sh _nvm_bc

# Go-installed binaries (regal, actionlint, ...).  `go install`
# drops binaries here by default; without this on PATH they're
# only reachable via the absolute path.  Guarded so the line is
# a no-op on machines that haven't installed Go tools yet.
[ -d "$HOME/go/bin" ] && export PATH="$HOME/go/bin:$PATH"

# For uv
[ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env"

# Short alias for the org-contributions reporter (lives in ~/.local/bin,
# stowed from the dotfiles `bin` package; runs itself via `uv run --script`).
alias ghoc='gh-org-contributions'

# mise (https://mise.jdx.dev) — runtime + tool version manager.
# Activates mise's shims/env so tools it manages are on PATH. Placed
# last so it takes precedence over pyenv/nvm where they overlap.
# Guarded so the line is a no-op on machines without mise installed.
if command -v mise &>/dev/null; then
  eval "$(mise activate zsh)"
fi
