;;; my-org-capture.el --- Capture templates and raw-notes helpers -*- lexical-binding: t; -*-

;; Builds `org-capture-templates' dynamically from category tuples,
;; active projects, and the "current project". Also provides the Raw
;; notes C-<return> helper. Keybindings, the :before advice, and hooks
;; are wired up from init.org — this file defines functions only.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'pcase)
(require 'my-org-core)
(require 'my-org-projects)
(require 'my-org-interview)

(defvar org-capture-templates)

(defconst my/org-project-max-slots 9
  "Maximum active projects reachable from the capture menu.
Digit keys 1-9 address these slots.")

(defconst my/org-project-capture-prefix "j"
  "Top-level capture key under which per-project templates are built.")

;; ---- Category templates -----------------------------------------

(defun my/org-capture-category (key name subdir &optional kinds)
  "Build capture templates for a category.
KEY is the single-letter prefix. NAME is the display name shown in
the capture menu. SUBDIR is the sub-directory under
~/org/src/orgfiles/ (nil puts the files directly under it).
KINDS is a list of symbols selecting which sub-templates to build;
nil means all of them. Valid kinds:
  deadline      -> <subdir>/inbox.org
  meeting       -> <subdir>/notes.org (weekly datetree)
  interview     -> <subdir>/notes.org (weekly datetree)
  whiteboard    -> <subdir>/whiteboard.org (daily datetree)
  miscellaneous -> <subdir>/inbox.org (Miscellaneous heading)"
  (let* ((all '(deadline meeting interview whiteboard miscellaneous))
         (kinds (or kinds all))
         (dir (if subdir
                  (format "~/org/src/orgfiles/%s/" subdir)
                "~/org/src/orgfiles/"))
         (inbox (concat dir "inbox.org"))
         (notes (concat dir "notes.org"))
         (whiteboard (concat dir "whiteboard.org"))
         (templates (list (list key name))))
    (dolist (kind kinds)
      (push
       (pcase kind
         ('deadline
          `(,(concat key "d") "Deadline" entry
            (file ,inbox)
            "* TODO %?\nDEADLINE: %^T\n%i\n" :prepend t))
         ('meeting
          `(,(concat key "m") "Meeting notes" entry
            (file+olp+datetree ,notes "Meeting notes")
            "* %?\n" :tree-type week))
         ('interview
          `(,(concat key "i") "Interview notes" entry
            (file+olp+datetree ,notes "Interview notes")
            ,my/org-interview-capture-template-body
            :tree-type week))
         ('whiteboard
          `(,(concat key "w") "Whiteboard" entry
            (file+olp+datetree ,whiteboard)
            "* %<%H:%M>\n%?\n" :prepend t))
         ('miscellaneous
          `(,(concat key "x") "Miscellaneous" entry
            (file+headline ,inbox "Miscellaneous")
            "* %?\n%U\n"))
         (_ (error "Unknown capture kind: %S" kind)))
       templates))
    (nreverse templates)))

;; ---- Per-project template builders ------------------------------

(defun my/org-project--template-group (prefix description root whiteboard)
  "Return the template group (header + t/r/p/w) for ROOT and WHITEBOARD."
  (list
   (list prefix description)
   `(,(concat prefix "t") "Todo" entry
     (file+headline ,root "Tasks")
     "* TODO %?\n%U\n" :prepend t)
   `(,(concat prefix "r") "Reference" entry
     (file+headline ,root "Reference")
     "* %?\n%U\n")
   `(,(concat prefix "p") "Pointer" entry
     (file+headline ,root "Pointers")
     "* %?\n%a\n%U\n")
   `(,(concat prefix "w") "Whiteboard" entry
     (file+olp+datetree ,whiteboard)
     "* %<%H:%M>\n%?\n" :prepend t)))

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
    (let ((root (my/org-project-root-file my/org-current-project))
          (whiteboard (my/org-project-whiteboard-file my/org-current-project))
          (slug my/org-current-project))
      `(("." ,(format "Current project (%s)" slug))
        (".t" "Todo" entry
         (file+headline ,root "Tasks")
         "* TODO %?\n%U\n" :prepend t)
        (".r" "Reference" entry
         (file+headline ,root "Reference")
         "* %?\n%U\n")
        (".p" "Pointer" entry
         (file+headline ,root "Pointers")
         "* %?\n%a\n%U\n")
        (".w" "Whiteboard" entry
         (file+olp+datetree ,whiteboard)
         "* %<%H:%M>\n%?\n" :prepend t)))))

;; ---- Dynamic rebuild --------------------------------------------

(defun my/org-rebuild-capture-templates (&rest _)
  "Rebuild `org-capture-templates' from scratch."
  (setq org-capture-templates
        (append
         (mapcan (lambda (cat) (apply #'my/org-capture-category cat))
                 my/org-capture-categories)
         (my/org-capture-project-templates)
         (my/org-current-project-capture-templates)
         '(("J" "Journal" entry
            (file+olp+datetree "~/org/src/orgfiles/journal.org")
            "* %?\n")
           ("x" "Miscellaneous" entry
            (file+headline "~/org/src/orgfiles/inbox.org" "To file")
            "* %?\n%U\n")))))

;; ---- Current-project capture entry point -----------------------

(defun my/org-project-capture ()
  "Start an org-capture into the current project.
If there is no current project, pick one first (which may also
prompt to save a repo/branch mapping). Reads a single char for the
template kind — [t]odo, [r]eference, [p]ointer, [w]hiteboard — and
hands off to `org-capture' with the resolved leaf key (e.g. \".t\").
The `:before' advice on `org-capture' rebuilds the template list, so
the leaf is guaranteed to exist when capture reads it."
  (interactive)
  (unless my/org-current-project
    (call-interactively #'my/org-project-set-current))
  (when my/org-current-project
    (let ((c (read-char-choice
              (format "Capture into %s: [t]odo [r]eference [p]ointer [w]hiteboard: "
                      my/org-current-project)
              '(?t ?r ?p ?w))))
      (org-capture nil (format ".%c" c)))))

(provide 'my-org-capture)
;;; my-org-capture.el ends here
