;;; my-org-capture.el --- Capture templates and raw-notes helpers -*- lexical-binding: t; -*-

;; Builds `org-capture-templates' dynamically from three configurable
;; sources:
;;   - `my/org-capture-categories' × `my/org-capture-category-kinds'
;;     produce the per-category templates (w* / p* / t* / d* ...).
;;   - `my/org-project-capture-kinds' produces the per-project
;;     templates under the `j' prefix and the `.' current-project
;;     shortcut.
;;   - `my/org-capture-extra-templates' is appended verbatim for
;;     anything else (journal, top-level miscellaneous inbox, ...).
;;
;; Also provides the current-project capture entry point. Keybindings,
;; the :before advice, and hooks are wired up from init.org.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'pcase)
(require 'my-org-core)
(require 'my-org-projects)
(require 'my-org-interview)

(defvar org-capture-templates)

(defvar my/org-project-max-slots 9
  "Maximum active projects reachable from the capture menu.
Digit keys 1-9 address these slots.")

(defvar my/org-project-capture-prefix "j"
  "Top-level capture key under which per-project templates are built.")

;; The config vars `my/org-capture-category-kinds',
;; `my/org-project-capture-kinds', and `my/org-capture-extra-templates'
;; are defvar'd in my-org-core and populated from init.org.

;; ---- Helpers ----------------------------------------------------

(defun my/org-capture--resolve-body (body)
  "Return the template body string for BODY.
When BODY is a non-nil symbol, use its variable value; otherwise
return BODY unchanged."
  (if (and (symbolp body) body)
      (symbol-value body)
    body))

(defun my/org-capture--retarget (target resolve-file)
  "Return TARGET with its file slot replaced by (funcall RESOLVE-FILE FILE).
When RESOLVE-FILE returns nil, TARGET is returned unchanged."
  (if (and (consp target) (cdr target))
      (let ((resolved (funcall resolve-file (cadr target))))
        (if resolved
            (cons (car target) (cons resolved (cddr target)))
          target))
    target))

(defun my/org-capture--category-target (target dir)
  "Resolve TARGET's file against DIR (a directory path)."
  (my/org-capture--retarget
   target
   (lambda (file)
     (when (stringp file) (expand-file-name file dir)))))

