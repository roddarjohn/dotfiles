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

# pyenv setup
export PATH="$HOME/.pyenv/bin:$PATH"
if command -v pyenv &>/dev/null; then
  eval "$(pyenv init -)"
  eval "$(pyenv virtualenv-init -)"
else
  echo "zshrc: pyenv not found, skipping"
fi

# nvm setup
export NVM_DIR="$HOME/.nvm"
if [ -d "$NVM_DIR" ]; then
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
else
  echo "zshrc: nvm not found, skipping"
fi

# For uv
[ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env"
