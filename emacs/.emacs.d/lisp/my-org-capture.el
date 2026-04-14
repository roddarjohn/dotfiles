;;; my-org-capture.el --- Custom org-capture setup -*- lexical-binding: t; -*-

;; Category-based org-capture templates, per-category project support
;; with dynamic rebuild, a "current project" concept, a modeline
;; indicator, and C-<return> timestamp entries inside "Raw notes"
;; sections.
;;
;; Entry points:
;;   C-c c                            - standard org-capture
;;   M-j                              - project/current-project transient
;;   M-x my/org-project-new           - create a project
;;   M-x my/org-project-archive       - mark a project archived
;;   M-x my/org-project-set-current   - pick current project
;;   M-x my/org-project-clear-current - clear current project

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'pcase)
(require 'transient)

(global-set-key (kbd "C-c c") 'org-capture)

;; ---- Category templates -------------------------------------------

(defun my/org-capture-category (key name subdir &optional kinds)
  "Build capture templates for a category.
KEY is the single-letter prefix. NAME is the display name shown in
the capture menu. SUBDIR is the sub-directory under
~/org/src/orgfiles/ (nil puts the files directly under it).
KINDS is a list of symbols selecting which sub-templates to build;
nil means all of them. Valid kinds:
  thought       -> <subdir>/journal.org
  journal       -> <subdir>/journal.org (datetree)
  deadline      -> <subdir>/inbox.org
  meeting       -> <subdir>/notes.org (weekly datetree)
  interview     -> <subdir>/notes.org (weekly datetree)
  miscellaneous -> <subdir>/inbox.org (Miscellaneous heading)"
  (let* ((all '(thought journal deadline meeting interview miscellaneous))
         (kinds (or kinds all))
         (dir (if subdir
                  (format "~/org/src/orgfiles/%s/" subdir)
                "~/org/src/orgfiles/"))
         (journal (concat dir "journal.org"))
         (inbox (concat dir "inbox.org"))
         (notes (concat dir "notes.org"))
         (templates (list (list key name))))
    (dolist (kind kinds)
      (push
       (pcase kind
         ('thought
          `(,(concat key "t") "Thought" entry
            (file ,journal)
            "* %?\n%U\n"))
         ('journal
          `(,(concat key "j") "Journal" entry
            (file+olp+datetree ,journal)
            "* %?\n%U\n"))
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
            "* %^{Interviewee} — %^{Position}\n** Overview\n** Raw notes%?\n** Materials\n"
            :tree-type week))
         ('miscellaneous
          `(,(concat key "x") "Miscellaneous" entry
            (file+headline ,inbox "Miscellaneous")
            "* %?\n%U\n"))
         (_ (error "Unknown capture kind: %S" kind)))
       templates))
    (nreverse templates)))

(defvar my/org-capture-categories
  '(("w" "Work"     "work")
    ("p" "Personal" "personal")
    ("t" "Talos"    "talos")
    ("d" "Debate"   "debate"))
  "List of (KEY NAME SUBDIR) tuples fed to `my/org-capture-category'.")

;; ---- Project subsystem -------------------------------------------

(defconst my/org-project-max-slots 9
  "Maximum active projects reachable from the capture menu.
Digit keys 1-9 address these slots.")

(defconst my/org-project-capture-prefix "j"
  "Top-level capture key under which per-project templates are built.")

(defconst my/org-project-root-template
  "#+title: %s\n#+category: %s\n\n* Tasks\n* Reference\n* Pointers\n"
  "Seed written into a new project's root.org. Receives the slug
twice (title then category).")

(defun my/org-projects-dir ()
  "Return the single projects directory."
  (expand-file-name "~/org/src/orgfiles/projects/"))

(defun my/org-project-index-file ()
  "Return the index.org tracking project status."
  (expand-file-name "index.org" (my/org-projects-dir)))

(defun my/org-project-root-file (slug)
  "Return the root.org file for SLUG."
  (expand-file-name
   "root.org" (expand-file-name slug (my/org-projects-dir))))

(defun my/org-project--read-index ()
  "Parse index.org into plists with :slug :status :created.
Uses a plain regex walk so we don't depend on full org-mode setup in
a temp buffer."
  (let ((index (my/org-project-index-file)))
    (when (file-exists-p index)
      (with-temp-buffer
        (insert-file-contents index)
        (goto-char (point-min))
        (let (projects)
          (while (re-search-forward "^\\*+ +\\(.+?\\) *$" nil t)
            (let ((slug (match-string 1))
                  (status "active")
                  (created nil))
              (save-excursion
                (forward-line 1)
                (when (looking-at-p "^[ \t]*:PROPERTIES:[ \t]*$")
                  (let ((drawer-end
                         (save-excursion
                           (and (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
                                (point)))))
                    (while (and drawer-end
                                (re-search-forward
                                 "^[ \t]*:\\([A-Za-z]+\\): +\\(.*\\)$"
                                 drawer-end t))
                      (let ((k (upcase (match-string 1)))
                            (v (string-trim (match-string 2))))
                        (cond
                         ((string= k "STATUS") (setq status v))
                         ((string= k "CREATED") (setq created v))))))))
              (push (list :slug slug :status status :created created)
                    projects)))
          (nreverse projects))))))

(defun my/org-project-active-slugs ()
  "Return active project slugs, alphabetical."
  (sort
   (mapcar (lambda (p) (plist-get p :slug))
           (seq-filter (lambda (p)
                         (string= (plist-get p :status) "active"))
                       (my/org-project--read-index)))
   #'string<))

;; ---- Current project state --------------------------------------

(defvar my/org-current-project nil
  "Current project slug, or nil.")

(defconst my/org-current-project-state-file
  (expand-file-name "my-org-current-project.el" user-emacs-directory)
  "File persisting `my/org-current-project' across sessions.")

(defun my/org-current-project-load ()
  "Load `my/org-current-project' from the state file, if present."
  (when (file-exists-p my/org-current-project-state-file)
    (with-temp-buffer
      (insert-file-contents my/org-current-project-state-file)
      (setq my/org-current-project
            (ignore-errors (read (current-buffer)))))))

(defun my/org-current-project-save ()
  "Persist `my/org-current-project' to the state file."
  (with-temp-file my/org-current-project-state-file
    (prin1 my/org-current-project (current-buffer))))

;; ---- Capture template builders for projects --------------------

(defun my/org-project--slug-key-candidates (slug)
  "Ordered candidate chars for SLUG's letter key.
First the leading letter, then each consonant in order, then the
remaining letters. Non-letters and duplicates are stripped."
  (let* ((chars (append (downcase slug) nil))
         (letters (seq-filter (lambda (c) (and (>= c ?a) (<= c ?z))) chars))
         (first (car letters))
         (consonants (seq-filter (lambda (c) (not (memq c '(?a ?e ?i ?o ?u))))
                                 letters)))
    (seq-uniq (append (and first (list first)) consonants letters))))

(defun my/org-project--allocate-letter-keys (slugs)
  "Return an alist (SLUG . \"X\") of unique single-letter keys.
Slugs that can't get a free letter are omitted. The prefix char
`j' itself is reserved so captures like `jj' don't shadow it."
  (let ((used (list (string-to-char my/org-project-capture-prefix)))
        (result nil))
    (dolist (slug slugs)
      (let ((chosen nil))
        (dolist (c (my/org-project--slug-key-candidates slug))
          (unless (or chosen (memq c used))
            (setq chosen c)))
        (when chosen
          (push chosen used)
          (push (cons slug (string chosen)) result))))
    (nreverse result)))

(defun my/org-project--template-group (prefix description root)
  "Return the four-entry template group (group header + t/r/l) for ROOT."
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
     "* %?\n%a\n%U\n")))

(defun my/org-capture-project-templates ()
  "Return capture entries for every active project under the `j' prefix.
Each project gets both a digit slot (`j1', `j2', ...) and, when a
free letter can be assigned, a letter shortcut (`jm', `jt', ...)."
  (let* ((slugs (seq-take (my/org-project-active-slugs)
                          my/org-project-max-slots))
         (letter-alist (my/org-project--allocate-letter-keys slugs))
         (templates nil)
         (idx 0))
    (when slugs
      (push (list my/org-project-capture-prefix "Projects") templates))
    (dolist (slug slugs)
      (setq idx (1+ idx))
      (let* ((root (my/org-project-root-file slug))
             (num-prefix (format "%s%d" my/org-project-capture-prefix idx))
             (letter (cdr (assoc slug letter-alist)))
             (label (if letter
                        (format "%s (%s)" slug letter)
                      slug)))
        (dolist (entry (my/org-project--template-group num-prefix label root))
          (push entry templates))
        (when letter
          (let ((let-prefix (concat my/org-project-capture-prefix letter)))
            (dolist (entry (my/org-project--template-group
                            let-prefix slug root))
              (push entry templates))))))
    (nreverse templates)))

(defun my/org-current-project-capture-templates ()
  "Templates under the `.' key for the current project, or nil."
  (when (and my/org-current-project
             (member my/org-current-project (my/org-project-active-slugs)))
    (let ((root (my/org-project-root-file my/org-current-project))
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
         "* %?\n%a\n%U\n")))))

;; ---- Dynamic rebuild --------------------------------------------

(defun my/org-rebuild-capture-templates (&rest _)
  "Rebuild `org-capture-templates' from scratch."
  (setq org-capture-templates
        (append
         (mapcan (lambda (cat) (apply #'my/org-capture-category cat))
                 my/org-capture-categories)
         (my/org-capture-project-templates)
         (my/org-current-project-capture-templates)
         '(("x" "Miscellaneous" entry
            (file+headline "~/org/src/orgfiles/inbox.org" "To file")
            "* %?\n%U\n")))))

;; ---- Refile -----------------------------------------------------

(defun my/org-category-files ()
  "Every org file reachable from the capture setup.
Includes the shared top-level inbox.org, per-category journal/inbox/notes
files, and every active project's root.org so refile can reach them."
  (let ((files (list (expand-file-name "~/org/src/orgfiles/inbox.org"))))
    (dolist (cat my/org-capture-categories)
      (let* ((subdir (nth 2 cat))
             (dir (format "~/org/src/orgfiles/%s/" subdir)))
        (dolist (name '("journal.org" "inbox.org" "notes.org"))
          (push (expand-file-name (concat dir name)) files))))
    (dolist (slug (my/org-project-active-slugs))
      (push (my/org-project-root-file slug) files))
    (nreverse files)))

(setq org-refile-targets
      '((my/org-category-files :maxlevel . 3)))
(setq org-refile-use-outline-path 'file
      org-outline-path-complete-in-steps nil)

;; ---- Set / clear current project --------------------------------

(defun my/org-project-set-current ()
  "Pick the current project. Uses `completing-read' (vertico handles UI)."
  (interactive)
  (let* ((slugs (my/org-project-active-slugs))
         (_ (unless slugs (user-error "No active projects")))
         (choice (completing-read "Current project: " slugs nil t)))
    (setq my/org-current-project choice)
    (my/org-current-project-save)
    (force-mode-line-update t)
    (message "Current project: %s" choice)))

(defun my/org-project-clear-current ()
  "Clear the current project."
  (interactive)
  (setq my/org-current-project nil)
  (my/org-current-project-save)
  (force-mode-line-update t)
  (message "Current project cleared"))

;; ---- New / archive projects -------------------------------------

(defun my/org-project-new (slug)
  "Create a new project with SLUG."
  (interactive (list (read-string "New project slug: ")))
  (let* ((dir (expand-file-name slug (my/org-projects-dir)))
         (root (expand-file-name "root.org" dir))
         (index (my/org-project-index-file)))
    (when (file-exists-p dir)
      (user-error "Project already exists: %s" dir))
    (make-directory dir t)
    (with-temp-file root
      (insert (format my/org-project-root-template slug slug)))
    (unless (file-exists-p index)
      (with-temp-file index
        (insert "#+title: Projects\n\n")))
    (with-current-buffer (find-file-noselect index)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* %s\n" slug))
      (forward-line -1)
      (org-set-property "STATUS" "active")
      (org-set-property "CREATED" (format-time-string "[%Y-%m-%d]"))
      (save-buffer))
    (setq my/org-current-project slug)
    (my/org-current-project-save)
    (force-mode-line-update t)
    (find-file root)
    (message "Created project %s (now current)" slug)))

(defun my/org-project-list ()
  "Open the projects index.org."
  (interactive)
  (let ((index (my/org-project-index-file)))
    (unless (file-exists-p index)
      (user-error "No projects yet"))
    (find-file index)))

(defun my/org-project-goto ()
  "Pick an active project and open its root.org."
  (interactive)
  (let ((slugs (my/org-project-active-slugs)))
    (unless slugs
      (user-error "No active projects"))
    (let ((slug (completing-read "Go to project: " slugs nil t)))
      (find-file (my/org-project-root-file slug)))))

(defun my/org-toplevel-file-alist ()
  "Return ((LABEL . PATH) ...) for the category-based capture files.
Includes the shared top-level inbox and each category's
journal/inbox/notes files, whether or not they exist on disk."
  (let ((entries (list (cons "inbox"
                             (expand-file-name
                              "~/org/src/orgfiles/inbox.org")))))
    (dolist (cat my/org-capture-categories)
      (let ((subdir (nth 2 cat)))
        (dolist (name '("journal" "inbox" "notes"))
          (push (cons (format "%s/%s" subdir name)
                      (expand-file-name
                       (format "~/org/src/orgfiles/%s/%s.org" subdir name)))
                entries))))
    (nreverse entries)))

(defun my/org-goto-toplevel-file ()
  "Pick a category-based top-level org file and open it."
  (interactive)
  (let* ((alist (my/org-toplevel-file-alist))
         (choice (completing-read "Goto org file: "
                                  (mapcar #'car alist) nil t)))
    (find-file (cdr (assoc choice alist)))))

(defun my/org-project-archive ()
  "Mark a project as archived by setting STATUS=archived in the index."
  (interactive)
  (let ((slugs (my/org-project-active-slugs)))
    (unless slugs
      (user-error "No active projects"))
    (let* ((slug (completing-read "Archive project: " slugs nil t))
           (index (my/org-project-index-file)))
      (with-current-buffer (find-file-noselect index)
        (goto-char (point-min))
        (unless (re-search-forward
                 (format "^\\*+ +%s *$" (regexp-quote slug)) nil t)
          (user-error "%s not found in %s" slug index))
        (org-set-property "STATUS" "archived")
        (save-buffer))
      (when (equal my/org-current-project slug)
        (setq my/org-current-project nil)
        (my/org-current-project-save))
      (force-mode-line-update t)
      (message "Archived %s" slug))))

;; ---- Modeline indicator -----------------------------------------

(defvar my/org-current-project-mode-line-segment
  '(:eval (when my/org-current-project
            (propertize (format " [proj: %s]" my/org-current-project)
                        'face 'mode-line-emphasis
                        'help-echo "Current org capture project"))))
(put 'my/org-current-project-mode-line-segment 'risky-local-variable t)

(unless (memq 'my/org-current-project-mode-line-segment mode-line-misc-info)
  (add-to-list 'mode-line-misc-info
               'my/org-current-project-mode-line-segment t))

;; ---- Timestamped list items in Raw notes ------------------------

(defun my/org-insert-timestamped-item ()
  "Start a new plain list item prefixed with the current HH:MM."
  (interactive)
  (end-of-line)
  (newline)
  (insert (format-time-string "- %H:%M ")))

(defun my/org-in-raw-notes-p ()
  "Return non-nil when point is inside a \"Raw notes\" subtree."
  (save-excursion
    (and (ignore-errors (org-back-to-heading t) t)
         (looking-at-p "^\\*+ +Raw notes\\b"))))

(defun my/org-timestamped-item-or-heading ()
  "In a Raw notes subtree insert a timestamped list item.
Otherwise fall back to `org-insert-heading-respect-content'."
  (interactive)
  (if (my/org-in-raw-notes-p)
      (my/org-insert-timestamped-item)
    (call-interactively #'org-insert-heading-respect-content)))

;; ---- Transient menu ---------------------------------------------

(transient-define-prefix my/org-project-transient ()
  "Manage org-capture projects and jump around org files."
  ["Projects"
   ("g" "Goto project"       my/org-project-goto)
   ("n" "New project"        my/org-project-new)
   ("a" "Archive project"    my/org-project-archive)
   ("l" "List (open index)"  my/org-project-list)]
  ["Current project"
   ("s" "Set current"        my/org-project-set-current)
   ("c" "Clear current"      my/org-project-clear-current)]
  ["Goto file"
   ("f" "Top-level org file" my/org-goto-toplevel-file)])

(global-set-key (kbd "M-j") #'my/org-project-transient)

;; ---- Load-time wiring -------------------------------------------

(my/org-current-project-load)

(advice-add 'org-capture :before #'my/org-rebuild-capture-templates)

(with-eval-after-load 'org
  (my/org-rebuild-capture-templates)
  (define-key org-mode-map (kbd "C-<return>")
              #'my/org-timestamped-item-or-heading))

(with-eval-after-load 'org-capture
  (define-key org-capture-mode-map (kbd "C-<return>")
              #'my/org-timestamped-item-or-heading))

(provide 'my-org-capture)
;;; my-org-capture.el ends here
