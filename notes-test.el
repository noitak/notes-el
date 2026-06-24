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
    (notes-new "First note: with colon" "Note")
    (let* ((file buffer-file-name)
           (metadata (notes--read-front-matter file))
           (id (notes--front-matter-get metadata "id"))
           (access (notes--read-access)))
      (should (string-suffix-p ".md" file))
      (should (string= "Note" (notes--front-matter-get metadata "type")))
      (should (string= "First note: with colon"
                       (notes--front-matter-get metadata "title")))
      (should (notes--front-matter-get metadata "timestamp"))
      (should-not (notes--front-matter-get metadata "updated"))
      (should (string= "[]" (notes--front-matter-get metadata "tags")))
      (should (gethash id access)))))

(ert-deftest notes-test-type-candidates-include-default-and-existing-types ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((notes-default-type "Note")
          (notes-type-candidates '("Reference" "Metric")))
      (notes--write-new-note
       (notes--note-file "20260521T100000")
       "20260521T100000"
       "Older"
       "Playbook"
       "2026-05-21T10:00:00+09:00")
      (let ((types (notes--all-note-types)))
        (should (member "Note" types))
        (should (member "Reference" types))
        (should (member "Metric" types))
        (should (member "Playbook" types))
        (should (= (length types)
                   (length (delete-dups (copy-sequence types)))))))))

(ert-deftest notes-test-type-prompt-uses-default-and-completion ()
  (notes-test--with-temp-directory
    (let ((notes-default-type "Note")
          (notes-type-candidates '("Reference"))
          seen-prompt
          seen-collection
          seen-default)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest args)
                   (setq seen-prompt prompt
                         seen-collection collection
                         seen-default (nth 4 args))
                   "")))
        (should (string= "Note" (notes--read-type)))
        (should (string-match-p "Type (default Note):" seen-prompt))
        (should (member "Reference" seen-collection))
        (should (equal "Note" seen-default))))))

