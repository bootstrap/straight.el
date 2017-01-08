;;; straight.el --- The straightforward package manager.

;; Copyright (C) 2017 Radon Rosborough

;; Author: Radon Rosborough <radon.neon@gmail.com>
;; Homepage: https://github.com/raxod502/straight.el
;; Keywords: extensions
;; Created: 1 Jan 2017

;;; Commentary:

;; Please see https://github.com/raxod502/straight.el for more
;; information.

;;; Code:

;; To see the outline of this file, run M-x occur with a query of four
;; semicolons followed by a space.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Libraries

(require 'subr-x)
(require 'cl-lib)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Evil GPL code from package-build

(defconst package-build-default-files-spec
  '("*.el" "*.el.in" "dir"
    "*.info" "*.texi" "*.texinfo"
    "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
    (:exclude ".dir-locals.el" "test.el" "tests.el" "*-test.el" "*-tests.el"))
  "Default value for :files attribute in recipes.")

(defun package-build-expand-file-specs (dir specs &optional subdir allow-empty)
  "In DIR, expand SPECS, optionally under SUBDIR.
The result is a list of (SOURCE . DEST), where SOURCE is a source
file path and DEST is the relative path to which it should be copied.

If the resulting list is empty, an error will be reported.  Pass t
for ALLOW-EMPTY to prevent this error."
  (let ((default-directory dir)
        (prefix (if subdir (format "%s/" subdir) ""))
        (lst))
    (dolist (entry specs lst)
      (setq lst
            (if (consp entry)
                (if (eq :exclude (car entry))
                    (cl-nset-difference lst
                                        (package-build-expand-file-specs dir (cdr entry) nil t)
                                        :key 'car
                                        :test 'equal)
                  (nconc lst
                         (package-build-expand-file-specs
                          dir
                          (cdr entry)
                          (concat prefix (car entry))
                          t)))
              (nconc
               lst (mapcar (lambda (f)
                             (let ((destname)))
                             (cons f
                                   (concat prefix
                                           (replace-regexp-in-string
                                            "\\.in\\'"
                                            ""
                                            (file-name-nondirectory f)))))
                           (file-expand-wildcards entry))))))
    (when (and (null lst) (not allow-empty))
      (error "No matching file(s) found in %s: %s" dir specs))
    lst))

(defun package-build--config-file-list (config)
  "Get the :files spec from CONFIG, or return `package-build-default-files-spec'."
  (let ((file-list (plist-get config :files)))
    (cond
     ((null file-list)
      package-build-default-files-spec)
     ((eq :defaults (car file-list))
      (append package-build-default-files-spec (cdr file-list)))
     (t
      file-list))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Low-level API

(defun straight--dir (&rest segments)
  (apply 'concat user-emacs-directory
         (mapcar (lambda (segment)
                   (concat segment "/"))
                 (cons "straight" segments))))

(defun straight--file (&rest segments)
  (substring (apply 'straight--dir segments) 0 -1))

(defvar straight--cache nil)

;;;###autoload
(defun straight-load-cache ()
  (setq straight--cache
        (or (with-temp-buffer
              (insert-file-contents-literally
               (straight--file "cache.el"))
              (ignore-errors
                (read (current-buffer))))
            (make-hash-table :test 'equal))))

;;;###autoload
(defun straight-save-cache ()
  (with-temp-file (straight--file "cache.el")
    (pp straight--cache (current-buffer))))

(defun straight--validate-build-recipe (build-recipe)
  (unless (plist-get build-recipe :name)
    (error "build recipe is missing `:name': %S" build-recipe))
  (unless (plist-get build-recipe :repo)
    (error "build recipe is missing `:repo': %S" build-recipe)))

;;;###autoload
(defun straight-package-might-be-modified-p (build-recipe)
  (straight--validate-build-recipe build-recipe)
  (let* ((name (plist-get build-recipe :name))
         (repo (plist-get build-recipe :repo))
         (mtime (gethash name straight--cache)))
    (or (not mtime)
        (with-temp-buffer
          (let ((default-directory (straight--dir "repos" repo)))
            (call-process
             "find" nil '(t t) nil
             "." "-name" ".git" "-o" "-newermt" mtime "-print")
            (> (buffer-size) 0))))))

(defun straight--symlink-package (build-recipe)
  (let ((name (plist-get build-recipe :name))
        (repo (plist-get build-recipe :repo)))
    (ignore-errors
      (delete-directory
       (straight--dir "build" name)
       'recursive))
    (make-directory (straight--dir "build" name) 'parents)
    (dolist (spec (package-build-expand-file-specs
                   (straight--dir "repos" repo)
                   (package-build--config-file-list build-recipe)))
      (let ((repo-file (straight--file "repos" repo (car spec)))
            (build-file (straight--file "build" name (cdr spec))))
        (unless (file-exists-p repo-file)
          (error "file %S does not exist" repo-file))
        (make-directory (file-name-directory build-file) 'parents)
        (make-symbolic-link repo-file build-file)))))

(defun straight--autoload-file (package-name)
  (format "%s-autoloads.el" package-name))

(defun straight--generate-package-autoloads (build-recipe)
  (let* ((name (plist-get build-recipe :name))
         (generated-autoload-file
          (straight--file
           "build" name
           (straight--autoload-file name)))
         ;; Silence `autoload-generate-file-autoloads'.
         (noninteractive t))
    (ignore-errors
      (delete-file generated-autoload-file))
    (update-directory-autoloads
     (straight--dir "build" name))))

(defun straight--byte-compile-package (build-recipe)
  (let ((name (plist-get build-recipe :name)))
    (cl-letf (((symbol-function #'save-some-buffers) #'ignore))
      (byte-recompile-directory
       (straight--dir "build" name)
       0 'force))))

(defun straight--update-build-mtime (build-recipe)
  (let ((name (plist-get build-recipe :name))
        (mtime (format-time-string "%FT%T%z")))
    (puthash name mtime straight--cache)))

;;;###autoload
(defun straight-build-package (build-recipe)
  (straight--validate-build-recipe build-recipe)
  (straight--symlink-package build-recipe)
  (straight--generate-package-autoloads build-recipe)
  (straight--byte-compile-package build-recipe)
  (straight--update-build-mtime build-recipe))

;;;###autoload
(defun straight-add-package-to-load-path (build-recipe)
  (straight--validate-build-recipe build-recipe)
  (let ((name (plist-get build-recipe :name)))
    (add-to-list 'load-path (straight--dir "build" name))))

;;;###autoload
(defun straight-install-package-autoloads (build-recipe)
  (straight--validate-build-recipe build-recipe)
  (let ((name (plist-get build-recipe :name)))
    (load (straight--file "build" name (straight--autoload-file name))
          nil 'nomessage)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Temporary placeholder for high-level API

;;;###autoload
(defun straight-load-package (build-recipe)
  (when (straight-package-might-be-modified-p build-recipe)
    (straight-build-package build-recipe))
  (straight-add-package-to-load-path build-recipe)
  (straight-install-package-autoloads build-recipe))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Closing remarks

(provide 'straight)

;;; straight.el ends here
