;;; emacs-erl.el --- Erlang toolkit  -*- lexical-binding: t -*-

(require 'bindat)

(defmacro erl--read-uint (n string offset)
  "Read N-byte network-endian unsigned integer from STRING at OFFSET."
  (macroexp-let2* symbolp ((s string) (j offset))
    (cl-loop
     for i below n collect
     (let ((x `(aref ,string ,(cl-case i
                                (0 j)
                                (1 `(1+ ,j))
                                (t `(+ ,j ,i))))))
       (if (< i (1- n)) `(ash ,x ,(* 8 (- n i 1))) x))
     into xs finally return `(logior ,@xs))))

(defmacro erl--write-uint (n integer)
  (macroexp-let2 symbolp x integer
    (cl-loop
     for i below n with xs do
     (push `(logand ,(if (= i 0) x `(ash ,x ,(* -8 i))) #xff) xs)
     finally return `(unibyte-string ,@xs))))

;;; Erlang Port Mapper Daemon (EPMD) interaction

(defun epmd-port-please (name cb)
  "Get the distribution port of the node NAME."
  (let* ((epmd-port 4369)
         (port2-resp-bindat-spec
          (bindat-type
            (tag u8 :pack-val 119)
            (result u8)
            (data
             . (if (/= result 0) (unit nil)
                 (struct
                  (portno uint 16)
                  (node-type u8)
                  (protocol u8)
                  (highest-version uint 16) (lowest-version uint 16)
                  (nlen uint 16) (node-name str nlen)
                  (elen uint 16) (extra vec elen u8))))))
         (proc
          (make-network-process
           :name "epmd-port-req" :host 'local :service epmd-port
           :coding 'raw-text :filter-multibyte nil :filter
           (lambda (proc string)
             (set-process-sentinel proc nil)
             (delete-process proc)
             (let* ((alist (bindat-unpack port2-resp-bindat-spec string))
                    (result (cdr (assq 'result alist))))
               (funcall cb (if (/= result 0) (cons 'error result)
                             (bindat-get-field alist 'data 'portno)))))
           :sentinel (lambda (proc event) (funcall cb (cons 'error event))))))
    (let ((s (concat (erl--write-uint 2 (1+ (string-bytes name)))
                     [122] ; PORT_PLEASE2_REQ
                     name)))
    (process-send-string proc s))
    proc))

(defun epmd-port-please-sync (name)
  (let* (result
         (proc (epmd-port-please name (lambda (x) (setq result x)))))
    (while (accept-process-output proc))
    result))

(epmd-port-please-sync "arnie")

;;; Erlang External Term Format

;; Unless messages are passed between connected nodes and a
;; distribution header is used the first byte should contain the
;; version number (131).
(defconst erl-ext-version 131)

(defconst erl-tag (make-symbol "erl-tag"))

(defun erl-read ()
  (when (eq (char-after) 80) ; Compressed term
    (delete-char 5) ; Skip tag and uncompressed size
    (unless (zlib-decompress-region (point) (point-max))
      (error "Failed to decompress term")))
  (cl-labels
      ((read2
        ()
        (forward-char 2)
        (logior (ash (char-before (1- (point))) 8) (char-before)))
       (read4
        ()
        (forward-char 4)
        (let ((pos (point)))
          (logior (ash (char-before (- pos 3)) 24) (ash (char-before (- pos 2)) 16)
                  (ash (char-before (1- pos)) 8) (char-before)))))
    (forward-char)
    (pcase (char-before)
      (97 ; SMALL_INTEGER_EXT
       (forward-char 1)
       (char-before))
      (98 ; INTEGER_EXT
       (let ((u (read4)))
         (- (logand u #x7fffffff) (logand u #x80000000))))

      (88 ; NEW_PID_EXT
       (let* ((node (erl-read))
              (id (read4))
              (serial (read4))
              (creation (read4)))
         (vector erl-tag 'pid node id serial creation)))

      ((or (and 104 (let n (progn (forward-char) (char-before)))) ; SMALL_TUPLE_EXT
           (and 105 (let n (read4)))) ; LARGE_TUPLE_EXT
       (cl-loop repeat n collect (erl-read) into xs
                finally return (apply #'vector xs)))

      (106) ; NIL_EXT
      (107 ; STRING_EXT
       (cl-loop repeat (read2) collect (progn (forward-char) (char-before))))
      (108 ; LIST_EXT
       (cl-loop repeat (read4) collect (erl-read) into xs
                finally (setcdr (last xs) (erl-read))))
      (109 ; BINARY_EXT
       (let ((n (read4)))
         (forward-char n)
         (buffer-substring-no-properties (- (point) n) (point))))
      ((or (and 110 (let n (progn (forward-char) (char-before)))) ; SMALL_BIG_EXT
           (and 111 (let n (read4)))) ; LARGE_BIG_EXT
       (cl-loop with sign = (progn (forward-char) (char-before))
                with x = 0 for i below n do
                (setq x (logior x (ash (char-after) (* 8 i))))
                (forward-char)
                finally return (* (if (= sign 0) 1 -1) x)))

      ((or (and 118 (let n (read2))) ; ATOM_UTF8_EXT
           (and 119 (let n (progn (forward-char) (char-before))))) ; SMALL_ATOM_UTF8_EXT
       (forward-char n)
       (intern (decode-coding-region (- (point) n) (point) 'utf-8 t)))
      ((or (and 100 (let n (read2))) ; ATOM_EXT
           (and 115 (let n (progn (forward-char) (char-before))))) ; SMALL_ATOM_EXT
       (forward-char n)
       (intern (decode-coding-region (- (point) n) (point) 'latin-1 t)))
      (tag (error "Unknown tag `%s'" tag)))))

(defun erl-write (term)
  (cl-labels
      ((write4
        (i)
        (insert (logand (ash i -24) #xff) (logand (ash i -16) #xff)
                (logand (ash i -8) #xff) (logand i #xff))))
    (pcase term
      ((and (pred integerp) i)
       (cond
        ((<= 0 i #xff) (insert 97 i)) ; SMALL_INTEGER_EXT
        ((<= (- #x80000000) i #x7fffffff)
         (insert 98) ; INTEGER_EXT
         (write4 i))
        (t (error "TODO Write bignum"))))
      (`[,(pred (eq erl-tag)) pid ,node ,id ,serial ,creation]
       (insert 88) ; NEW_PID_EXT
       (erl-write node)
       (write4 id)
       (write4 serial)
       (write4 creation))
      ((pred vectorp)
       (if (<= (length term) #xff) (insert 104 (length term)) ; SMALL_TUPLE_EXT
         (insert 105) ; LARGE_TUPLE_EXT
         (write4 (length term)))
       (cl-loop for x across term do (erl-write x)))
      ('nil (insert 106)) ; NIL_EXT
      ((pred consp)
       (let ((sp (point)) n)
         (while (progn
                  (erl-write (pop term))
                  (setq n (1+ n))
                  (consp term)))
         (erl-write term)
         (save-excursion (goto-char sp) (write4 n))))
      ((pred symbolp)
       (let ((n (encode-coding-string
                 (symbol-name term) 'utf-8 t (current-buffer))))
         (if (<= n #xff) (insert 119 n) ; SMALL_ATOM_UTF8_EXT
           (insert 118) ; ATOM_UTF8_EXT
           (write4 n))
         (forward-char n)))

      (_ (error "Cannot encode the term `%S'" term)))))

(defun erl-binary-to-term (&rest args)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (apply #'insert args)
    (goto-char (point-min))
    (unless (eq (char-after) erl-ext-version) (error "Bad version"))
    (forward-char)
    (erl-read)))

(defun erl-term-to-binary (term)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert erl-ext-version)
    (erl-write term)
    (buffer-substring-no-properties (point-min) (point-max))))

;;; Erlang-ish process library

(cl-defstruct (erl-process (:type vector) (:constructor nil)
                           (:copier nil) (:predicate nil))
  (id (:read-only t)) (cond-var (:read-only t)) mailbox)

(defvar erl--processes (make-hash-table :test 'eql)
  "Map of PID:s to processes.")
(defvar erl--next-pid 0)

;; Process-local variables
(defvar erl--self "The current process.")
(defvar erl--mailbox "The private mailbox of the current process.")

(defmacro erl-spawn (&rest body)
  `(let* ((id (cl-incf erl--next-pid))
          (mutex (make-mutex))
          (cond-var (make-condition-variable mutex))
          (process (vector id cond-var ()))
          (fun (lambda ()
                 (let ((erl--self process) erl--mailbox)
                   (unwind-protect (progn ,@body)
                     (remhash (erl-process-id erl--self) erl--processes)))))
          (thread (make-thread fun)))
     (puthash id process erl--processes)))

;; TODO Selective receive
(defmacro erl-receive (&rest arms)
  `(pcase
       (progn
         (unless erl--mailbox
           (with-mutex (condition-mutex (erl-process-cond-var erl--self))
             (while (null (erl-process-mailbox erl--self))
               (condition-wait (erl-process-cond-var erl--self)))
             (setf erl--mailbox (nreverse (erl-process-mailbox erl--self))
                   (erl-process-mailbox erl--self) ())))
         (pop erl--mailbox))
     ,@arms))

(defun erl-send (pid expr)
  (when-let (process (gethash pid erl--processes))
    (with-mutex (condition-mutex (erl-process-cond-var process))
      (push expr (erl-process-mailbox process))
      (condition-notify (erl-process-cond-var process)))))

(erl-spawn
 (erl-receive
  (x (message "Received %S!" x)))
 (message "After!"))

(cl-loop for process being the hash-values of erl--processes do
         (erl-send (erl-process-id process) 1337))

;;; Erlang Distribution Protocol

(defconst erl-recv-challenge-bindat-spec
  (bindat-type
    (length uint 16)
    (tag u8 :pack-val ?N)
    (flags uint 64)
    (challenge uint 32)
    (creation uint 32)
    (nlen uint 16)
    (name str nlen)))

(defun erl--gen-digest (challenge cookie)
  "Generate a message digest (the \"gen_digest()\" function)."
  (secure-hash 'md5 (concat cookie (number-to-string challenge)) nil nil t))

(cl-defun erl-conn (port cookie)
  (cl-labels
      ((get-msg
        (proc string)
        (let* ((saved-s (process-get proc 'buf))
               (s (if (string= saved-s "") string (concat saved-s string)))
               (s-len (string-bytes s)) length)
          (if (or (< s-len 2) (> (setq len (+ 2 (erl--read-uint 2 s 0))) s-len))
              (progn (process-put proc 'buf s) nil)
            (process-put proc 'buf (substring s len))
            (substring s 2 len))))
       (recv-status
        (proc string)
        (when-let (s (get-msg proc string))
          (unless (eq (aref s 0) ?s) (error "Bad status"))
          (funcall
           (cond
            ((eq (compare-strings s 1 7 "named:" nil nil) t)
             (let* ((nlen (erl--read-uint 2 s 7))
                    (name (substring s 9 (+ 9 nlen)))
                    (creation (erl--read-uint 4 s (+ 9 nlen))))
               (message "Name: %s, creation: %s" name creation)
               (process-put proc 'name (intern name))
               (process-put proc 'creation creation)
               (set-process-filter proc #'recv-challenge)))
            ;; TODO alive and case 3B)
            (t (error "Unknown status: %S" s)))
           ;; proc "")))
           proc (prog1 (process-get proc 'buf) (process-put proc 'buf "")))))
       (recv-challenge
        (proc string)
        (let* ((alist (bindat-unpack erl-recv-challenge-bindat-spec string))
               (creation-b (cdr (assq 'creation alist)))
               (name-b (cdr (assq 'name alist)))
               (challenge-b (cdr (assq 'challenge alist)))
               (challenge-a (random (ash 1 32))) ; #x100000000
               (digest (erl--gen-digest challenge-b cookie)))
          (process-put proc 'name-b (intern name-b))
          (process-put proc 'creation-b creation-b)
          (process-send-string
           proc (concat [0 21 ; Length
                           ?r] ; send_challenge_reply tag
                        (erl--write-uint 4 challenge-a)
                        digest))
          (set-process-filter proc #'recv-challenge-ack)))
       (recv-challenge-ack
        (proc string)
        (unless (eq (aref string 2) ?a) (error "Bad tag"))
        (let ((digest (substring string 3 (+ 3 16))))
          (message "Got challenge ACK: digest %S!" digest)
          (set-process-filter proc #'connected-filter)))
       (connected-filter
        (proc string)
        (let* ((saved-s (process-get proc 'buf))
               (s (if (string= saved-s "") string (concat saved-s string)))
               (s-len (string-bytes s)) length)
          (if (or (< s-len 4) (> (setq length (+ 4 (erl--read-uint 4 s 0))) s-len))
              (process-put proc 'buf s)
            (setq string (substring s 4 length))
            (if (string= string "")
                (process-send-string proc "\0\0\0\0") ; Zero length heartbeat
              (message "Received: %S" string)
              (cl-assert (eq (aref string 0) 112)) ; Check that type is pass through
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert string)
                (goto-char (1+ (point-min)))
                (let ((control-msg
                       (progn (cl-assert (eq (char-after) erl-ext-version))
                              (forward-char)
                              (erl-read)))
                      (msg (progn (cl-assert (eq (char-after) erl-ext-version))
                                  (forward-char)
                                  (erl-read))))
                  (message "Parsed: %S" (cons control-msg msg))

                  (pcase control-msg
                    ;; SEND_SENDER
                    (`[22 ,_from-pid [,_ pid ,_name ,to-pid ,_serial ,_creation]]
                     (erl-send to-pid msg))))))

            (process-put proc 'buf "")
            (connected-filter proc (substring s length))))))
    (let ((proc (make-network-process
                 :name "erl-emacs" :host 'local :service port
                 :coding 'raw-text :filter-multibyte nil :filter #'recv-status
                 :sentinel (lambda (proc string) (message "Sentinel: %S" string))
                 :plist (list 'buf "")))
          (flags
           (eval-when-compile
             (erl--write-uint
              8 (logior
                 #x4 ; DFLAG_EXTENDED_REFERENCES
                 #x10 ; DFLAG_FUN_TAGS
                 #x80 ; DFLAG_NEW_FUN_TAGS
                 #x100 ; DFLAG_EXTENDED_PID_PORTS
                 #x200 ; DFLAG_EXPORT_PTR_TAG
                 #x400 ; DFLAG_BIT_BINARIES
                 #x800 ; DFLAG_NEW_FLOATS
                 #x10000 ; DFLAG_UTF8_ATOMS
                 #x20000 ; DFLAG_MAP_TAG
                 #x40000 ; DFLAG_BIG_CREATION
                 #x80000 ; DFLAG_SEND_SENDER
                 #x1000000 ; DFLAG_HANDSHAKE_23
                 #x2000000 ; DFLAG_UNLINK_ID
                 (ash 1 33) ; DFLAG_NAME_ME
                 (ash 1 34))))) ; DFLAG_V4_NC
          (name (system-name)))
      ;; Send send_name message
      (process-send-string
       proc (concat (erl--write-uint 2 (+ 15 (string-bytes name))) ; Length
                    [?N] ; send_name tag
                    flags
                    [0 0 0 0] ; Creation
                    (erl--write-uint 2 (string-bytes name)) ; Nlen
                    name))
      proc)))

(setq erl-conn (erl-conn 42761 "IYQBVJUETYMWBBGPADPN"))
(delete-process erl-conn)

(defun erl-self (conn)
  "Return an Erlang PID object for this process on the node connection CONN."
  (let ((name (process-get conn 'name))
        (id (erl-process-id erl--self))
        (serial 0)
        (creation (process-get conn 'creation)))
    `[,erl-tag pid ,name ,id ,serial ,creation]))

(defun erl-rpc (conn module function &rest args)
  (let* ((name-b (process-get conn 'name-b))
         (pid (erl-self conn))
         (control-msg (erl-term-to-binary `[6 ,pid nil rex])) ; REG_SEND
         (msg (erl-term-to-binary
               ;; {Who, {call, M, F, A, GroupLeader}}
               `[,pid [call ,module ,function ,args ,pid]])))
    (process-send-string
     conn
     (concat
      (erl--write-uint 4 (+ 1 (string-bytes control-msg) (string-bytes msg)))
      [112] ; Pass through
      control-msg
      msg)))
  (erl-receive (`[rex ,x] x)))

(erl-spawn
 (message "Result of RPC: %S" (erl-rpc erl-conn 'erlang 'node)))

(require 'ert)

(ert-deftest erl-gen-digest-test ()
  (should (equal (erl--gen-digest #xb0babeef "kaka")
                 "\327k1\f\326ck'\344\263m\C-F\305P\C-KP")))

(ert-deftest erl-read-test ()
  (should (eq (erl-binary-to-term 131 97 #xff) 255))
  (should (eq (erl-binary-to-term 131 98 #xff #xff #xfc #x18) -1000))
  (should (equal (erl-binary-to-term 131 104 3 97 1 97 2 97 3) [1 2 3]))
  (should (eq (erl-binary-to-term 131 106) ()))

  (should (eq (erl-binary-to-term 131 98 255 255 255 255) -1)))

(ert-deftest erl-write-test ()
  (should (equal (erl-term-to-binary -1) "\203b\377\377\377\377"))
  (should (equal (erl-term-to-binary (- #x80000000)) "\203b\200\0\0\0"))

  (should
   (equal 
    (erl-term-to-binary [rex "hej"])
"\203h\C-bd\0\C-crexk\0\C-chej"
    ;; (unibyte-string 131 104 2 100 0 3 114 101 120 107 0 3 104 101 106)
    )))

(ert-deftest erl-roundtrip-test ()
  (should (let ((x [rex "hej"]))
            (equal (erl-binary-to-term (erl-term-to-binary x)) x))))