(defun my/org-capture--project-target (target root whiteboard)
  "Resolve TARGET's file slot (`root'/`whiteboard' symbol) to a path."
  (my/org-capture--retarget
   target
   (lambda (file)
     (pcase file
       ('root       root)
       ('whiteboard whiteboard)
       (_           nil)))))

(defun my/org-capture--extra-target (target)
  "Resolve TARGET's relative file against `my/org-directory'."
  (my/org-capture--retarget
   target
   (lambda (file)
     (cond ((not (stringp file))       nil)
           ((file-name-absolute-p file) (expand-file-name file))
           (t (expand-file-name file my/org-directory))))))

(defun my/org-capture--build-entry (prefix spec target)
  "Build a `(KEY DESC entry TARGET BODY . OPTS)' capture-template entry.
PREFIX is the capture prefix (e.g. \"w\"); SPEC is a kind plist;
TARGET is the already-resolved target form."
  (append
   (list (concat prefix (plist-get spec :key))
         (plist-get spec :desc)
         'entry
         target
         (my/org-capture--resolve-body (plist-get spec :body)))
   (plist-get spec :opts)))

;; ---- Category templates -----------------------------------------

(defun my/org-capture-category (key name subdir &optional kinds)
  "Build capture templates for a category.
KEY is the single-letter prefix. NAME is shown in the capture menu.
SUBDIR is the sub-directory under `my/org-directory' (nil places the
files directly in it). KINDS is a list of kind symbols from
`my/org-capture-category-kinds'; nil means all of them."
  (let* ((dir (my/org-category-dir subdir))
         (all (mapcar #'car my/org-capture-category-kinds))
         (kinds (or kinds all))
         (templates (list (list key name))))
    (dolist (kind kinds)
      (let ((spec (cdr (assq kind my/org-capture-category-kinds))))
        (unless spec
          (error "Unknown capture kind: %S" kind))
        (push (my/org-capture--build-entry
               key spec
               (my/org-capture--category-target
                (plist-get spec :target) dir))
              templates)))
    (nreverse templates)))

;; ---- Per-project template builders ------------------------------

(defun my/org-project--template-group (prefix description root whiteboard)
  "Return a template group (header + one entry per kind) for a project.
PREFIX is the capture-key prefix (e.g. \"j1\" or \".\"). The kinds
come from `my/org-project-capture-kinds'."
  (cons
   (list prefix description)
   (mapcar
    (lambda (cell)
      (let ((spec (cdr cell)))
        (my/org-capture--build-entry
         prefix spec
         (my/org-capture--project-target
          (plist-get spec :target) root whiteboard))))
    my/org-project-capture-kinds)))

(defun my/org-capture-project-templates ()
  "Return capture entries for every active project under the `j' prefix.
Each project gets both a digit slot (`j1', `j2', ...) and, when a
free letter can be assigned, a letter shortcut (`jm', `jt', ...)."
  (let* ((slugs (seq-take (my/org-project-active-slugs)
                          my/org-project-max-slots))
         (letter-alist
          (my/org-project--allocate-letter-keys
           slugs (list (string-to-char my/org-project-capture-prefix))))
         (templates nil)
         (idx 0))
    (when slugs
      (push (list my/org-project-capture-prefix "Projects") templates))
    (dolist (slug slugs)
      (setq idx (1+ idx))
      (let* ((root (my/org-project-root-file slug))
             (whiteboard (my/org-project-whiteboard-file slug))
             (num-prefix (format "%s%d" my/org-project-capture-prefix idx))
             (letter (cdr (assoc slug letter-alist)))
             (label (if letter
                        (format "%s (%s)" slug letter)
                      slug)))
        (dolist (entry (my/org-project--template-group
                        num-prefix label root whiteboard))
          (push entry templates))
        (when letter
          (let ((let-prefix (concat my/org-project-capture-prefix letter)))
            (dolist (entry (my/org-project--template-group
                            let-prefix slug root whiteboard))
              (push entry templates))))))
    (nreverse templates)))

(defun my/org-current-project-capture-templates ()
  "Templates under the `.' key for the current project, or nil."
  (when (and my/org-current-project
             (member my/org-current-project (my/org-project-active-slugs)))
    (my/org-project--template-group
     "."
     (format "Current project (%s)" my/org-current-project)
     (my/org-project-root-file my/org-current-project)
     (my/org-project-whiteboard-file my/org-current-project))))

;; ---- Extra templates --------------------------------------------

(defun my/org-capture--resolved-extra-templates ()
  "Return `my/org-capture-extra-templates' with file paths expanded."
  (mapcar
   (lambda (entry)
     (pcase entry
       (`(,key ,desc ,type ,target . ,rest)
        (append (list key desc type
                      (my/org-capture--extra-target target))
                rest))
       (_ entry)))
   my/org-capture-extra-templates))

;; ---- Dynamic rebuild --------------------------------------------

(defun my/org-rebuild-capture-templates (&rest _)
  "Rebuild `org-capture-templates' from scratch."
  (setq org-capture-templates
        (append
         (mapcan (lambda (cat) (apply #'my/org-capture-category cat))
                 my/org-capture-categories)
         (my/org-capture-project-templates)
         (my/org-current-project-capture-templates)
         (my/org-capture--resolved-extra-templates))))

;; ---- Current-project capture entry point -----------------------

(defun my/org-project-capture ()
  "Start an org-capture into the current project.
If there is no current project, pick one first (which may also
prompt to save a repo/branch mapping). Reads a single char chosen
from `my/org-project-capture-kinds' and hands off to `org-capture'
with the resolved leaf key (e.g. \".t\"). The `:before' advice on
`org-capture' rebuilds the template list, so the leaf is guaranteed
to exist when capture reads it."
  (interactive)
  (unless my/org-current-project
    (call-interactively #'my/org-project-set-current))
  (when my/org-current-project
    (let* ((specs (mapcar #'cdr my/org-project-capture-kinds))
           (chars (mapcar (lambda (s)
                            (string-to-char (plist-get s :key)))
                          specs))
           (prompt (format "Capture into %s: %s: "
                           my/org-current-project
                           (mapconcat
                            (lambda (s)
                              (format "[%s]%s"
                                      (plist-get s :key)
                                      (downcase (plist-get s :desc))))
                            specs " ")))
           (c (read-char-choice prompt chars)))
      (org-capture nil (format ".%c" c)))))

(provide 'my-org-capture)
;;; my-org-capture.el ends here