(ert-deftest notes-test-collect-notes-sorts-by-access ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (notes--write-new-note
     (notes--note-file "20260521T100000")
     "20260521T100000"
     "Older"
     "Note"
     "2026-05-21T10:00:00+09:00")
    (notes--write-new-note
     (notes--note-file "20260521T110000")
     "20260521T110000"
     "Newer"
     "Note"
     "2026-05-21T11:00:00+09:00")
    (let ((access (make-hash-table :test 'equal)))
      (puthash "20260521T100000" "2026-05-21T12:00:00+09:00" access)
      (puthash "20260521T110000" "2026-05-21T11:00:00+09:00" access)
      (notes--write-access access))
    (let ((notes (notes--collect-notes)))
      (should (string= "Older" (plist-get (car notes) :title)))
      (should (string= "Newer" (plist-get (cadr notes) :title))))))

(ert-deftest notes-test-collect-notes-falls-back-to-updated-timestamp ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (with-temp-file (notes--note-file "20260521T100000")
      (insert "---\n")
      (insert "type: Note\n")
      (insert "id: 20260521T100000\n")
      (insert "title: \"Legacy\"\n")
      (insert "updated: 2026-05-21T12:00:00+09:00\n")
      (insert "tags: []\n")
      (insert "---\n\n"))
    (let ((notes (notes--collect-notes)))
      (should (string= "2026-05-21T12:00:00+09:00"
                       (plist-get (car notes) :timestamp)))
      (should (string= "2026-05-21T12:00:00+09:00"
                       (plist-get (car notes) :accessed))))))

(ert-deftest notes-test-list-displays-access-timestamps ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (notes--write-new-note
     (notes--note-file "20260521T100000")
     "20260521T100000"
     "Older"
     "Note"
     "2026-05-21T10:00:00+09:00")
    (notes--write-new-note
     (notes--note-file "20260521T110000")
     "20260521T110000"
     "Newer"
     "Note"
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
        (notes-list-new "From list" "Note")
        (setq file buffer-file-name))
      (let* ((metadata (notes--read-front-matter file)))
        (should (string= "Note" (notes--front-matter-get metadata "type")))
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
       "Note"
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
       "Note"
       "2026-05-21T10:00:00+09:00")
      (with-temp-buffer
        (notes-list-mode)
        (should (eq (lookup-key notes-list-mode-map (kbd "r"))
                    #'notes-list-rename))
        (notes--insert-list)
        (notes-list-rename "New title")
        (let ((line (substring-no-properties (buffer-string))))
          (should (string-suffix-p "  New title\n" line))
          (should (= 31 (length line)))
          (should (= ?- (aref line 4)))
          (should (= ?- (aref line 7)))
          (should (= ?  (aref line 10)))
          (should (= ?: (aref line 13)))
          (should (= ?: (aref line 16)))))
      (let ((metadata (notes--read-front-matter file)))
        (should (string= "New title"
                         (notes--front-matter-get metadata "title")))
        (should-not (notes--front-matter-get metadata "updated"))
        (should (string-match-p
                 "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}[+-][0-9]\\{2\\}:[0-9]\\{2\\}\\'"
                 (notes--front-matter-get metadata "timestamp")))))))

(ert-deftest notes-test-list-rename-rejects-empty-title ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (notes--write-new-note
     (notes--note-file "20260521T100000")
     "20260521T100000"
     "Old title"
     "Note"
     "2026-05-21T10:00:00+09:00")
    (with-temp-buffer
      (notes-list-mode)
      (notes--insert-list)
      (should-error (notes-list-rename "  ") :type 'user-error))))

(ert-deftest notes-test-before-save-updates-timestamp-field ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((file (notes--note-file "20260521T100000")))
      (notes--write-new-note
       file
       "20260521T100000"
       "Save me"
       "Note"
       "2026-05-21T10:00:00+09:00")
      (find-file file)
      (notes-note-mode 1)
      (goto-char (point-max))
      (insert "Body\n")
      (save-buffer)
      (let ((metadata (notes--read-front-matter file)))
        (should-not
         (string= "2026-05-21T10:00:00+09:00"
                  (notes--front-matter-get metadata "timestamp")))
        (should
         (string-match-p
          "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}[+-][0-9]\\{2\\}:[0-9]\\{2\\}\\'"
          (notes--front-matter-get metadata "timestamp")))))))

(ert-deftest notes-test-auto-save-is-enabled-by-default ()
  (should notes-auto-save))

(ert-deftest notes-test-note-mode-enables-auto-save-hook ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((file (notes--note-file "20260521T100000")))
      (notes--write-new-note
       file
       "20260521T100000"
       "Auto save me"
       "Note"
       "2026-05-21T10:00:00+09:00")
      (find-file file)
      (notes-note-mode 1)
      (should (memq #'notes--schedule-auto-save after-change-functions)))))

(ert-deftest notes-test-auto-save-can-be-disabled ()
  (notes-test--with-temp-directory
    (let ((notes-auto-save nil))
      (notes--ensure-directory)
      (let ((file (notes--note-file "20260521T100000")))
        (notes--write-new-note
         file
         "20260521T100000"
         "Manual save me"
         "Note"
         "2026-05-21T10:00:00+09:00")
        (find-file file)
        (notes-note-mode 1)
        (should-not (memq #'notes--schedule-auto-save after-change-functions))))))

(ert-deftest notes-test-auto-save-schedules-and-cleans-up-timer ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((file (notes--note-file "20260521T100000")))
      (notes--write-new-note
       file
       "20260521T100000"
       "Timer save me"
       "Note"
       "2026-05-21T10:00:00+09:00")
      (find-file file)
      (notes-note-mode 1)
      (goto-char (point-max))
      (insert "Body\n")
      (should (timerp notes--auto-save-timer))
      (notes-note-mode -1)
      (should-not notes--auto-save-timer)
      (should-not (memq #'notes--schedule-auto-save after-change-functions)))))

(ert-deftest notes-test-find-file-touches-access ()
  (notes-test--with-temp-directory
    (notes--ensure-directory)
    (let ((file (notes--note-file "20260521T120000")))
      (notes--write-new-note
       file
       "20260521T120000"
       "Find me"
       "Note"
       "2026-05-21T12:00:00+09:00")
      (should-not (gethash "20260521T120000" (notes--read-access)))
      (find-file file)
      (should (gethash "20260521T120000" (notes--read-access))))))

(provide 'notes-test)

;;; notes-test.el ends here
