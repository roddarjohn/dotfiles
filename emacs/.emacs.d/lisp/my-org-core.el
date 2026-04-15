;;; my-org-core.el --- Shared state for my-org-* modules -*- lexical-binding: t; -*-

;; Shared definitions used by the other my-org-* modules: the category
;; list, project path helpers, index parsing, and the file-set helpers
;; consumed by capture/agenda/refile. This file defines data only — all
;; invocation wiring lives in init.org.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defvar my/org-capture-categories
  '(("w" "Work"     "work")
    ("p" "Personal" "personal")
    ("t" "Talos"    "talos")
    ("d" "Debate"   "debate"))
  "List of (KEY NAME SUBDIR) tuples used by capture and agenda.")

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
Includes the shared top-level inbox and each category's
journal/inbox/notes files, whether or not they exist on disk."
  (let ((entries (list (cons "inbox"
                             (expand-file-name
                              "~/org/src/orgfiles/inbox.org")))))
    (dolist (cat my/org-capture-categories)
      (let ((subdir (nth 2 cat)))
        (dolist (name '("journal" "inbox" "notes" "whiteboard"))
          (push (cons (format "%s/%s" subdir name)
                      (expand-file-name
                       (format "~/org/src/orgfiles/%s/%s.org" subdir name)))
                entries))))
    (nreverse entries)))

(defun my/org-category-files ()
  "Every org file reachable from the capture setup.
Includes the shared top-level inbox.org, per-category
journal/inbox/notes files, and every active project's root.org so
refile can reach them."
  (let ((files (list (expand-file-name "~/org/src/orgfiles/inbox.org"))))
    (dolist (cat my/org-capture-categories)
      (let* ((subdir (nth 2 cat))
             (dir (format "~/org/src/orgfiles/%s/" subdir)))
        (dolist (name '("journal.org" "inbox.org" "notes.org" "whiteboard.org"))
          (push (expand-file-name (concat dir name)) files))))
    (dolist (slug (my/org-project-active-slugs))
      (push (my/org-project-root-file slug) files)
      (push (my/org-project-whiteboard-file slug) files))
    (nreverse files)))

(provide 'my-org-core)
;;; my-org-core.el ends here
