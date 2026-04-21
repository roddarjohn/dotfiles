;;; my-org-refile.el --- Refile via capture-shaped transient menu -*- lexical-binding: t; -*-

;; Context-sensitive refile: the destinations offered mirror the
;; capture hierarchy (categories × kinds, plus per-project kinds). The
;; source subtree's shape drives which kinds appear:
;;   - under a datetree day heading → only datetree destinations, with
;;     the source's date reused for the destination's date path.
;;   - anywhere else → only heading/file destinations (datetree kinds
;;     are hidden).
;;
;; Entry point `my/org-refile-dispatch' is wired to a keybinding in
;; init.org.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'org)
(require 'org-datetree)
(require 'my-org-core)
(require 'my-org-projects)

(defvar my/org-capture-categories)
(defvar my/org-capture-category-kinds)
(defvar my/org-project-capture-kinds)

(defconst my/org-refile--day-heading-re
  "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
  "Matches a datetree day heading at the start of a heading string.")

;; ---- Source classification --------------------------------------

(defun my/org-refile--scan-source-date ()
  "Return (MONTH DAY YEAR) if current subtree sits under a datetree day,
else nil."
  (save-excursion
    (org-back-to-heading t)
    (let (date)
      (while (and (not date) (org-up-heading-safe))
        (let ((txt (nth 4 (org-heading-components))))
          (when (and txt (string-match my/org-refile--day-heading-re txt))
            (setq date
                  (list (string-to-number (match-string 2 txt))
                        (string-to-number (match-string 3 txt))
                        (string-to-number (match-string 1 txt)))))))
      date)))

(defun my/org-refile--target-type (target)
  "Classify a capture :target TARGET as `datetree', `headline', `file', or nil."
  (pcase (car-safe target)
    ((or 'file+olp+datetree 'file+datetree) 'datetree)
    ('file+headline 'headline)
    ('file          'file)
    (_              nil)))

(defun my/org-refile--kind-matches-source (spec source-datetree-p)
  "Non-nil if SPEC's target kind is allowed given SOURCE-DATETREE-P."
  (let ((type (my/org-refile--target-type (plist-get spec :target))))
    (if source-datetree-p
        (eq type 'datetree)
      (memq type '(file headline)))))

;; ---- Target resolution -----------------------------------------

(defun my/org-refile--resolve-category-target (target dir)
  "Expand TARGET's string filename slot against DIR."
  (if (and (consp target) (stringp (cadr target)))
      (cons (car target)
            (cons (expand-file-name (cadr target) dir)
                  (cddr target)))
    target))

(defun my/org-refile--resolve-project-target (target root whiteboard)
  "Substitute `root'/`whiteboard' symbols in TARGET with concrete paths."
  (if (consp target)
      (cons (car target)
            (cons (pcase (cadr target)
                    ('root       root)
                    ('whiteboard whiteboard)
                    (other       other))
                  (cddr target)))
    target))

;; ---- Placement + refile ----------------------------------------

(defun my/org-refile--position-for-target (target date)
  "Leave point at the insertion spot for TARGET in the current buffer.
Buffer is assumed widened. DATE is (MONTH DAY YEAR) for datetree targets."
  (pcase target
    (`(file ,_)
     (goto-char (point-max))
     (unless (bolp) (insert "\n")))
    (`(file+headline ,_ ,headline)
     (goto-char (point-min))
     (let ((re (format org-complex-heading-regexp-format
                       (regexp-quote headline))))
       (unless (re-search-forward re nil t)
         (error "Heading %S not found" headline)))
     (end-of-line))
    (`(file+olp+datetree ,_ . ,olp)
     (unless date (error "Datetree target requires a source date"))
     (goto-char (point-min))
     (when olp
       (goto-char (org-find-olp olp t))
       (org-narrow-to-subtree))
     (org-datetree-find-date-create date t)
     (end-of-line))
    (`(file+datetree ,_)
     (unless date (error "Datetree target requires a source date"))
     (org-datetree-find-date-create date t)
     (end-of-line))
    (_ (error "Unsupported refile target: %S" target))))

(defun my/org-refile--execute (target date)
  "Cut current subtree and paste it at TARGET (with DATE for datetrees)."
  (save-excursion
    (org-back-to-heading t)
    (org-cut-subtree))
  (let ((buf (find-file-noselect (cadr target))))
    (with-current-buffer buf
      (save-restriction
        (widen)
        (my/org-refile--position-for-target target date)
        (org-paste-subtree))
      (save-buffer)))
  (message "Refiled to %s" (file-name-nondirectory (cadr target))))

;; ---- Action entry points (closures captured by setup-children) --

(defvar my/org-refile--source-date nil
  "(MONTH DAY YEAR) of the source subtree, set on transient entry.")

(defvar my/org-refile--source-datetree-p nil
  "Non-nil when source subtree sits under a datetree; set on entry.")

(defun my/org-refile--do-category (subdir kind-sym)
  "Refile current subtree into category SUBDIR's KIND-SYM target."
  (let* ((spec (cdr (assq kind-sym my/org-capture-category-kinds)))
         (dir (my/org-category-dir subdir))
         (target (my/org-refile--resolve-category-target
                  (plist-get spec :target) dir)))
    (my/org-refile--execute target my/org-refile--source-date)))

(defun my/org-refile--do-project (slug kind-sym)
  "Refile current subtree into project SLUG's KIND-SYM target."
  (let* ((spec (cdr (assq kind-sym my/org-project-capture-kinds)))
         (root (my/org-project-root-file slug))
         (whiteboard (my/org-project-whiteboard-file slug))
         (target (my/org-refile--resolve-project-target
                  (plist-get spec :target) root whiteboard)))
    (my/org-refile--execute target my/org-refile--source-date)))

;; ---- Sub-transients (per category / per project) ---------------

(defvar my/org-refile--active-category nil
  "Subdir of the category whose sub-transient is currently open.")

(defvar my/org-refile--active-project nil
  "Slug of the project whose sub-transient is currently open.")

(defun my/org-refile--category-kind-children (_)
  "Build suffixes for the kinds allowed in the active category."
  (let ((subdir my/org-refile--active-category))
    (delq nil
          (mapcar
           (lambda (cell)
             (let ((spec (cdr cell))
                   (kind-sym (car cell)))
               (when (my/org-refile--kind-matches-source
                      spec my/org-refile--source-datetree-p)
                 (let* ((key (plist-get spec :key))
                        (desc (plist-get spec :desc))
                        (cmd-name (intern (format "my/org-refile--cat-%s-%s"
                                                  subdir kind-sym))))
                   (unless (fboundp cmd-name)
                     (defalias cmd-name
                       (lambda ()
                         (interactive)
                         (my/org-refile--do-category subdir kind-sym))
                       (format "Refile to %s / %s." subdir desc)))
                   (transient-parse-suffix
                    'my/org-refile--category-transient
                    (list key desc cmd-name))))))
           my/org-capture-category-kinds))))

(defun my/org-refile--project-kind-children (_)
  "Build suffixes for the kinds allowed in the active project."
  (let ((slug my/org-refile--active-project))
    (delq nil
          (mapcar
           (lambda (cell)
             (let ((spec (cdr cell))
                   (kind-sym (car cell)))
               (when (my/org-refile--kind-matches-source
                      spec my/org-refile--source-datetree-p)
                 (let* ((key (plist-get spec :key))
                        (desc (plist-get spec :desc))
                        (cmd-name (intern (format "my/org-refile--proj-%s-%s"
                                                  slug kind-sym))))
                   (unless (fboundp cmd-name)
                     (defalias cmd-name
                       (lambda ()
                         (interactive)
                         (my/org-refile--do-project slug kind-sym))
                       (format "Refile to project %s / %s." slug desc)))
                   (transient-parse-suffix
                    'my/org-refile--project-transient
                    (list key desc cmd-name))))))
           my/org-project-capture-kinds))))

(transient-define-prefix my/org-refile--category-transient ()
  "Pick a kind within the chosen category."
  [:description
   (lambda () (format "Refile into category (%s)"
                      my/org-refile--active-category))
   :class transient-column
   :setup-children my/org-refile--category-kind-children])

(transient-define-prefix my/org-refile--project-transient ()
  "Pick a kind within the chosen project."
  [:description
   (lambda () (format "Refile into project (%s)"
                      my/org-refile--active-project))
   :class transient-column
   :setup-children my/org-refile--project-kind-children])

;; ---- Top-level transient ---------------------------------------

(defun my/org-refile--category-has-matches-p (_subdir)
  "Non-nil if any kind matches the current source mode (shared across categories)."
  (cl-some (lambda (cell)
             (my/org-refile--kind-matches-source
              (cdr cell) my/org-refile--source-datetree-p))
           my/org-capture-category-kinds))

(defun my/org-refile--project-has-matches-p ()
  "Non-nil if any project kind matches the current source mode."
  (cl-some (lambda (cell)
             (my/org-refile--kind-matches-source
              (cdr cell) my/org-refile--source-datetree-p))
           my/org-project-capture-kinds))

(defun my/org-refile--category-entries (_)
  "Build one suffix per category that opens its kind sub-transient."
  (delq nil
        (mapcar
         (lambda (cat)
           (pcase-let ((`(,key ,name ,subdir) cat))
             (when (my/org-refile--category-has-matches-p subdir)
               (let ((cmd-name (intern (format "my/org-refile--enter-cat-%s"
                                               subdir))))
                 (unless (fboundp cmd-name)
                   (defalias cmd-name
                     (lambda ()
                       (interactive)
                       (setq my/org-refile--active-category subdir)
                       (my/org-refile--category-transient))
                     (format "Open refile sub-menu for %s." name)))
                 (transient-parse-suffix
                  'my/org-refile-transient
                  (list key name cmd-name))))))
         my/org-capture-categories)))

(defun my/org-refile--project-entries (_)
  "Build one suffix per active project that opens its kind sub-transient."
  (when (my/org-refile--project-has-matches-p)
    (let* ((slugs (my/org-project-active-slugs))
           (reserved (mapcar (lambda (c) (string-to-char (car c)))
                             my/org-capture-categories))
           (letter-alist
            (my/org-project--allocate-letter-keys slugs reserved)))
      (cl-loop
       for slug in slugs
       for idx from 1
       collect
       (let* ((letter (cdr (assoc slug letter-alist)))
              (key (or letter (number-to-string idx)))
              (cmd-name (intern (format "my/org-refile--enter-proj-%s" slug))))
         (unless (fboundp cmd-name)
           (defalias cmd-name
             (lambda ()
               (interactive)
               (setq my/org-refile--active-project slug)
               (my/org-refile--project-transient))
             (format "Open refile sub-menu for project %s." slug)))
         (transient-parse-suffix
          'my/org-refile-transient
          (list key slug cmd-name)))))))

(transient-define-prefix my/org-refile-transient ()
  "Refile current subtree into a capture-shaped destination."
  [:description
   (lambda ()
     (if my/org-refile--source-datetree-p
         (pcase-let ((`(,m ,d ,y) my/org-refile--source-date))
           (format "Refile (from datetree %04d-%02d-%02d) — Categories"
                   y m d))
       "Refile — Categories"))
   :class transient-column
   :setup-children my/org-refile--category-entries]
  [:description "Projects"
   :class transient-column
   :setup-children my/org-refile--project-entries])

;;;###autoload
(defun my/org-refile-dispatch ()
  "Classify current subtree and open the refile transient."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (unless (ignore-errors (save-excursion (org-back-to-heading t) t))
    (user-error "No headline at or before point"))
  (setq my/org-refile--source-date (my/org-refile--scan-source-date)
        my/org-refile--source-datetree-p
        (not (null my/org-refile--source-date)))
  (my/org-refile-transient))

(provide 'my-org-refile)
;;; my-org-refile.el ends here
