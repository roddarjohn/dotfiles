;;; my-org-agenda.el --- Agenda dispatcher tied to the my-org layout -*- lexical-binding: t; -*-

;; Agenda on top of the capture layout defined across `my-org-core' and
;; `my-org-projects'.
;;
;; Agenda file scope: the top-level inbox, each category's
;; TODO-bearing files (derived from `my/org-capture-category-kinds' —
;; specifically kinds whose target is not a datetree), and every
;; active project's root.org. Datetree'd notes and whiteboards are
;; excluded so the view stays focused on actual tasks.
;;
;; Entry point: `my/org-agenda-transient' offers an "everything" view, a
;; category picker, and a project picker. The raw org-agenda dispatcher
;; is reachable under `d'. Keybindings and the initial file-set refresh
;; are wired up from init.org.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'org-agenda)
(require 'my-org-core)
(require 'my-org-projects)

(defconst my/org-agenda--todo-target-types
  '(file file+headline file+regexp)
  "Target types that produce agenda-relevant (TODO-bearing) captures.
Datetree types are excluded — those kinds file time-series notes or
whiteboards, not tasks.")

;; ---- File-set helpers -------------------------------------------

(defun my/org-agenda--category-file-names ()
  "Distinct filenames from `my/org-capture-category-kinds' whose
targets are TODO-bearing (see `my/org-agenda--todo-target-types')."
  (let (files)
    (dolist (cell my/org-capture-category-kinds)
      (let* ((spec (cdr cell))
             (target (plist-get spec :target))
             (type (car-safe target))
             (file (my/org-capture-kind-file spec)))
        (when (and file
                   (memq type my/org-agenda--todo-target-types)
                   (not (member file files)))
          (push file files))))
    (nreverse files)))

(defun my/org-agenda--category-files (subdir)
  "Return the agenda-relevant files in category SUBDIR."
  (let ((dir (my/org-category-dir subdir)))
    (mapcar (lambda (name) (expand-file-name name dir))
            (my/org-agenda--category-file-names))))

(defun my/org-agenda-files-all ()
  "Return every agenda-relevant org file.
Includes the top-level inbox, each category's agenda files, and
every active project root. Notes and whiteboards are intentionally
excluded."
  (let ((files (list (my/org-toplevel-file "inbox.org"))))
    (dolist (cat my/org-capture-categories)
      (dolist (f (my/org-agenda--category-files (nth 2 cat)))
        (push f files)))
    (dolist (slug (my/org-project-active-slugs))
      (push (my/org-project-root-file slug) files))
    (nreverse files)))

(defun my/org-agenda-files-for-category (subdir)
  "Agenda file list scoped to category SUBDIR."
  (my/org-agenda--category-files subdir))

(defun my/org-agenda-files-for-project (slug)
  "Agenda file list scoped to a single project SLUG."
  (list (my/org-project-root-file slug)))

;; ---- Prefix-format label ---------------------------------------
;;
;; `org-agenda-prefix-format' evaluates %(sexp) while the source org
;; buffer is current, so `buffer-file-name' here points at the entry's
;; origin file. We derive the label from the path rather than from
;; `#+CATEGORY:' lines so the on-disk files stay unannotated.

(defun my/org-agenda-entry-label ()
  "Label showing the category or project an agenda entry comes from.
Returns \"[<category>]\" for entries under a category subdir,
\"[proj:<slug>]\" for entries under projects/<slug>/, and
\"[<filename>]\" for top-level files (e.g. inbox.org)."
  (let* ((file (or (buffer-file-name (buffer-base-buffer))
                   (buffer-file-name)))
         (rel (and file my/org-directory
                   (file-relative-name file my/org-directory))))
    (cond
     ((null rel) "")
     ((string-match "\\`projects/\\([^/]+\\)/" rel)
      (format "[proj:%s]" (match-string 1 rel)))
     ((string-match "\\`\\([^/]+\\)/" rel)
      (let* ((subdir (match-string 1 rel))
             (cat (seq-find (lambda (c) (equal (nth 2 c) subdir))
                            my/org-capture-categories)))
        (format "[%s]" (downcase (if cat (nth 1 cat) subdir)))))
     (t (format "[%s]" (file-name-base rel))))))

(defun my/org-agenda-refresh-files ()
  "Rebuild `org-agenda-files' from the capture layout.
Called explicitly from entry points that want the \"everything\" view.
We deliberately do NOT advise `org-agenda' to do this — scoped commands
let-bind `org-agenda-files', and an advice would clobber that binding."
  (setq org-agenda-files (my/org-agenda-files-all)))

;; ---- Commands ---------------------------------------------------

(defvar my/org-agenda--scoping nil
  "Dynamic file list carried through a scoped agenda run.
`my/org-agenda--show-scoped' binds this and `org-agenda-files' to the
same list, and `my/org-agenda--rewrap-redo-command' bakes the binding
into `org-agenda-redo-command' so `g' (`org-agenda-redo') keeps the
scope. Re-binding it inside the wrapped redo form is what lets the
finalize hook re-wrap on every redo, so scope survives indefinitely.")

(defun my/org-agenda--rewrap-redo-command ()
  "Wrap the agenda's redo command to preserve the current scope.
Runs from `org-agenda-finalize-hook'. `org-agenda-redo' actually reads
the redo from the `org-redo-cmd' text property — the variable is
secondary — so we update both. The agenda command resets them to
unwrapped forms just before finalize, so we re-wrap each time."
  (when (and (derived-mode-p 'org-agenda-mode)
             my/org-agenda--scoping)
    (let* ((files my/org-agenda--scoping)
           (orig (or (get-text-property (point-min) 'org-redo-cmd)
                     org-agenda-redo-command))
           (wrapped (and orig
                         `(let ((my/org-agenda--scoping ',files)
                                (org-agenda-files ',files))
                            ,orig))))
      (when wrapped
        (setq org-agenda-redo-command wrapped)
        (let ((inhibit-read-only t))
          (put-text-property (point-min) (point-max)
                             'org-redo-cmd wrapped))))))

(add-hook 'org-agenda-finalize-hook #'my/org-agenda--rewrap-redo-command)

(defun my/org-agenda--show (files view)
  "Run `org-agenda' VIEW with FILES as its file list."
  (let ((org-agenda-files files))
    (org-agenda nil view)))

(defun my/org-agenda--show-scoped (files view)
  "Run `org-agenda' VIEW scoped to FILES, persisting scope across `g'."
  (let ((my/org-agenda--scoping files)
        (org-agenda-files files))
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
  (my/org-agenda--show-scoped (my/org-agenda-files-for-category subdir)
                              my/org-agenda--category-view))

(defun my/org-agenda--run-project (slug)
  "Internal: show TODO list for project SLUG."
  (my/org-agenda--show-scoped (my/org-agenda-files-for-project slug) "t"))

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
     ;; `cl-loop' updates SLUG via `setq', so all iterations share one
     ;; binding cell. Shadow it with a fresh `let' binding so the
     ;; per-project lambda below closes over its own value.
     (let* ((slug slug)
            (letter (cdr (assoc slug letters)))
            (key (or letter (number-to-string idx)))
            (cmd-name (intern (format "my/org-agenda--project-%s" slug))))
       (defalias cmd-name
         (lambda ()
           (interactive)
           (my/org-agenda--run-project slug))
         (format "Agenda for project %s." slug))
       (transient-parse-suffix
        'my/org-agenda-project-transient
        (list key slug cmd-name))))))

(transient-define-prefix my/org-agenda-category-transient ()
  "Pick a category to view its agenda."
  [:description
   (lambda () (format "Category (%s)"
                      (if (equal my/org-agenda--category-view "a")
                          "Weekly agenda" "TODO list")))
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

(provide 'my-org-agenda)
;;; my-org-agenda.el ends here
