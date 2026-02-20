# Overview

This repository stores configuration files for various applications I
use when on machines.

It's largely intended for personal use, but is released under no
license for the potential benefit of others.

I often only maintain this repository when not employed or currently
working on projects, so it may be out of date.

# Getting started

In progress...

# Emacs

As is common with many `emacs` users, `emacs` serves both as a text
editor, but also (with `org`), an organization aide, calendar client,
email client, and much more.

My `emacs` configuration is in two parts, an `init.el` file which is
very slim. It serves to ensure `use-package` is available, as well as
to load the org file that contains much of the remainder of the
configuration.

This makes use literate programming
([link](https://cs.stanford.edu/~knuth/lp.html)) in org mode, via
`org-babel`.

I change my configuration from time to time, and try to not include
portions I don't currently use.

# ZSH

The zsh configuration is defined in a `.zshrc` file.

The zsh configuration is short, only configuring emacs as an editor
and a few other oh-my-zsh specifics.

# tmux

The tmux configuration is stored in a `.tmux.conf` file.

At present, this configures key bindings and the powerline theme.

Sample change
