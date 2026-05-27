;;; notes-test.el --- Tests for notes.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'notes)

(defmacro notes-test--with-temp-directory (&rest body)
  "Run BODY with `notes-directory' bound to a temporary directory."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "notes-test-" t))
          (notes-directory (file-name-as-directory dir)))
     (unwind-protect
         (progn ,@body)
       (dolist (buffer (buffer-list))
         (with-current-buffer buffer
           (when (and buffer-file-name
                      (string-prefix-p notes-directory
                                       (expand-file-name buffer-file-name)))
             (set-buffer-modified-p nil)
             (kill-buffer buffer))))
       (delete-directory dir t))))

(ert-deftest notes-test-new-note-writes-front-matter-and-access ()
  (notes-test--with-temp-directory
    (notes-new "First note: with colon")
    (let* ((file buffer-file-name)
           (metadata (notes--read-front-matter file))
           (id (notes--front-matter-get metadata "id"))
           (access (notes--read-access)))
      (should (string-suffix-p ".md" file))
      (should (string= "First note: with colon"
                       (notes--front-matter-get metadata "title")))
      (should (string= "[]" (notes--front-matter-get metadata "tags")))
      (should (gethash id access)))))

(ert-deftest notes-test-collect-notes-sorts-by-access ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (notes--write-new-note
     (notes--note-file "20260521T100000")
     "20260521T100000"
     "Older"
     "2026-05-21T10:00:00+09:00")
    (notes--write-new-note
     (notes--note-file "20260521T110000")
     "20260521T110000"
     "Newer"
     "2026-05-21T11:00:00+09:00")
    (let ((access (make-hash-table :test 'equal)))
      (puthash "20260521T100000" "2026-05-21T12:00:00+09:00" access)
      (puthash "20260521T110000" "2026-05-21T11:00:00+09:00" access)
      (notes--write-access access))
    (let ((notes (notes--collect-notes)))
      (should (string= "Older" (plist-get (car notes) :title)))
      (should (string= "Newer" (plist-get (cadr notes) :title))))))

(ert-deftest notes-test-list-displays-access-timestamps ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (notes--write-new-note
     (notes--note-file "20260521T100000")
     "20260521T100000"
     "Older"
     "2026-05-21T10:00:00+09:00")
    (notes--write-new-note
     (notes--note-file "20260521T110000")
     "20260521T110000"
     "Newer"
     "2026-05-21T11:00:00+09:00")
    (let ((access (make-hash-table :test 'equal)))
      (puthash "20260521T100000" "2026-05-21T12:00:00+09:00" access)
      (puthash "20260521T110000" "2026-05-21T11:00:00+09:00" access)
      (notes--write-access access))
    (with-temp-buffer
      (notes-list-mode)
      (notes--insert-list)
      (should (string=
               "2026-05-21 12:00:00  Older\n2026-05-21 11:00:00  Newer\n"
               (buffer-string)))
      (goto-char (point-min))
      (should (string= "20260521T100000"
                       (get-text-property (point) 'notes-id))))))

(ert-deftest notes-test-list-opens-full-size ()
  (notes-test--with-temp-directory
    (save-window-excursion
      (split-window-right)
      (should-not (one-window-p))
      (notes-list)
      (should (one-window-p))
      (should (eq major-mode 'notes-list-mode))
      (should (string= notes--list-buffer-name (buffer-name))))))

(ert-deftest notes-test-format-list-timestamp-removes-time-zone ()
  (should (string= "2026-05-21 12:00:00"
                   (notes--format-list-timestamp
                    "2026-05-21T12:00:00+09:00")))
  (should (string= "2026-05-21 12:00:00"
                   (notes--format-list-timestamp
                    "2026-05-21T12:00:00+0900")))
  (should (string= "2026-05-21 12:00:00"
                   (notes--format-list-timestamp
                    "2026-05-21T12:00:00+09:00+09:00"))))

(ert-deftest notes-test-list-new-shortcut-creates-note ()
  (notes-test--with-temp-directory
    (let (file)
      (with-temp-buffer
        (notes-list-mode)
        (should (eq (lookup-key notes-list-mode-map (kbd "n"))
                    #'notes-list-new))
        (notes-list-new "From list")
        (setq file buffer-file-name))
      (let* ((metadata (notes--read-front-matter file)))
        (should (string= "From list"
                         (notes--front-matter-get metadata "title")))))))

(ert-deftest notes-test-list-refresh-shortcut-updates-list ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (with-temp-buffer
      (notes-list-mode)
      (should (eq (lookup-key notes-list-mode-map (kbd "g"))
                  #'notes-list-refresh))
      (notes--insert-list)
      (should (string= "No notes yet. Press n to create one.\n"
                       (buffer-string)))
      (notes--write-new-note
       (notes--note-file "20260521T100000")
       "20260521T100000"
       "Refresh me"
       "2026-05-21T10:00:00+09:00")
      (notes-list-refresh)
      (should (string= "2026-05-21 10:00:00  Refresh me\n"
                       (buffer-string))))))

(ert-deftest notes-test-list-search-shortcut ()
  (notes-test--with-temp-directory
    (with-temp-buffer
      (notes-list-mode)
      (should (eq (lookup-key notes-list-mode-map (kbd "s"))
                  #'notes-search)))))

(ert-deftest notes-test-list-rename-shortcut-updates-title ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((file (notes--note-file "20260521T100000")))
      (notes--write-new-note
       file
       "20260521T100000"
       "Old title"
       "2026-05-21T10:00:00+09:00")
      (with-temp-buffer
        (notes-list-mode)
        (should (eq (lookup-key notes-list-mode-map (kbd "r"))
                    #'notes-list-rename))
        (notes--insert-list)
        (notes-list-rename "New title")
        (should (string= "2026-05-21 10:00:00  New title\n"
                         (buffer-string))))
      (let ((metadata (notes--read-front-matter file)))
        (should (string= "New title"
                         (notes--front-matter-get metadata "title")))
        (should-not (string= "2026-05-21T10:00:00+09:00"
                             (notes--front-matter-get metadata "updated")))))))

(ert-deftest notes-test-list-rename-rejects-empty-title ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (notes--write-new-note
     (notes--note-file "20260521T100000")
     "20260521T100000"
     "Old title"
     "2026-05-21T10:00:00+09:00")
    (with-temp-buffer
      (notes-list-mode)
      (notes--insert-list)
      (should-error (notes-list-rename "  ") :type 'user-error))))

(ert-deftest notes-test-before-save-updates-updated-field ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((file (notes--note-file "20260521T100000")))
      (notes--write-new-note
       file
       "20260521T100000"
       "Save me"
       "2026-05-21T10:00:00+09:00")
      (find-file file)
      (notes-note-mode 1)
      (goto-char (point-max))
      (insert "Body\n")
      (save-buffer)
      (let ((metadata (notes--read-front-matter file)))
        (should-not
         (string= "2026-05-21T10:00:00+09:00"
                  (notes--front-matter-get metadata "updated")))
        (should
         (string-match-p
          "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}[+-][0-9]\\{2\\}:[0-9]\\{2\\}\\'"
          (notes--front-matter-get metadata "updated")))))))

(ert-deftest notes-test-find-file-touches-access ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((file (notes--note-file "20260521T120000")))
      (notes--write-new-note
       file
       "20260521T120000"
       "Find me"
       "2026-05-21T12:00:00+09:00")
      (should-not (gethash "20260521T120000" (notes--read-access)))
      (find-file file)
      (should (gethash "20260521T120000" (notes--read-access))))))

(provide 'notes-test)

;;; notes-test.el ends here
