;;; my-org-autoswitch.el --- Auto-switch current org project by repo/branch -*- lexical-binding: t; -*-

;; Global minor mode that keeps `my/org-current-project' in sync with
;; the selected buffer's git (repo, branch), using the mappings stored
;; in `index.org' as :REPOS: multi-value properties (see
;; `my-org-projects' for writers and `my-org-core' for the parser).
;;
;; Behavior when the mode is on:
;;   - Entering a buffer whose (repo, branch) maps to a project: switch
;;     `my/org-current-project' to that project.
;;   - Entering a buffer with no matching mapping: clear the current
;;     project so the modeline and capture `.` menu reflect that.
;;
;; The mode is defined here but NOT enabled by default — require and
;; enable it explicitly from init.org.

;;; Code:

(require 'my-org-core)
(require 'my-org-projects)

;; ---- Modeline --------------------------------------------------
;;
;; This module owns the current-project concept that shows up on the
;; modeline, so the segment (and a minimal format that uses it) live
;; here rather than in `my-org-projects'.

(defvar my/org-current-project-mode-line-segment
  '(:eval (when my/org-current-project
            (propertize (format " [proj: %s]" my/org-current-project)
                        'face 'mode-line-emphasis
                        'help-echo "Current org capture project"))))
(put 'my/org-current-project-mode-line-segment 'risky-local-variable t)

(defvar my/projectile-mode-line-segment
  '(:eval (when (and (bound-and-true-p projectile-mode)
                     (fboundp 'projectile-project-name))
            (let ((name (projectile-project-name)))
              (and name
                   (not (string= name ""))
                   (not (string= name "-"))
                   (propertize (format " <%s>" name)
                               'face 'mode-line-emphasis
                               'help-echo "Projectile project"))))))
(put 'my/projectile-mode-line-segment 'risky-local-variable t)

(defvar my/org-minimal-mode-line-format
  '("%e" " "
    mode-line-buffer-identification
    "  L%l  "
    "(" mode-name ")"
    my/projectile-mode-line-segment
    my/org-current-project-mode-line-segment)
  "Minimal modeline: buffer name, line number, major mode, projectile
project, current org project.
Install with
  (setq-default mode-line-format my/org-minimal-mode-line-format).")

;; ---- Auto-switch state -----------------------------------------

(defvar my/org-project-autoswitch--last-context 'unset
  "Cached last (REPO . BRANCH) pair, or nil, or the symbol `unset'.
Used to skip redundant lookups when nothing about the buffer's git
context has changed.")

(defun my/org-project-autoswitch--apply ()
  "Set `my/org-current-project' from the selected buffer's git context."
  (let ((ctx (ignore-errors (my/org-project-git-context))))
    (unless (equal ctx my/org-project-autoswitch--last-context)
      (setq my/org-project-autoswitch--last-context ctx)
      (let ((slug (and ctx
                       (my/org-project-find-by-context
                        (car ctx) (cdr ctx)))))
        (unless (equal slug my/org-current-project)
          (setq my/org-current-project slug)
          (my/org-current-project-save)
          (force-mode-line-update t))))))

(defun my/org-project-autoswitch--hook (&rest _)
  (my/org-project-autoswitch--apply))

;;;###autoload
(define-minor-mode my/org-project-autoswitch-mode
  "Toggle auto-switching of `my/org-current-project' based on git context.
When enabled, selecting a buffer whose git (repo, branch) matches a
mapping in index.org switches to that project; buffers with no
matching mapping clear the current project."
  :global t
  :lighter nil
  :group 'org
  (if my/org-project-autoswitch-mode
      (progn
        (setq my/org-project-autoswitch--last-context 'unset)
        (add-hook 'window-buffer-change-functions
                  #'my/org-project-autoswitch--hook)
        (add-hook 'window-selection-change-functions
                  #'my/org-project-autoswitch--hook)
        (my/org-project-autoswitch--apply))
    (remove-hook 'window-buffer-change-functions
                 #'my/org-project-autoswitch--hook)
    (remove-hook 'window-selection-change-functions
                 #'my/org-project-autoswitch--hook)
    (setq my/org-project-autoswitch--last-context 'unset)))

(provide 'my-org-autoswitch)
;;; my-org-autoswitch.el ends here
