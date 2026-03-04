(require 'package)

(setq package-enable-at-startup nil)
(setq package-archives
      '(("melpa" . "http://melpa.org/packages/")
	("gnu" . "http://elpa.gnu.org/packages/")
	("org" . "http://orgmode.org/elpa/")))

(package-initialize)

(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))

(org-babel-load-file (expand-file-name "~/config/emacs/init.org"))
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages
   '(ace-window all-the-icons-ibuffer apheleia beacon cape casual-suite
		company consult-projectile devdocs embark-consult
		expand-region flatland-theme flycheck-ledger
		hungry-delete iedit ledger-mode lsp-pyright magit
		marginalia orderless org-modern org-super-agenda
		pyenv-mode quelpa-use-package rainbow-delimiters
		terraform-mode transient tree-sitter-langs tsi
		typescript-mode vertico which-key yasnippet-snippets))
 '(warning-suppress-log-types '((defvaralias losing-value git-commit-mode-hook))))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
