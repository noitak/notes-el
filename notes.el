;;; notes.el --- Lightweight Markdown note manager -*- lexical-binding: t; -*-

;; Author: taku_tsunoi
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: outlines, convenience

;;; Commentary:

;; notes.el manages one Markdown file per note.  Each note has YAML front
;; matter, while recently accessed order is stored separately in
;; `.notes-access.json'.
;;
;; Use `notes-new' to create a note, `notes-list' to browse notes ordered by
;; recent access, and `notes-open' to open a note by completion.  In the notes
;; list buffer, RET opens the note at point, n creates a note, g refreshes the
;; list, r renames the note at point, and s searches notes.
;;
;; Notes are stored in `notes-directory', which defaults to ~/notes/.  Set it
;; before loading or using this package to keep notes somewhere else:
;;
;;   (setq notes-directory "~/Documents/notes/")
;;
;; Each note uses a timestamp-based id as its file name, so changing the title
;; does not rename the underlying Markdown file.  Opening a note updates access
;; metadata only; saving a note updates its `updated' front matter field.
;;
;; `notes-search' uses `consult-ripgrep' when the optional consult package is
;; installed.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function consult-ripgrep "ext:consult")

(defgroup notes nil
  "Lightweight Markdown note manager."
  :group 'applications
  :prefix "notes-")

