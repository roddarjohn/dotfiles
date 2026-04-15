;;; my-org-interview.el --- Interview note taking -*- lexical-binding: t; -*-

;; Interview-style note taking. The capture template writes an
;; `:INTERVIEW_MODE: t' property onto the "Raw notes" subheading of
;; each interview, and the buffer-local minor mode
;; `my/org-interview-mode' binds `C-<return>' to a handler that
;; inserts a timestamped list item whenever point is inside a
;; subtree carrying that property (inherited), falling back to a
;; normal heading elsewhere.
;;
;; The mode auto-enables in any org buffer (or capture buffer) that
;; contains at least one such subtree, via the hook function
;; `my/org-interview-maybe-enable'. Wire that hook up from init.org.

;;; Code:

(require 'org)

(defconst my/org-interview-property "INTERVIEW_MODE"
  "Name of the subtree property that activates interview-mode behavior.
When a subtree (or any ancestor) carries this property,
`my/org-interview-c-return' inserts a timestamped list item instead
of a heading.")

(defconst my/org-interview-capture-template-body
  (concat
   "* %^{Interviewee} — %^{Position}\n"
   "** Overview\n"
   "** Raw notes\n"
   ":PROPERTIES:\n"
   ":" my/org-interview-property ": t\n"
   ":END:\n"
   "%?\n"
   "** Materials\n")
  "Capture template body for interview notes.
Consumed by `my-org-capture' when building the per-category
interview templates. Embeds the INTERVIEW_MODE property on the live
notes subheading so `my/org-interview-mode' can recognize it
without matching on heading names.")

(defun my/org-interview--active-at-point-p ()
  "Return non-nil when point's subtree carries the INTERVIEW_MODE property.
Walks up inherited properties so the timestamped-item behavior also
works inside nested subheadings."
  (save-excursion
    (and (ignore-errors (org-back-to-heading t) t)
         (org-entry-get (point) my/org-interview-property t))))

(defun my/org-interview--insert-timestamped-item ()
  "Start a new plain list item prefixed with the current HH:MM."
  (end-of-line)
  (newline)
  (insert (format-time-string "- %H:%M ")))

(defun my/org-interview-c-return ()
  "Interview-aware `C-<return>' handler.
Inside an INTERVIEW_MODE subtree insert a timestamped list item;
anywhere else fall back to `org-insert-heading-respect-content'."
  (interactive)
  (if (my/org-interview--active-at-point-p)
      (my/org-interview--insert-timestamped-item)
    (call-interactively #'org-insert-heading-respect-content)))

(defvar my/org-interview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<return>") #'my/org-interview-c-return)
    map)
  "Keymap for `my/org-interview-mode'.")

;;;###autoload
(define-minor-mode my/org-interview-mode
  "Buffer-local mode for interview-style note taking.
When enabled, \\[my/org-interview-c-return] checks the subtree at
point for the INTERVIEW_MODE property and inserts a timestamped
list item when it's set, or a normal heading otherwise. Normally
auto-enabled by `my/org-interview-maybe-enable' when an org buffer
contains any INTERVIEW_MODE subtree."
  :lighter " Iv"
  :keymap my/org-interview-mode-map
  :group 'org)

(defun my/org-interview--buffer-has-property-p ()
  "Return non-nil if the current buffer has any INTERVIEW_MODE property."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward
     (format "^[ \t]*:%s:" my/org-interview-property)
     nil t)))

(defun my/org-interview-maybe-enable ()
  "Enable `my/org-interview-mode' if this buffer has an INTERVIEW_MODE subtree."
  (when (my/org-interview--buffer-has-property-p)
    (my/org-interview-mode 1)))

(provide 'my-org-interview)
;;; my-org-interview.el ends here
