;; Setup melpa

(require 'package)

(setq package-enable-at-startup nil)
(setq package-archives
	     '(("melpa" . "http://melpa.org/packages/")
	       ("gnu" . "http://elpa.gnu.org/packages/")
	       ("org" . "http://orgmode.org/elpa/")
	     ))

(package-initialize)

(add-to-list 'load-path "~/.emacs.d/lisp/")
(add-to-list 'load-path "~/.emacs.d/org-mode/lisp")

;; Setup use-package
(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))

(org-babel-load-file (expand-file-name "~/.emacs.d/myinit.org"))
;(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
; '(elpy-formatter 'black)
; '(flycheck-checker-error-threshold 25000)
; '(flycheck-pycheckers-checkers '(flake8))
; '(js-indent-level 2)
; '(org-agenda-files '("~/orgfiles/cal.org" "~/orgfiles/i.org"))
; '(package-selected-packages
;   '(pyenv-mode tide typescript-mode add-node-modules-path importmagic terraform-mode js2-mode minimap ox-latex dired+ dumb-jump counsel-projectile projectile ggtags org-gcal web-mode iedit expand-region aggresive-indent hungry-delete beacon flycheck-pycheckers flycheck-pyflakes jedi htmlize ox-reveal zenburn-theme which-key use-package try sml-mode org-bullets nlinum load-theme-buffer-local jinja2-mode counsel auto-complete ace-window))
; '(python-check-command "/Users/rjohn/.pyenv/shims/flake8"))
;(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
; )
