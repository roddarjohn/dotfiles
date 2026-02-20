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
