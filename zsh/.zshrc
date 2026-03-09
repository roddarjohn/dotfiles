export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="bira"
plugins=(git)

source $ZSH/oh-my-zsh.sh

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
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# nvm setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
