;; Suppress Org's "version mismatch" warning. The built-in Org loads
;; first (via this file's `ob-tangle' require), then straight's Org
;; loads later as a dependency of org-super-agenda. Both versions are
;; recent enough that the literate tangle and the agenda views work
;; correctly — the warning is cosmetic. The proper fix is to
;; bootstrap straight here and pin Org early, but doing so breaks the
;; use-package + straight integration that emacs-config.el sets up.
;; `org--inhibit-version-check' only catches the call sites that are
;; loaded as source; the macro is expanded into .elc at compile time
;; so we also advise `warn' to filter the same message.
(setq org--inhibit-version-check t)
(define-advice warn (:around (orig &rest args) suppress-org-version-mismatch)
  (unless (and args (stringp (car args))
               (string-prefix-p "Org version mismatch" (car args)))
    (apply orig args)))

(require 'ob-tangle)
(let* ((init-org (file-truename (expand-file-name "init.org" user-emacs-directory)))
       (config-el (expand-file-name "emacs-config.el" (file-name-directory init-org))))
  (org-babel-tangle-file init-org)
  (load config-el))