(defcustom notes-directory (expand-file-name "~/notes/")
  "Directory where notes are stored."
  :type 'directory
  :group 'notes)

(defcustom notes-access-file-name ".notes-access.json"
  "File name used to store note access timestamps."
  :type 'string
  :group 'notes)

(defconst notes--list-buffer-name "*notes*")

(defvar-local notes--note-id nil
  "Note id associated with the current note buffer.")

(defvar-local notes--updating-front-matter nil
  "Non-nil while notes.el is updating front matter.")

(defvar notes-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'notes-list-open)
    (define-key map (kbd "g") #'notes-list-refresh)
    (define-key map (kbd "n") #'notes-list-new)
    (define-key map (kbd "r") #'notes-list-rename)
    (define-key map (kbd "s") #'notes-search)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `notes-list-mode'.")

(define-derived-mode notes-list-mode special-mode "notes-list"
  "Major mode for listing notes."
  (setq truncate-lines t))

(defun notes--directory ()
  "Return normalized `notes-directory'."
  (file-name-as-directory (expand-file-name notes-directory)))

(defun notes--ensure-directory ()
  "Ensure `notes-directory' exists."
  (make-directory (notes--directory) t))

(defun notes--access-file ()
  "Return the access metadata file path."
  (expand-file-name notes-access-file-name (notes--directory)))

(defun notes--note-file (id)
  "Return the Markdown file path for note ID."
  (expand-file-name (concat id ".md") (notes--directory)))

(defun notes--timestamp (&optional time)
  "Return TIME as an ISO-like timestamp with numeric time zone."
  (let ((timestamp (format-time-string "%Y-%m-%dT%H:%M:%S%z" time)))
    (replace-regexp-in-string
     "\\([+-][0-9][0-9]\\)\\([0-9][0-9]\\)\\'"
     "\\1:\\2"
     timestamp)))

(defun notes--id-from-time (&optional time)
  "Return a note id generated from TIME."
  (format-time-string "%Y%m%dT%H%M%S" time))

(defun notes--generate-id ()
  "Generate a note id that does not collide with existing files."
  (let* ((base (notes--id-from-time))
         (id base)
         (suffix 1))
    (while (file-exists-p (notes--note-file id))
      (setq id (format "%s-%d" base suffix))
      (setq suffix (1+ suffix)))
    id))

(defun notes--json-read-file (file)
  "Read JSON object from FILE and return it as a hash table."
  (if (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (if (string-empty-p (string-trim (buffer-string)))
            (make-hash-table :test 'equal)
          (let ((json-object-type 'hash-table)
                (json-array-type 'list)
                (json-key-type 'string)
                (json-false nil))
            (json-read))))
    (make-hash-table :test 'equal)))

(defun notes--json-write-file (file table)
  "Write hash TABLE to FILE as JSON."
  (notes--ensure-directory)
  (let ((json-encoding-pretty-print t))
    (with-temp-file file
      (insert (json-encode table))
      (insert "\n"))))

(defun notes--read-access ()
  "Read access metadata."
  (notes--json-read-file (notes--access-file)))

(defun notes--write-access (table)
  "Write access metadata TABLE."
  (notes--json-write-file (notes--access-file) table))

(defun notes--touch-access (id)
  "Set ID's access timestamp to now."
  (let ((table (notes--read-access)))
    (puthash id (notes--timestamp) table)
    (notes--write-access table)))

(defun notes--touch-current-buffer-access ()
  "Touch access metadata for the current note buffer."
  (when notes--note-id
    (notes--touch-access notes--note-id)))

(defun notes--front-matter-bounds ()
  "Return front matter bounds as (START END CONTENT-START CONTENT-END).

START and END include the opening and closing delimiter lines.
CONTENT-START and CONTENT-END bound the content between delimiters."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (looking-at "\\`---[ \t]*\n")
        (let ((start (point-min))
              (content-start (match-end 0)))
          (goto-char content-start)
          (when (re-search-forward "^---[ \t]*$" nil t)
            (list start (line-end-position) content-start (match-beginning 0))))))))

(defun notes--parse-front-matter-string (string)
  "Parse minimal YAML front matter STRING into a hash table."
  (let ((table (make-hash-table :test 'equal)))
    (with-temp-buffer
      (insert string)
      (goto-char (point-min))
      (while (re-search-forward "^\\([^:#\n]+\\):[ \t]*\\(.*\\)$" nil t)
        (let ((key (string-trim (match-string 1)))
              (value (string-trim (match-string 2))))
          (puthash key value table))))
    table))

(defun notes--unquote-yaml-string (value)
  "Return VALUE without simple YAML double quotes when present."
  (if (and (string-prefix-p "\"" value)
           (string-suffix-p "\"" value))
      (condition-case nil
          (let ((json-string value))
            (with-temp-buffer
              (insert json-string)
              (goto-char (point-min))
              (let ((json-object-type 'hash-table)
                    (json-array-type 'list)
                    (json-key-type 'string)
                    (json-false nil))
                (json-read))))
        (error value))
    value))

(defun notes--quote-yaml-string (value)
  "Return VALUE quoted as a YAML-compatible double-quoted string."
  (json-encode-string value))

(defun notes--read-front-matter-from-buffer ()
  "Read front matter from the current buffer."
  (let ((bounds (notes--front-matter-bounds)))
    (when bounds
      (notes--parse-front-matter-string
       (buffer-substring-no-properties (nth 2 bounds) (nth 3 bounds))))))

(defun notes--read-front-matter (file)
  "Read front matter from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (notes--read-front-matter-from-buffer)))

(defun notes--front-matter-get (metadata key)
  "Return KEY from METADATA."
  (when metadata
    (let ((value (gethash key metadata)))
      (if (and (stringp value) (member key '("title")))
          (notes--unquote-yaml-string value)
        value))))

(defun notes--note-file-p (file)
  "Return non-nil if FILE is a note file in `notes-directory'."
  (let ((file (expand-file-name file))
        (dir (notes--directory)))
    (and (string-equal (file-name-extension file) "md")
         (string-prefix-p dir file)
         (string-equal (file-name-directory file) dir))))

(defun notes--collect-notes ()
  "Return a list of note plists."
  (notes--ensure-directory)
  (let ((access (notes--read-access))
        notes)
    (dolist (file (directory-files (notes--directory) t "\\.md\\'"))
      (let* ((metadata (notes--read-front-matter file))
             (id (or (notes--front-matter-get metadata "id")
                     (file-name-base file)))
             (title (or (notes--front-matter-get metadata "title")
                        (file-name-base file)))
             (created (notes--front-matter-get metadata "created"))
             (accessed (or (gethash id access) created "")))
        (push (list :id id
                    :title title
                    :file file
                    :created created
                    :accessed accessed)
              notes)))
    (sort notes
          (lambda (a b)
            (string> (or (plist-get a :accessed) "")
                     (or (plist-get b :accessed) ""))))))

(defun notes--format-list-timestamp (timestamp)
  "Return TIMESTAMP formatted for display in `notes-list-mode'."
  (replace-regexp-in-string
   "T"
   " "
   (replace-regexp-in-string
    "\\(?:[+-][0-9]\\{2\\}:?[0-9]\\{2\\}\\)+\\'"
    ""
    (or timestamp ""))))

(defun notes--insert-list ()
  "Insert note list into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if-let* ((notes (notes--collect-notes)))
        (dolist (note notes)
          (let ((start (point))
                (title (plist-get note :title))
                (accessed (plist-get note :accessed)))
            (insert (format "%s  %s\n"
                            (notes--format-list-timestamp accessed)
                            title))
            (add-text-properties
             start (point)
             `(notes-id ,(plist-get note :id)
                        notes-file ,(plist-get note :file)
                        notes-title ,title
                        mouse-face highlight
                        help-echo "RET: open note"))))
      (insert "No notes yet. Press n to create one.\n"))
    (goto-char (point-min))))

(defun notes--setup-note-buffer ()
  "Set up the current buffer as a notes buffer when applicable."
  (when-let* ((file buffer-file-name)
              ((notes--note-file-p file))
              (metadata (notes--read-front-matter-from-buffer))
              (id (notes--front-matter-get metadata "id")))
    (setq notes--note-id id)
    (add-hook 'before-save-hook #'notes--before-save nil t)
    (notes--touch-current-buffer-access)))

(defun notes--replace-front-matter-field (key value)
  "Set front matter KEY to VALUE in the current buffer."
  (when-let* ((bounds (notes--front-matter-bounds)))
    (save-excursion
      (goto-char (nth 2 bounds))
      (let ((end (copy-marker (nth 3 bounds))))
        (if (re-search-forward
             (format "^%s:[ \t]*.*$" (regexp-quote key))
             end t)
            (replace-match (format "%s: %s" key value) t t)
          (goto-char end)
          (insert (format "%s: %s\n" key value)))))))

(defun notes--update-note-file-front-matter (file fields)
  "Update front matter FIELDS in FILE.
FIELDS is an alist of (KEY . VALUE), where VALUE is already formatted for YAML."
  (let ((buffer (find-buffer-visiting file)))
    (if buffer
        (with-current-buffer buffer
          (let ((notes--updating-front-matter t))
            (dolist (field fields)
              (notes--replace-front-matter-field (car field) (cdr field)))
            (save-buffer)))
      (with-temp-buffer
        (insert-file-contents file)
        (dolist (field fields)
          (notes--replace-front-matter-field (car field) (cdr field)))
        (write-region (point-min) (point-max) file nil 'silent)))))

(defun notes--rename-note-title (file title)
  "Rename note FILE to TITLE and update its `updated' timestamp."
  (when (string-empty-p (string-trim title))
    (user-error "Title cannot be empty"))
  (notes--update-note-file-front-matter
   file
   `(("title" . ,(notes--quote-yaml-string title))
     ("updated" . ,(notes--timestamp)))))

(defun notes--list-note-at-point ()
  "Return note properties at point in a notes list buffer."
  (unless (derived-mode-p 'notes-list-mode)
    (user-error "Not in a notes list buffer"))
  (let ((file (get-text-property (point) 'notes-file))
        (id (get-text-property (point) 'notes-id))
        (title (get-text-property (point) 'notes-title)))
    (unless (and file id)
      (user-error "No note at point"))
    (list :file file :id id :title title)))

(defun notes--before-save ()
  "Update the current note's `updated' field before saving."
  (when (and (not notes--updating-front-matter)
             buffer-file-name
             (notes--note-file-p buffer-file-name))
    (let ((notes--updating-front-matter t))
      (notes--replace-front-matter-field "updated" (notes--timestamp)))))

(defun notes--write-new-note (file id title timestamp)
  "Write a new note FILE with ID, TITLE, and TIMESTAMP."
  (with-temp-file file
    (insert "---\n")
    (insert "id: " id "\n")
    (insert "title: " (notes--quote-yaml-string title) "\n")
    (insert "created: " timestamp "\n")
    (insert "updated: " timestamp "\n")
    (insert "tags: []\n")
    (insert "---\n\n")))

;;;###autoload
(defun notes-list ()
  "Display notes ordered by recent access."
  (interactive)
  (notes--ensure-directory)
  (let ((buffer (get-buffer-create notes--list-buffer-name)))
    (with-current-buffer buffer
      (notes-list-mode)
      (notes--insert-list))
    (delete-other-windows)
    (switch-to-buffer buffer)))

;;;###autoload
(defun notes-list-refresh ()
  "Refresh the notes list."
  (interactive)
  (unless (derived-mode-p 'notes-list-mode)
    (user-error "Not in a notes list buffer"))
  (notes--insert-list))

;;;###autoload
(defun notes-list-new (title)
  "Create a new note with TITLE from a notes list buffer."
  (interactive "sTitle: ")
  (unless (derived-mode-p 'notes-list-mode)
    (user-error "Not in a notes list buffer"))
  (notes-new title))

;;;###autoload
(defun notes-list-rename (title)
  "Rename the note at point to TITLE in a notes list buffer."
  (interactive
   (let* ((note (notes--list-note-at-point))
          (title (plist-get note :title)))
     (list (read-string "Title: " title))))
  (let* ((note (notes--list-note-at-point))
         (file (plist-get note :file)))
    (notes--rename-note-title file title)
    (notes-list-refresh)))

;;;###autoload
(defun notes-list-open ()
  "Open the note at point in a notes list buffer."
  (interactive)
  (unless (derived-mode-p 'notes-list-mode)
    (user-error "Not in a notes list buffer"))
  (let ((file (get-text-property (point) 'notes-file))
        (id (get-text-property (point) 'notes-id)))
    (unless (and file id)
      (user-error "No note at point"))
    (notes--touch-access id)
    (find-file file)
    (notes--setup-note-buffer)))

;;;###autoload
(defun notes-new (title)
  "Create a new note with TITLE."
  (interactive "sTitle: ")
  (when (string-empty-p (string-trim title))
    (user-error "Title cannot be empty"))
  (notes--ensure-directory)
  (let* ((id (notes--generate-id))
         (file (notes--note-file id))
         (timestamp (notes--timestamp)))
    (notes--write-new-note file id title timestamp)
    (notes--touch-access id)
    (find-file file)
    (notes--setup-note-buffer)))

;;;###autoload
(defun notes-open (id)
  "Open note ID."
  (interactive
   (let* ((notes (notes--collect-notes))
          (choices (mapcar
                    (lambda (note)
                      (cons (plist-get note :title)
                            (plist-get note :id)))
                    notes)))
     (list (cdr (assoc (completing-read "Note: " choices nil t) choices)))))
  (let ((file (notes--note-file id)))
    (unless (file-exists-p file)
      (user-error "No note file for id: %s" id))
    (notes--touch-access id)
    (find-file file)
    (notes--setup-note-buffer)))

;;;###autoload
(defun notes-search ()
  "Search notes with `consult-ripgrep'."
  (interactive)
  (unless (require 'consult nil t)
    (user-error "consult is not installed"))
  (consult-ripgrep (notes--directory)))

;;;###autoload
(define-minor-mode notes-note-mode
  "Minor mode for notes Markdown files."
  :lighter " notes"
  (if notes-note-mode
      (notes--setup-note-buffer)
    (remove-hook 'before-save-hook #'notes--before-save t)))

;;;###autoload
(defun notes-enable-note-mode ()
  "Enable `notes-note-mode' when visiting a note file."
  (when (and buffer-file-name (notes--note-file-p buffer-file-name))
    (notes-note-mode 1)))

(add-hook 'find-file-hook #'notes-enable-note-mode)

(provide 'notes)

;;; notes.el ends here
