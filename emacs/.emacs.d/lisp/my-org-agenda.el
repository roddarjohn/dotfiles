;;; my-org-agenda.el --- Agenda setup tied to my-org-capture -*- lexical-binding: t; -*-

;; Agenda on top of the capture layout in `my-org-capture'.
;;
;; Agenda file scope: the top-level inbox, each <category>/inbox.org, and
;; every active project's root.org. Journals and notes are excluded to
;; keep the view focused on actual tasks.
;;
;; Entry point: `C-c a' opens `my/org-agenda-transient' which offers an
;; "everything" view, a category picker, and a project picker. The raw
;; org-agenda dispatcher is still reachable from the transient under `d'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'org-agenda)
(require 'my-org-capture)

;; ---- File-set helpers -------------------------------------------

(defun my/org-agenda--category-inbox (subdir)
  (expand-file-name (format "~/org/src/orgfiles/%s/inbox.org" subdir)))

(defun my/org-agenda-files-all ()
  "Return every agenda-relevant org file.
Includes the top-level inbox, per-category inboxes, and every active
project root. Journals and notes are intentionally excluded."
  (let ((files (list (expand-file-name "~/org/src/orgfiles/inbox.org"))))
    (dolist (cat my/org-capture-categories)
      (push (my/org-agenda--category-inbox (nth 2 cat)) files))
    (dolist (slug (my/org-project-active-slugs))
      (push (my/org-project-root-file slug) files))
    (nreverse files)))

(defun my/org-agenda-files-for-category (subdir)
  "Agenda file list scoped to category SUBDIR (its inbox)."
  (list (my/org-agenda--category-inbox subdir)))

(defun my/org-agenda-files-for-project (slug)
  "Agenda file list scoped to a single project SLUG."
  (list (my/org-project-root-file slug)))

(defun my/org-agenda-refresh-files ()
  "Rebuild `org-agenda-files' from the capture layout.
Called explicitly from entry points that want the \"everything\" view.
We deliberately do NOT advise `org-agenda' to do this — scoped commands
let-bind `org-agenda-files', and an advice would clobber that binding."
  (setq org-agenda-files (my/org-agenda-files-all)))

(my/org-agenda-refresh-files)

;; ---- Commands ---------------------------------------------------

(defun my/org-agenda--show (files view)
  "Run `org-agenda' VIEW with FILES as its file list."
  (let ((org-agenda-files files))
    (org-agenda nil view)))

(defun my/org-agenda-everything-week ()
  "Weekly agenda across everything."
  (interactive)
  (my/org-agenda--show (my/org-agenda-files-all) "a"))

(defun my/org-agenda-everything-todo ()
  "Flat TODO list across everything."
  (interactive)
  (my/org-agenda--show (my/org-agenda-files-all) "t"))

(defun my/org-agenda-dispatch ()
  "Raw org-agenda dispatcher with the full capture file set."
  (interactive)
  (my/org-agenda-refresh-files)
  (call-interactively #'org-agenda))

;; ---- Sub-transient runners --------------------------------------
;;
;; Transient suffix commands must be named — anonymous lambdas lose
;; their closure by the time transient resolves them. We keep the
;; "which category / which project / which view" state in module-level
;; vars that are set just before the sub-transient opens and read by
;; the suffix command.

(defvar my/org-agenda--category-view "a"
  "View type (\"a\" or \"t\") used by the category sub-transient.")

(defun my/org-agenda--run-category (subdir)
  "Internal: show SUBDIR agenda using `my/org-agenda--category-view'."
  (my/org-agenda--show (my/org-agenda-files-for-category subdir)
                       my/org-agenda--category-view))

(defun my/org-agenda--run-project (slug)
  "Internal: show TODO list for project SLUG."
  (my/org-agenda--show (my/org-agenda-files-for-project slug) "t"))

(defun my/org-agenda--category-children (_)
  "Dynamic children for the category agenda sub-transient."
  (mapcar
   (lambda (cat)
     (pcase-let* ((`(,key ,name ,subdir) cat)
                  (cmd-name (intern (format "my/org-agenda--category-%s" subdir))))
       (unless (fboundp cmd-name)
         (defalias cmd-name
           (lambda ()
             (interactive)
             (my/org-agenda--run-category subdir))
           (format "Agenda for the %s category." name)))
       (transient-parse-suffix
        'my/org-agenda-category-transient
        (list key name cmd-name))))
   my/org-capture-categories))

(defun my/org-agenda--project-children (_)
  "Dynamic children for the project sub-transient.
Each project gets its single-letter slug key (see
`my/org-project--allocate-letter-keys'), falling back to a digit slot."
  (let* ((slugs (my/org-project-active-slugs))
         (letters (my/org-project--allocate-letter-keys slugs)))
    (cl-loop
     for slug in slugs
     for idx from 1
     collect
     (let* ((letter (cdr (assoc slug letters)))
            (key (or letter (number-to-string idx)))
            (cmd-name (intern (format "my/org-agenda--project-%s" slug))))
       (unless (fboundp cmd-name)
         (defalias cmd-name
           (lambda ()
             (interactive)
             (my/org-agenda--run-project slug))
           (format "Agenda for project %s." slug)))
       (transient-parse-suffix
        'my/org-agenda-project-transient
        (list key slug cmd-name))))))

(transient-define-prefix my/org-agenda-category-transient ()
  "Pick a category to view its agenda."
  [:description
   (lambda () (format "Category (%s)"
                      (if (equal my/org-agenda--category-view "a")
                          "weekly agenda" "TODO list")))
   :class transient-column
   :setup-children my/org-agenda--category-children])

(transient-define-prefix my/org-agenda-project-transient ()
  "Pick a project to view its TODO list."
  [:description "Project TODO list"
   :class transient-column
   :setup-children my/org-agenda--project-children])

(defun my/org-agenda-category-agenda-entry ()
  "Open the category sub-transient in \"weekly agenda\" mode."
  (interactive)
  (setq my/org-agenda--category-view "a")
  (my/org-agenda-category-transient))

(defun my/org-agenda-category-todo-entry ()
  "Open the category sub-transient in \"TODO list\" mode."
  (interactive)
  (setq my/org-agenda--category-view "t")
  (my/org-agenda-category-transient))

;; ---- Main transient --------------------------------------------

(transient-define-prefix my/org-agenda-transient ()
  "Org agenda dispatcher."
  ["Everything"
   ("a" "Weekly agenda"       my/org-agenda-everything-week)
   ("t" "All TODOs"           my/org-agenda-everything-todo)]
  ["Filtered"
   ("c" "Category agenda..."  my/org-agenda-category-agenda-entry)
   ("C" "Category TODOs..."   my/org-agenda-category-todo-entry)
   ("p" "Project TODOs..."    my/org-agenda-project-transient)]
  ["Raw"
   ("d" "Dispatcher"          my/org-agenda-dispatch)])

(global-set-key (kbd "C-c a") #'my/org-agenda-transient)

(provide 'my-org-agenda)
;;; my-org-agenda.el ends here
