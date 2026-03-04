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
   '(casual-suite mu4e-views mu4e zenburn-theme yasnippet-snippets
		  which-key vertico typescript-mode tsi
		  tree-sitter-langs terraform-mode solarized-theme
		  rainbow-delimiters quelpa-use-package pyenv-mode
		  org-super-agenda org-modern orderless marginalia
		  magit lsp-pyright iedit hungry-delete
		  hc-zenburn-theme flycheck flatland-theme
		  expand-region exec-path-from-shell embark-consult
		  devdocs corfu consult-projectile company casual cape
		  beacon anti-zenburn-theme all-the-icons-ibuffer
		  ace-window))
 '(warning-suppress-log-types '((defvaralias losing-value git-commit-mode-hook))))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
