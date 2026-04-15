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

(declare-function my/org-project-autoswitch-mode "my-org-autoswitch")
(declare-function org-set-property "org")
(declare-function org-entry-add-to-multivalued-property "org")
(declare-function org-entry-remove-from-multivalued-property "org")
(declare-function org-clock-in "org-clock")
(declare-function org-clock-out "org-clock")
(declare-function org-clock-goto "org-clock")
(declare-function org-clock-in-last "org-clock")
(declare-function org-clocking-p "org-clock")

(defconst my/org-project-root-template
  "#+title: %s\n#+category: %s\n\n* Tasks\n* Reference\n* Pointers\n"
  "Seed written into a new project's root.org.
Receives the slug twice (title then category).")

(defconst my/org-project-whiteboard-template
  "#+title: %s whiteboard\n#+category: %s\n\n"
  "Seed written into a new project's whiteboard.org.
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

;; ---- Repo/branch mappings ---------------------------------------

(defun my/org-project-git-context ()
  "Return (REPO . BRANCH) for the current buffer, or nil.
REPO is the git top-level absolute path (no trailing slash). BRANCH is
the symbolic ref from `git rev-parse --abbrev-ref HEAD', or nil on
detached HEAD."
  (let ((root (locate-dominating-file default-directory ".git")))
    (when root
      (let* ((repo (directory-file-name (expand-file-name root)))
             (branch
              (with-temp-buffer
                (let ((default-directory (file-name-as-directory repo)))
                  (when (zerop (call-process
                                "git" nil t nil
                                "rev-parse" "--abbrev-ref" "HEAD"))
                    (let ((s (string-trim (buffer-string))))
                      (unless (string= s "HEAD") s)))))))
        (cons repo branch)))))

(defun my/org-project--parse-mapping (str)
  "Parse `REPO' or `REPO@BRANCH' into (REPO . BRANCH-or-nil).
Splits on the rightmost `@' so repo paths containing `@' still parse."
  (if (string-match "\\`\\(.+\\)@\\([^@]+\\)\\'" str)
      (cons (match-string 1 str) (match-string 2 str))
    (cons str nil)))

(defun my/org-project--format-mapping (repo &optional branch)
  "Format REPO and optional BRANCH as a mapping string."
  (if (and branch (not (string-empty-p branch)))
      (format "%s@%s" repo branch)
    repo))

(defun my/org-project-find-by-context (repo branch)
  "Return the active project slug matching REPO and BRANCH, or nil.
A bare REPO mapping matches any branch; a REPO@BRANCH mapping must
match exactly. Branch-specific mappings take precedence over
any-branch mappings."
  (let ((projects (my/org-project--read-index))
        exact any)
    (dolist (p projects)
      (when (string= (plist-get p :status) "active")
        (dolist (m (plist-get p :repos))
          (let ((parsed (my/org-project--parse-mapping m)))
            (when (equal (car parsed) repo)
              (cond
               ((null (cdr parsed))
                (unless any (setq any (plist-get p :slug))))
               ((and branch (equal (cdr parsed) branch))
                (unless exact (setq exact (plist-get p :slug))))))))))
    (or exact any)))

(defun my/org-project--goto-heading (slug)
  "Move point to SLUG's heading in the current index buffer, or error."
  (goto-char (point-min))
  (unless (re-search-forward
           (format "^\\*+ +%s *$" (regexp-quote slug)) nil t)
    (user-error "%s not found in index" slug)))

(defun my/org-project--mapping-conflict-p (new-branch existing-branch)
  "Return non-nil if an existing mapping conflicts with a new one.
Both arguments may be nil, representing an any-branch mapping. A
conflict means the two mappings could match the same (repo, branch)
context. Any-branch on either side clobbers specific branches on the
other side, since an unambiguous lookup shouldn't be possible
afterwards."
  (cond
   ((null new-branch) t)                   ; new any-branch takes the whole repo
   ((null existing-branch) t)              ; existing any-branch already covers us
   (t (equal new-branch existing-branch))))

(defun my/org-project--clear-conflicting-mappings (slug repo branch)
  "Remove mappings matching REPO[@BRANCH] from projects other than SLUG.
Returns a list of (OTHER-SLUG . MAPPING-STRING) pairs that were removed."
  (let (cleared)
    (dolist (p (my/org-project--read-index))
      (let ((other (plist-get p :slug)))
        (unless (equal other slug)
          (dolist (m (plist-get p :repos))
            (let* ((parsed (my/org-project--parse-mapping m))
                   (r (car parsed))
                   (b (cdr parsed)))
              (when (and (equal r repo)
                         (my/org-project--mapping-conflict-p branch b))
                (my/org-project-remove-mapping other r b)
                (push (cons other m) cleared)))))))
    (nreverse cleared)))

(defun my/org-project-add-mapping (slug repo &optional branch)
  "Add REPO[@BRANCH] to SLUG's :REPOS: multi-value property.
Before adding, removes any mapping from other active projects that
would match the same (repo, branch), so the lookup remains
unambiguous."
  (let ((cleared (my/org-project--clear-conflicting-mappings slug repo branch))
        (index (my/org-project-index-file))
        (value (my/org-project--format-mapping repo branch)))
    (with-current-buffer (find-file-noselect index)
      (save-excursion
        (my/org-project--goto-heading slug)
        (org-entry-add-to-multivalued-property (point) "REPOS" value))
      (save-buffer))
    (when cleared
      (message "Cleared conflicting mapping%s: %s"
               (if (> (length cleared) 1) "s" "")
               (mapconcat (lambda (c) (format "%s → %s" (cdr c) (car c)))
                          cleared ", ")))))

(defun my/org-project-remove-mapping (slug repo &optional branch)
  "Remove REPO[@BRANCH] from SLUG's :REPOS: multi-value property."
  (let ((index (my/org-project-index-file))
        (value (my/org-project--format-mapping repo branch)))
    (with-current-buffer (find-file-noselect index)
      (save-excursion
        (my/org-project--goto-heading slug)
        (org-entry-remove-from-multivalued-property (point) "REPOS" value))
      (save-buffer))))

(defun my/org-project--read-save-choice (repo branch)
  "Prompt for how to save a mapping for REPO.
Returns one of the symbols `this-branch', `any-branch', or `cancel'."
  (let ((c (read-char-choice
            (format "Save mapping for %s%s? [y]es-this-branch [a]ny-branch [n]o: "
                    repo
                    (if branch (format " (branch %s)" branch) ""))
            '(?y ?a ?n))))
    (pcase c (?y 'this-branch) (?a 'any-branch) (?n 'cancel))))

(defun my/org-project--maybe-save-context-mapping (slug)
  "After setting SLUG as current, offer to save the current repo/branch.
Skips the prompt when we're not inside a git repo or when the current
(repo, branch) already maps to SLUG. Conflict handling is delegated
to `my/org-project-add-mapping'."
  (when-let ((ctx (my/org-project-git-context)))
    (let* ((repo (car ctx))
           (branch (cdr ctx))
           (existing (my/org-project-find-by-context repo branch)))
      (unless (equal existing slug)
        (pcase (my/org-project--read-save-choice repo branch)
          ('this-branch (my/org-project-add-mapping slug repo branch))
          ('any-branch  (my/org-project-add-mapping slug repo nil))
          ('cancel      nil))))))

;; ---- Set / clear current project --------------------------------

(defun my/org-project-set-current ()
  "Pick the current project.
When invoked inside a git repo, also offers to persist the current
(repo, branch) as a mapping for the chosen project."
  (interactive)
  (let* ((slugs (my/org-project-active-slugs))
         (_ (unless slugs (user-error "No active projects")))
         (choice (completing-read "Current project: " slugs nil t)))
    (setq my/org-current-project choice)
    (my/org-current-project-save)
    (force-mode-line-update t)
    (my/org-project--maybe-save-context-mapping choice)
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
         (whiteboard (expand-file-name "whiteboard.org" dir))
         (index (my/org-project-index-file)))
    (when (file-exists-p dir)
      (user-error "Project already exists: %s" dir))
    (make-directory dir t)
    (with-temp-file root
      (insert (format my/org-project-root-template slug slug)))
    (with-temp-file whiteboard
      (insert (format my/org-project-whiteboard-template slug slug)))
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

(defun my/org-project--file-for-kind (slug kind)
  "Return SLUG's file for KIND (`root' or `whiteboard')."
  (pcase kind
    ('root       (my/org-project-root-file slug))
    ('whiteboard (my/org-project-whiteboard-file slug))
    (_ (error "Unknown project file kind: %S" kind))))

(defun my/org-project--read-goto-kind ()
  "Read `[r]oot' or `[w]hiteboard'. Returns the kind symbol."
  (pcase (read-char-choice "File: [r]oot [w]hiteboard: " '(?r ?w))
    (?r 'root)
    (?w 'whiteboard)))

(defun my/org-project-goto ()
  "Pick an active project and open one of its files.
Prompts for the slug, then reads `[r]oot' or `[w]hiteboard' to
decide which file to open."
  (interactive)
  (let ((slugs (my/org-project-active-slugs)))
    (unless slugs
      (user-error "No active projects"))
    (let* ((slug (completing-read "Go to project: " slugs nil t))
           (kind (my/org-project--read-goto-kind)))
      (find-file (my/org-project--file-for-kind slug kind)))))

(defun my/org-project-goto-all ()
  "Pick any project (active or archived) and open one of its files.
Archived entries are annotated so you can distinguish them in the
completion list. Reads `[r]oot' or `[w]hiteboard' after picking the
slug."
  (interactive)
  (let* ((projects (my/org-project--read-index))
         (_ (unless projects (user-error "No projects")))
         (status-by-slug
          (mapcar (lambda (p)
                    (cons (plist-get p :slug) (plist-get p :status)))
                  projects))
         (candidates (sort (mapcar #'car status-by-slug) #'string<))
         (annot (lambda (cand)
                  (if (equal (cdr (assoc cand status-by-slug)) "archived")
                      "  [archived]"
                    "")))
         (completion-extra-properties
          (list :annotation-function annot))
         (slug (completing-read "Go to project (all): " candidates nil t))
         (kind (my/org-project--read-goto-kind)))
    (find-file (my/org-project--file-for-kind slug kind))))

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

;; ---- Interactive mapping commands -------------------------------

(defun my/org-project-mapping-add-here ()
  "Map the current buffer's (repo, branch) to a project of your choice."
  (interactive)
  (let ((ctx (my/org-project-git-context)))
    (unless ctx (user-error "Not inside a git repo"))
    (let* ((slugs (my/org-project-active-slugs))
           (_ (unless slugs (user-error "No active projects")))
           (slug (completing-read "Add mapping to project: " slugs nil t))
           (repo (car ctx))
           (branch (cdr ctx)))
      (pcase (my/org-project--read-save-choice repo branch)
        ('this-branch
         (my/org-project-add-mapping slug repo branch)
         (message "Mapped %s@%s → %s" repo branch slug))
        ('any-branch
         (my/org-project-add-mapping slug repo nil)
         (message "Mapped %s (any branch) → %s" repo slug))
        ('cancel (message "Cancelled"))))))

(defun my/org-project-mapping-remove-here ()
  "Remove any mapping that matches the current buffer's (repo, branch)."
  (interactive)
  (let ((ctx (my/org-project-git-context)))
    (unless ctx (user-error "Not inside a git repo"))
    (let* ((repo (car ctx))
           (branch (cdr ctx))
           (slug (my/org-project-find-by-context repo branch)))
      (unless slug
        (user-error "No mapping matches %s%s"
                    repo (if branch (concat "@" branch) "")))
      ;; A match could be branch-specific or any-branch; try both.
      (my/org-project-remove-mapping slug repo branch)
      (my/org-project-remove-mapping slug repo nil)
      (message "Removed mapping %s → %s" repo slug))))

;; ---- Clocking ---------------------------------------------------
;;
;; We clock on the `* <slug>' heading in projects/index.org rather than
;; per-task headings inside root.org. Each project therefore has a
;; single LOGBOOK drawer in index.org that accumulates across sessions,
;; which matches the "track time on the project as a whole" intent.

(defun my/org-project--clock-in-on-slug (slug)
  "Clock in on SLUG's heading in projects/index.org."
  (require 'org-clock)
  (let ((index (my/org-project-index-file)))
    (unless (file-exists-p index)
      (user-error "No projects yet"))
    (with-current-buffer (find-file-noselect index)
      (save-excursion
        (my/org-project--goto-heading slug)
        (org-clock-in))
      (save-buffer))))

(defun my/org-project-clock-in ()
  "Clock in on a project's index.org heading.
Defaults to the current project; prompts among active projects if
none is set. Does not change `my/org-current-project'."
  (interactive)
  (require 'org-clock)
  (let* ((slugs (my/org-project-active-slugs))
         (_ (unless slugs (user-error "No active projects")))
         (slug (or my/org-current-project
                   (completing-read "Clock in on project: " slugs nil t))))
    (my/org-project--clock-in-on-slug slug)
    (message "Clocked in on %s" slug)))

(defun my/org-project-clock-out ()
  "Clock out of the active clock."
  (interactive)
  (require 'org-clock)
  (if (org-clocking-p)
      (org-clock-out)
    (user-error "No active clock")))

(defun my/org-project-clock-goto ()
  "Jump to the currently-clocked heading."
  (interactive)
  (require 'org-clock)
  (org-clock-goto))

(defun my/org-project-clock-in-last ()
  "Resume the last clocked task."
  (interactive)
  (require 'org-clock)
  (org-clock-in-last))

;; ---- Transient menu ---------------------------------------------

(transient-define-prefix my/org-project-transient ()
  "Manage org-capture projects, clocks, and jumps."
  [["Projects"
    ("g" "Goto active"         my/org-project-goto)
    ("G" "Goto all"            my/org-project-goto-all)
    ("n" "New project"         my/org-project-new)
    ("a" "Archive project"     my/org-project-archive)
    ("l" "List (open index)"   my/org-project-list)]
   ["Current project"
    ("s" "Set current"         my/org-project-set-current)
    ("c" "Clear current"       my/org-project-clear-current)]]
  [["Clock"
    ("i" "Clock in"            my/org-project-clock-in)
    ("o" "Clock out"           my/org-project-clock-out)
    ("I" "Clock in last"       my/org-project-clock-in-last)
    ("j" "Goto clock"          my/org-project-clock-goto)]
   ["Mappings"
    ("M" "Map current repo"    my/org-project-mapping-add-here)
    ("R" "Unmap current repo"  my/org-project-mapping-remove-here)
    ("T" "Toggle autoswitch"   my/org-project-autoswitch-mode)]]
  [["Goto file"
    ("f" "Top-level org file"  my/org-goto-toplevel-file)]])

(provide 'my-org-projects)
;;; my-org-projects.el ends here
