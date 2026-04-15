;;; my-org-projects.el --- Project CRUD and current-project state -*- lexical-binding: t; -*-

;; Creating, archiving, navigating, and tracking the "current project"
;; slug used by org-capture templates and the modeline. Also provides
;; the letter-key allocator shared between capture and agenda, and the
;; project management transient. Keybindings, modeline install, and
;; state load live in init.org.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'my-org-core)

(defconst my/org-project-root-template
  "#+title: %s\n#+category: %s\n\n* Tasks\n* Reference\n* Pointers\n"
  "Seed written into a new project's root.org.
Receives the slug twice (title then category).")

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

;; ---- Letter-key allocation --------------------------------------

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

(defun my/org-project--allocate-letter-keys (slugs &optional reserved)
  "Return an alist (SLUG . \"X\") of unique single-letter keys.
RESERVED is an optional list of char codes to keep free. Slugs that
can't get a free letter are omitted."
  (let ((used (append reserved nil))
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

;; ---- New / archive / goto projects ------------------------------

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

(defun my/org-goto-toplevel-file ()
  "Pick a category-based top-level org file and open it."
  (interactive)
  (let* ((alist (my/org-toplevel-file-alist))
         (choice (completing-read "Goto org file: "
                                  (mapcar #'car alist) nil t)))
    (find-file (cdr (assoc choice alist)))))

(defun my/org-project-archive ()
  "Archive a project.
Sets STATUS=archived and stamps ARCHIVED_AT with the current time
in the project's index.org entry."
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
        (org-set-property "ARCHIVED_AT"
                          (format-time-string "[%Y-%m-%d %a %H:%M]"))
        (save-buffer))
      (when (equal my/org-current-project slug)
        (setq my/org-current-project nil)
        (my/org-current-project-save))
      (force-mode-line-update t)
      (message "Archived %s" slug))))

;; ---- Modeline segment (install from init.org) -------------------

(defvar my/org-current-project-mode-line-segment
  '(:eval (when my/org-current-project
            (propertize (format " [proj: %s]" my/org-current-project)
                        'face 'mode-line-emphasis
                        'help-echo "Current org capture project"))))
(put 'my/org-current-project-mode-line-segment 'risky-local-variable t)

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

(provide 'my-org-projects)
;;; my-org-projects.el ends here
