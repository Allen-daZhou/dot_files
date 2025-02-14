;;; copilot.el --- An unofficial Copilot plugin for Emacs  -*- lexical-binding:t -*-

;; Package-Requires: ((emacs "27.2") (s "1.12.0") (dash "2.19.1") (editorconfig "0.8.2"))

;;; Code:
(require 'cl-lib)
(require 'json)
(require 's)
(require 'dash)
(require 'editorconfig)

(defgroup copilot nil
  "Copilot."
  :group 'completion
  :prefix "copilot-")

(defcustom copilot-idle-delay 0
  "Time in seconds to wait before starting completion. Complete immediately if set to 0."
  :type 'float
  :group 'copilot)

(defcustom copilot-log-max message-log-max
  "Maximum number of lines to keep in the *copilot-log* buffer."
  :group 'copilot
  :type 'integer)

(defconst copilot--log-name "*copilot-log*"
  "Name of the copilot log buffer.")

(defconst copilot--base-dir
  (file-name-directory
   (or load-file-name
       (buffer-file-name)))
  "Directory containing this file.")

(defvar copilot--process nil
  "Copilot agent process object.")

(defvar copilot--request-id 0
  "Request Id to distinguish requests.")

(defvar copilot--callbacks nil
  "An alist in the form of (request-id . callback).")

(defvar copilot--output-buffer nil
  "Buffer for process outputs.")

(defvar copilot--request-timer nil
  "Timer for sending delayed requests.")

;;
;; log
;;


(defun copilot--log (format &rest args)
  "Log a (format FORMAT ARGS) message to the copilot log buffer."
  (when copilot-log-max
    (let ((log-buffer (get-buffer copilot--log-name))
          (inhibit-read-only t))
      (unless log-buffer
        (setq log-buffer (get-buffer-create copilot--log-name))
        (with-current-buffer log-buffer
          (view-mode 1)))
      (with-current-buffer log-buffer
        (save-excursion
          (let ((msg (apply 'format format args)))
            (goto-char (point-max))
            (insert "\n")
            (insert msg))
          (let ((lines (count-lines (point-min) (point-max))))
            (when (and (integerp copilot-log-max)
                       (> lines copilot-log-max))
              (goto-char (point-min))
              (forward-line (- lines copilot-log-max))
              (delete-region (point-min) (point)))))))))

;;
;; agent
;;

(defconst copilot--node
  (if (eq system-type 'windows-nt)
      "node.exe"
    "node")
  "Node executable name.")

(defun copilot--start-process ()
  "Start the copilot agent process."
  (if (not (locate-file copilot--node exec-path))
      (message "Could not find node executable")
    (let ((node-version (->> (shell-command-to-string (concat copilot--node " --version"))
                             (s-trim)
                             (s-chop-prefix "v")
                             (string-to-number))))
      (if (< node-version 12)
          (message "Node 12+ required but found %s" node-version)
        (setq copilot--process
              (make-process :name "copilot-agent"
                            :command (list copilot--node
                                           (concat copilot--base-dir "/dist/agent.js"))
                            :coding 'utf-8
                            :connection-type 'pipe
                            :filter 'copilot--process-filter
                            :sentinel 'copilot--process-sentinel
                            :noquery t))
        (message "Copilot agent started.")))))


(defun copilot--kill-process ()
  "Kill Copilot agent process."
  (when copilot--process
    (delete-process copilot--process)
    (setq copilot--process nil)))

(defun copilot--process-sentinel (_ event)
  "Process sentinel for the copilot agent process. Simply logs the EVENT."
  (copilot--log "[PROCESS] %s" event))

(defun copilot--send-request (request)
  "Send REQUEST to Copilot agent."
  (unless copilot--process
    (copilot--start-process))
  (when copilot--process
    (when copilot--request-timer
      (cancel-timer copilot--request-timer)
      (setq copilot--request-timer nil))
    (let* ((body (json-serialize request))
           (content (concat "Content-Length: "
                            (int-to-string (string-bytes body))
                            "\r\n\r\n"
                            body)))
      (if (> copilot-idle-delay 0)
          (setq copilot--request-timer
                (run-with-timer copilot-idle-delay nil
                                (lambda () (process-send-string copilot--process content))))
        (process-send-string copilot--process content)))))

(defun copilot--agent-request (method params)
  "Send a request with METHOD and PARAMS to the copilot agent."
  (lambda (callback)
   (cl-incf copilot--request-id)
   (let ((request (list :method method
                        :params params
                        :id copilot--request-id)))

      (push (cons copilot--request-id
                  callback)
            copilot--callbacks)
      (copilot--send-request request))))


(defun copilot--let-fold-left (fn forms bindings)
  "Fold left over the forms in FORMS using FN with the bindings in BINDINGS."
  (let ((res forms))
    (dolist (binding bindings)
      (setq res (funcall fn res binding)))
    res))

(defmacro copilot--let-req (bindings &rest forms)
  "Bind async functions with callbacks in BINDINGS and evaluate FORMS."
  (declare (indent 1))
  (copilot--let-fold-left (lambda (res binding)
                            `(funcall ,(cadr binding)
                                      (lambda (,(car binding))
                                        ,res)))
                                  `(progn ,@forms)
                                  (reverse bindings)))

(defmacro copilot--let-req-async (bindings &rest forms)
  "Bind async functions with callbacks in BINDINGS and evaluate FORMS. Return a promise."
  (declare (indent 1))
  `(lambda (callback)
     (copilot--let-req ,bindings (funcall callback (progn ,@forms)))))

(defun copilot--agent-http-request (url params)
  "Send an http request to URL with PARAMS via Copilot agent."
  (copilot--let-req-async
      ((result
        (copilot--agent-request "httpRequest"
                                (append params
                                        (list :url url
                                              :timeout 30000)))))
    (let ((status (alist-get 'status result))
          (body (alist-get 'body result)))
      (unless (equal status 200)
        (copilot--log "[ERROR] HTTP request failed with status %s\n[ERROR] HTTP Response: %S\n" status result))
      (when body
        (->> body
            json-read-from-string
            (cons (cons 'status status)))))))

(defmacro copilot--substring-raw (string &rest args)
  "Return (substring STRING ARGS) in `raw-text' coding system."
  `(-> ,string
       (encode-coding-string 'raw-text)
       (substring ,@args)
       (decode-coding-string 'utf-8)))

(defun copilot--process-filter (process output)
  "Process OUTPUT of Copilot agent PROCESS."
  (setq copilot--output-buffer (concat copilot--output-buffer output))
  (let ((header-match (s-match "^Content-Length: \\([0-9]+\\)\r?\n\r?\n" copilot--output-buffer)))
    (if (and (not header-match) (> (length copilot--output-buffer) 50))
        (progn
          (copilot--log "[Warning] Copilot agent output buffer reset.")
          (copilot--log "[Warning] Before reset:%S\n" copilot--output-buffer)
          (setq copilot--output-buffer nil))
      (when header-match
        (let* ((header (car header-match))
              (content-length (string-to-number (cadr header-match)))
              (full-length (+ (length header) content-length)))
          (when (>= (length copilot--output-buffer) full-length)
            (let ((content (copilot--substring-raw copilot--output-buffer (length header) full-length)))
              (setq copilot--output-buffer (copilot--substring-raw copilot--output-buffer full-length))
              (copilot--process-response content)
              ; rerun filter to process remaining output
              (copilot--process-filter process nil))))))))

(defun copilot--process-response (content)
  "Process a response message with CONTENT."
  (let* ((content (json-read-from-string content))
         (result (alist-get 'result content))
         (err (alist-get 'error content))
         (id (alist-get 'id content)))
    (when err
      (copilot--log "[ERROR] Error in response: %S\n[ERROR] Response:%S\n" err content))
    (if (not id)
        (copilot--log "[INFO] Discard message without id: %S" content)
      (funcall (alist-get id copilot--callbacks)
               (cons (cons 'error err) result))
      (assq-delete-all id copilot--callbacks))))

;;
;; login
;;

(defconst copilot--client-id "Iv1.b507a08c87ecfe98"
  "Copilot client id, copied from copilot.vim.")

(defconst copilot--terms-version "2021-10-14"
  "Copilot terms version, copied from copilot.vim.")

(defconst copilot--config-root
  (let ((root (concat (or (getenv "XDG_CONFIG_HOME")
                          (if (eq system-type 'windows-nt)
                              ; should be %APPDATALOCAL% (~ expands to %APPDATA% in Windows)
                              (expand-file-name "~/../Local")
                            (expand-file-name "~/.config")))
                      "/github-copilot")))
    (make-directory root t)
    root)
  "Copilot config root.")

(defconst copilot--config-hosts
  (concat copilot--config-root "/hosts.json"))

(defconst copilot--config-terms
  (concat copilot--config-root "/terms.json"))

(defun copilot-login ()
  "Login to Copilot."
  (interactive)
  (funcall (copilot--agent-http-request "https://github.com/login/device/code"
                                        `(:method "POST"
                                                  :headers (:Accept "application/json"):json
                                                  (:client_id ,copilot--client-id :scope "user:read")))
           'copilot--login-callback))

(defun copilot--login-callback (result)
  "Callback for login request. RESULT is the response."
  (let* ((device-code (alist-get 'device_code result))
         (verification-uri (alist-get 'verification_uri result))
         (user-code (alist-get 'user_code result)))
    (if (display-graphic-p)
        (progn
          (gui-set-selection 'CLIPBOARD user-code)
          (read-from-minibuffer (format "Your one-time code %s is copied. Press ENTER to open GitHub in your browser." user-code))
          (browse-url verification-uri)
          (read-from-minibuffer "Press ENTER if you finish authorizing."))
      (read-from-minibuffer (format "First copy your one-time code: %s. Press ENTER to continue." user-code))
      (read-from-minibuffer (format "Please open %s in your browser. Press ENTER if you finish authorizing." verification-uri)))
    (message "Verifying...")
    (copilot--login-verify device-code)))


(defun copilot--login-verify (device-code)
  "Verify login with DEVICE-CODE."
  (funcall (copilot--agent-http-request (format "https://github.com/login/oauth/access_token?grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=%s&client_id=%s"
                                                device-code copilot--client-id)
                                        '(:method "GET"
                                                  :headers (:Accept "application/json")))
           'copilot--login-verify-callback))

(defun copilot--login-verify-callback (result)
  "Callback for login verification request. RESULT is the response."
  (let ((access-token (alist-get 'access_token result)))
    (if (not access-token)
        (message "Login failed. Server responds with %S." result)
      (copilot--let-req
          ((copilot-access-result (copilot--agent-http-request
                                   "https://api.github.com/copilot_internal/token"
                                   `(:method "GET"
                                             :headers (:Authorization ,(concat "Bearer " access-token))))))
        (let ((status (alist-get 'status copilot-access-result)))
          (if (equal status 403)
              (message "You don't have access to GitHub Copilot. Join the waitlist by visiting https://copilot.github.com")
            (when (yes-or-no-p "I agree to these telemetry terms as part of the GitHub Copilot technical preview.\nhttps://github.co/copilot-telemetry-terms")
              (copilot--let-req ((user (copilot--oauth-user access-token)))
                (when user
                  (with-temp-file copilot--config-hosts
                    (insert (json-encode `(:github.com (:user ,user :oauth_token ,access-token)))))
                  (with-temp-file copilot--config-terms
                    (insert (json-encode `((,user . (("version" . ,copilot--terms-version)))))))
                  (message "Copilot: Authenticated as GitHub user %s" user))))))))))


(defun copilot--oauth-user (access-token)
  "Get user name by ACCESS-TOKEN."
  (copilot--let-req-async
      ((result (copilot--agent-http-request "https://api.github.com/user"
                                            `(:method "GET"
                                                      :headers (:Authorization ,(concat "Bearer " access-token))))))
    (if (equal (alist-get 'status result) 200)
        (alist-get 'login result)
      (message "Failed to get user info.")
      nil)))


;;
;; diagnose
;;

(defun copilot--diagnose-network ()
  "Diagnose network."
  (copilot--let-req-async ((result (copilot--agent-http-request "https://copilot-proxy.githubusercontent.com/_ping"
                                                                '(:timeout 5000 :method "GET"))))
    (cond
     ((not result) "Server connectivity error")
     ((equal (alist-get 'status result) 466) "Server error")
     (t nil))))

(defun copilot--diagnose-access ()
  "Diagnose Copilot access with a dummy completion request."
  (copilot--let-req-async ((result (copilot--agent-request "getCompletions"
                                                           '(:doc (:source ""
                                                                   :path ""
                                                                   :relativePath ""
                                                                   :languageId ""
                                                                   :position (:line 0 :character 0))))))

    (let ((err (alist-get 'error result)))
      (if err
          (format "error: %S" err)
        "OK"))))

(defun copilot-diagnose ()
  "Restart and diagnose copilot."
  (interactive)
  (when copilot--process
    (copilot--kill-process))
  (copilot--start-process)
  (if (not copilot--process)
      (message "Copilot agent is not running.")
    (copilot--let-req ((network (copilot--diagnose-network)))
      (if network
          (message "Network: %s" network)
        (copilot--let-req ((access (copilot--diagnose-access)))
          (message "Copilot: %s" access))))))

;;
;; Auto completion
;;

(defconst copilot--indentation-alist
  (append '((latex-mode tex-indent-basic)
            (nxml-mode nxml-child-indent)
            (python-mode python-indent py-indent-offset python-indent-offset)
            (web-mode web-mode-markup-indent-offset web-mode-html-offset))
          editorconfig-indentation-alist)
  "Alist of `major-mode' to indentation map with optional fallbacks.")

(defvar-local copilot--completion-cache nil)
(defvar-local copilot--completion-idx 0)

(defun copilot--infer-indentation-offset ()
  "Infer indentation offset."
  (or (let ((mode major-mode))
        (while (and (not (assq mode copilot--indentation-alist))
                    (setq mode (get mode 'derived-mode-parent))))
        (when mode
          (cl-some (lambda (s)
                     (when (boundp s)
                       (symbol-value s)))
                   (alist-get mode copilot--indentation-alist))))
      tab-width))

(defun copilot--generate-doc ()
  "Generate doc param for completion request."
  (list :source (concat (buffer-substring-no-properties (point-min) (point-max)) "\n")
        :tabSize (copilot--infer-indentation-offset)
        :indentSize (copilot--infer-indentation-offset)
        :insertSpaces (if indent-tabs-mode :false t)
        :path (buffer-file-name)
        :relativePath (file-name-nondirectory (buffer-file-name))
        :languageId (s-chop-suffix "-mode" (symbol-name major-mode))
        :position (list :line (1- (line-number-at-pos))
                        :character (length (buffer-substring-no-properties (point-at-bol) (point))))))

(defun copilot--get-completion (callback)
  "Get completion with CALLBACK."
  (funcall (copilot--agent-request "getCompletions"
                                   (list :doc (copilot--generate-doc)))
           callback))

(defun copilot--get-completions-cycling (callback)
  "Get completion cycling options with CALLBACK."
  (if copilot--completion-cache
      (funcall callback copilot--completion-cache)
    (funcall (copilot--agent-request "getCompletionsCycling"
                                     (list :doc (copilot--generate-doc)))
             callback)))

(defun copilot--cycle-completion (direction)
  "Cycle completion with DIRECTION."
  (lambda (result)
    (unless copilot--completion-cache
      (setq copilot--completion-cache result))
    (let ((completions (cl-remove-duplicates (alist-get 'completions result)
                                             :key (lambda (x) (alist-get 'text x))
                                             :test 'equal)))
      (cond ((seq-empty-p completions)
             (message "No completion is available."))
            ((= (length completions) 1)
             (message "Only one completion is available."))
            (t (let ((idx (mod (+ copilot--completion-idx direction)
                               (length completions))))
                 (setq copilot--completion-idx idx)
                 (let ((completion (elt completions idx)))
                   (copilot--show-completion completion))))))))

(defun copilot-next-completion ()
  "Cycle to next completion."
  (interactive)
  (when copilot--overlay
    (copilot--get-completions-cycling (copilot--cycle-completion 1))))

(defun copilot-previous-completion ()
  "Cycle to previous completion."
  (interactive)
  (when copilot--overlay
    (copilot--get-completions-cycling (copilot--cycle-completion -1))))


;;
;; UI
;;


(defface copilot-overlay-face
  '((t :inherit shadow))
  "Face for Copilot overlay")

(defvar-local copilot--overlay nil
  "Overlay for Copilot completion.")

(defun copilot-display-overlay-completion (completion line col user-pos)
  "Show COMPLETION in overlay at LINE and COL. For Copilot, COL is always 0.
USER-POS is the cursor position (for verification only)."
  (copilot-clear-overlay)
  (save-excursion
    (widen)
    (goto-char (point-min))
    (if (= (line-end-position line) (1- (point-max)))
        ; special case if the last line is empty
        (progn
          (goto-char (point-max))
          (newline)
          (forward-char -1))
      (forward-line line)
      (forward-char col))

    ; remove common prefix
    (let* ((cur-line (s-chop-suffix "\n" (thing-at-point 'line)))
            (common-prefix-len (length (s-shared-start completion cur-line))))
      (setq completion (substring completion common-prefix-len))
      (forward-char common-prefix-len))

    (when (and (s-present-p completion)
               (or (= (point) user-pos) ; up-to-date completion
                   (and (< (point) user-pos) ; special case for removing indentation
                        (s-blank-p (s-trim (buffer-substring-no-properties (point) user-pos))))))
      (let* ((ov (make-overlay (point) (point-at-eol) nil t t))
             (p-completion (propertize completion 'face 'copilot-overlay-face))
             (display (substring p-completion 0 1))
             (after-string (substring p-completion 1)))
        (overlay-put ov 'completion completion)
        (overlay-put ov 'start (point))
        (if (equal (overlay-start ov) (overlay-end ov))
            (progn
              (put-text-property 0 1 'cursor t p-completion)
              (overlay-put ov 'after-string p-completion))
          (overlay-put ov 'display display)
          (overlay-put ov 'after-string after-string))
        (setq copilot--overlay ov)))))

(defun copilot-clear-overlay ()
  "Clear Copilot overlay."
  (interactive)
  (when copilot--overlay
    (delete-overlay copilot--overlay)
    (setq copilot--overlay nil)))

(defun copilot-accept-completion (&optional transform-fn)
  "Accept completion. Return t if there is a completion. Use TRANSFORM-FN to transform completion if provided."
  (interactive)
  (when copilot--overlay
    (let* ((completion (overlay-get copilot--overlay 'completion))
           (start (overlay-get copilot--overlay 'start))
           (t-completion (funcall (or transform-fn 'identity) completion)))
      (copilot-clear-overlay)
      (delete-region start (line-end-position))
      (insert t-completion)
      ; trigger completion again if not fully accepted
      (unless (equal completion t-completion)
        (copilot-complete))
      t)))

(defun copilot-accept-completion-by-word (n-word)
  "Accept first N-WORD words of completion."
  (interactive "p")
  (setq n-word (or n-word 1))
  (copilot-accept-completion (lambda (completion)
                               (let* ((blank-regexp '(any blank "\r" "\n"))
                                      (separator-regexp (rx-to-string
                                                         `(seq
                                                           (not ,blank-regexp)
                                                           (1+ ,blank-regexp))))
                                      (words (s-split-up-to separator-regexp completion n-word))
                                      (remain (if (<= (length words) n-word)
                                                  ""
                                                (first (last words))))
                                      (length (- (length completion) (length remain)))
                                      (prefix (substring completion 0 length)))
                                 (s-trim-right prefix)))))

(defun copilot-accept-completion-by-line (n-line)
  "Accept first N-LINE lines of completion."
  (interactive "p")
  (setq n-line (or n-line 1))
  (copilot-accept-completion (lambda (completion)
                               (let* ((lines (s-split-up-to (rx anychar (? "\r") "\n") completion n-line))
                                      (remain (if (<= (length lines) n-line)
                                                  ""
                                                (first (last lines))))
                                      (length (- (length completion) (length remain)))
                                      (prefix (substring completion 0 length)))
                                 prefix))))

(defun copilot--show-completion (completion)
  "Show COMPLETION."
  (when completion
    (let* ((text (alist-get 'text completion))
           (range (alist-get 'range completion))
           (start (alist-get 'start range))
           (start-line (alist-get 'line start))
           (start-char (alist-get 'character start)))
      (copilot-display-overlay-completion text start-line start-char (point)))))

(defun copilot-complete ()
  "Complete at the current point."
  (interactive)
  (copilot-clear-overlay)

  (setq copilot--completion-cache nil)
  (setq copilot--completion-idx 0)

  (let ((called-interactively (called-interactively-p 'interactive)))
    ;; (when (buffer-file-name)
    (when t ;; Mod
      (copilot--get-completion
      (lambda (result)
        (copilot--log "[INFO] Completion: %S" result)
        (let* ((completions (alist-get 'completions result))
                (completion (if (seq-empty-p completions) nil (seq-elt completions 0))))
          (when (and (not completion)
                     called-interactively)
            (message "No completion is available."))
          (copilot--show-completion completion)))))))

;;
;; minor mode
;;

(defcustom copilot-disable-predicates nil
  "A list of predicate functions with no argument to disable Copilot. Copilot will be disabled if any predicate returns t."
  :type 'list
  :group 'copilot)

(defcustom copilot-enable-predicates nil
  "A list of predicate functions with no argument to enable Copilot. Copilot will be enabled only if all predicates return t."
  :type 'list
  :group 'copilot)

;;;###autoload
(define-minor-mode copilot-mode
  "Minor mode for Copilot."
  :init-value nil
  :lighter " Copilot"
  (copilot-clear-overlay)
  (add-hook 'post-command-hook 'copilot--complete-post-command))

(defun copilot--complete-post-command ()
  "Complete in post-command hook."
  (when copilot-mode
    (unless (and (symbolp this-command)
                 (s-starts-with-p "copilot-" (symbol-name this-command)))
      (copilot-clear-overlay)
      (when (and (cl-every (lambda (pred)
                             (if (functionp pred) (funcall pred) t))
                          copilot-enable-predicates)
                 (cl-notany (lambda (pred)
                              (if (functionp pred) (funcall pred) f))
                            copilot-disable-predicates))
          (copilot-complete)))))

(provide 'copilot)
;;; copilot.el ends here
