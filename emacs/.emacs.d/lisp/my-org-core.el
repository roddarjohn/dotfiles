;;; my-org-core.el --- Shared state for my-org-* modules -*- lexical-binding: t; -*-

;; Shared state used by the other my-org-* modules: the configuration
;; defvars (directory, categories, capture kinds, extra templates),
;; project path helpers, index parsing, and the file-set helpers
;; consumed by capture/agenda/refile. All defvars here are populated
;; from init.org; this file defines data and derivations only.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defvar my/org-directory nil
  "Base directory for my-org capture files.
Top-level files (inbox.org, journal.org) live directly in here,
category files live under <my/org-directory>/<subdir>/, and projects
live under <my/org-directory>/projects/<slug>/. Set in init.org.")

(defvar my/org-capture-categories nil
  "Categories used by capture and agenda.
Each entry is (KEY NAME SUBDIR [KINDS]):
  KEY    single-letter capture prefix
  NAME   description shown in the capture/agenda menus
  SUBDIR sub-directory under `my/org-directory' holding this
         category's org files (nil places them in `my/org-directory'
         itself)
  KINDS  optional list of kind symbols from
         `my/org-capture-category-kinds' to include; nil (or omitted)
         means all of them.
Set in init.org.")

(defvar my/org-capture-category-kinds nil
  "Alist of category-capture sub-template specs. Set in init.org.
See the \"capture kinds\" section of init.org for the shape.")

(defvar my/org-project-capture-kinds nil
  "Alist of per-project capture sub-template specs. Set in init.org.")

(defvar my/org-capture-extra-templates nil
  "Top-level capture templates merged verbatim. Set in init.org.")

(defun my/org-capture-kind-file (spec)
  "Return the string filename slot in SPEC's :target, or nil.
Skips non-string slots (e.g. project-kind symbols `root'/`whiteboard')
so callers iterating category kinds get just the literal filenames."
  (let* ((target (plist-get spec :target))
         (file (and (consp target) (cadr target))))
    (and (stringp file) file)))

(defun my/org-category-file-names ()
  "Distinct filenames referenced by `my/org-capture-category-kinds'.
Used by `my/org-category-files' and `my/org-toplevel-file-alist' to
enumerate per-category files for refile and the goto menu."
  (let (files)
    (dolist (cell my/org-capture-category-kinds)
      (let ((file (my/org-capture-kind-file (cdr cell))))
        (when (and file (not (member file files)))
          (push file files))))
    (nreverse files)))

(defun my/org-toplevel-file (name)
  "Return the path to top-level file NAME under `my/org-directory'."
  (expand-file-name name my/org-directory))

(defun my/org-category-dir (subdir)
  "Return the directory for category SUBDIR (nil → `my/org-directory')."
  (file-name-as-directory
   (if subdir
       (expand-file-name subdir my/org-directory)
     my/org-directory)))

(defun my/org-projects-dir ()
  "Return the single projects directory."
  (expand-file-name "projects/" my/org-directory))

(defun my/org-project-index-file ()
  "Return the index.org tracking project status."
  (expand-file-name "index.org" (my/org-projects-dir)))

(defun my/org-project-root-file (slug)
  "Return the root.org file for SLUG."
  (expand-file-name
   "root.org" (expand-file-name slug (my/org-projects-dir))))

(defun my/org-project-whiteboard-file (slug)
  "Return the whiteboard.org file for SLUG."
  (expand-file-name
   "whiteboard.org" (expand-file-name slug (my/org-projects-dir))))

(defun my/org-project--read-index ()
  "Parse index.org into plists.
Keys: :slug :status :created :archived-at :repos. :repos is a list
of strings each of form REPO or REPO@BRANCH. Uses a plain regex walk
so we don't depend on full org-mode setup in a temp buffer."
  (let ((index (my/org-project-index-file)))
    (when (file-exists-p index)
      (with-temp-buffer
        (insert-file-contents index)
        (goto-char (point-min))
        (let (projects)
          (while (re-search-forward "^\\*+ +\\(.+?\\) *$" nil t)
            (let ((slug (match-string 1))
                  (status "active")
                  (created nil)
                  (archived-at nil)
                  (repos nil))
              (save-excursion
                (forward-line 1)
                (when (looking-at-p "^[ \t]*:PROPERTIES:[ \t]*$")
                  (let ((drawer-end
                         (save-excursion
                           (and (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
                                (point)))))
                    (while (and drawer-end
                                (re-search-forward
                                 "^[ \t]*:\\([A-Za-z_]+\\): +\\(.*\\)$"
                                 drawer-end t))
                      (let ((k (upcase (match-string 1)))
                            (v (string-trim (match-string 2))))
                        (cond
                         ((string= k "STATUS")      (setq status v))
                         ((string= k "CREATED")     (setq created v))
                         ((string= k "ARCHIVED_AT") (setq archived-at v))
                         ((string= k "REPOS")
                          (setq repos (split-string v nil t)))))))))
              (push (list :slug slug :status status
                          :created created :archived-at archived-at
                          :repos repos)
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

(defun my/org-toplevel-file-alist ()
  "Return ((LABEL . PATH) ...) for the category-based capture files.
Includes the shared top-level inbox and journal and, for each
category, one entry per file derived from
`my/org-capture-category-kinds'."
  (let ((names (my/org-category-file-names))
        (entries (list (cons "inbox"   (my/org-toplevel-file "inbox.org"))
                       (cons "journal" (my/org-toplevel-file "journal.org")))))
    (dolist (cat my/org-capture-categories)
      (let* ((subdir (nth 2 cat))
             (dir (my/org-category-dir subdir)))
        (dolist (name names)
          (push (cons (format "%s/%s" subdir (file-name-base name))
                      (expand-file-name name dir))
                entries))))
    (nreverse entries)))

(defun my/org-category-files ()
  "Every org file reachable from the capture setup.
Includes the shared top-level inbox.org and journal.org, each
category's files (derived from `my/org-capture-category-kinds'),
and every active project's root and whiteboard so refile can reach
them."
  (let ((names (my/org-category-file-names))
        (files (list (my/org-toplevel-file "inbox.org")
                     (my/org-toplevel-file "journal.org"))))
    (dolist (cat my/org-capture-categories)
      (let ((dir (my/org-category-dir (nth 2 cat))))
        (dolist (name names)
          (push (expand-file-name name dir) files))))
    (dolist (slug (my/org-project-active-slugs))
      (push (my/org-project-root-file slug) files)
      (push (my/org-project-whiteboard-file slug) files))
    (nreverse files)))

(provide 'my-org-core)
;;; my-org-core.el ends here
