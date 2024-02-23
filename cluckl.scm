(import srfi-13
	srfi-18
	srfi-69
	miscmacros
        (chicken repl)
	(chicken port)
	(chicken condition)
	(chicken format)
	(chicken file)
	(only (chicken tcp)
	      tcp-listen
	      tcp-connect
	      tcp-close
	      tcp-accept
	      tcp-read-timeout
	      tcp-connect-timeout)
	(only (breadline)
	      readline
	      insert-text
	      history-file
	      read-history!
	      add-history!
	      write-history!)
	(only (pathname-expand) pathname-expand))

(define-syntax with-mutex
  (syntax-rules ()
    ((_ (mutex lock-arguments ...) g g* ...)
     (begin
       (mutex-lock! mutex lock-arguments ...)
       (dynamic-wind void
	   (lambda () g g* ...)
	   (lambda () (mutex-unlock! mutex)))))))

;;

(history-file "~/.chicken-cluckl-history")

(define current-cluckl-port (make-parameter 56249))
(define current-cluckl-host (make-parameter "127.0.0.1"))
(define current-cluckl-backlog (make-parameter 16))
(define current-cluckl-prompt (make-parameter " λ > "))
(define current-cluckl-debug (make-parameter #f))

(define process-error-port (current-error-port))

(define cluckl-threads (make-hash-table))
(define cluckl-threads-mutex (make-mutex))


;;

(define (cluckl-log message)
  (when (current-cluckl-debug)
    (display message process-error-port)
    (newline process-error-port)))

(define (cluckl-debug)
  (current-cluckl-debug (not (current-cluckl-debug))))

(define (cluckl-message-get key message #!optional (default #f))
  (let ((pair (or (assq key message) default)))
    (if (eq? pair default) default
	(cdr pair))))

(define (cluckl-message-get-op message)
  (cluckl-message-get 'op message))

(define (cluckl-message-get-body message)
  (cluckl-message-get 'body message))

(define (cluckl-message-get-result message)
  (cluckl-message-get 'result message))

(define (cluckl-message-get-error message)
  (cluckl-message-get 'error message))

(define (cluckl-message-get-callchain message)
  (cluckl-message-get 'callchain message))

(define (cluckl-message-get-output message)
  (cluckl-message-get 'output message))

(define (cluckl-message-get-stream message)
  (cluckl-message-get 'stream message))

;;

(define (cluckl-write message #!optional (port (current-output-port)))
  (cluckl-log message)
  (write message port))

(define (cluckl-build-eval body)
  `((op . eval) (body . ,body)))

(define (cluckl-write-eval body #!optional (port (current-output-port)))
  (cluckl-write (cluckl-build-eval body) port))

(define (cluckl-build-output stream-id output)
  `((stream . ,stream-id) (output . ,output)))

(define (cluckl-write-output stream-id output #!optional (port (current-output-port)))
  (cluckl-write (cluckl-build-output stream-id output) port))

(define (cluckl-build-result result)
  (let ((out (open-output-string)))
    (##sys#repl-print-hook result out)
    `((result . ,(string-trim-right (get-output-string out))))))

(define (cluckl-write-result result #!optional (port (current-output-port)))
  (cluckl-write (cluckl-build-result result) port))

(define (cluckl-build-error error #!optional (callchain #f))
  `((error . ,error) (callchain . ,callchain)))

(define (cluckl-write-error error #!optional (callchain #f) (port (current-output-port)))
  (cluckl-write (cluckl-build-error error callchain) port))

(define (cluckl-wrap-output-port stream-id #!optional (port (current-output-port)))
  (make-output-port
   (lambda (output) (cluckl-write-output stream-id output port))
   (lambda () (close-output-port port))
   (lambda () (flush-output port))))

;;

(define original-output (current-output-port))
(define (cluckl-protocol-error message)
  (error (format "protocol error: ~a" message)))

(define (cluckl-handle-op-eval message)
  (define body (cluckl-message-get-body message))
  (if body
      (receive (result)
	  (parameterize ((current-output-port (cluckl-wrap-output-port 'stdout (current-output-port)))
			 (current-error-port (cluckl-wrap-output-port 'stderr (current-error-port))))
	    (eval body))
	(cluckl-write-result result))
      (cluckl-protocol-error (format "no 'body provided for eval 'op: ~a" message))))

(define (cluckl-handle-message message)
  (define op (cluckl-message-get-op message))
  (case op
    ((eval) (cluckl-handle-op-eval message))
    ((#f) (cluckl-protocol-error (format "missing required 'op key in message ~a" message)))
    (else (cluckl-protocol-error (format "unsupported 'op ~a" op)))))

(define (cluckl-display-exception exn
				  #!optional
				  (message-port (current-output-port))
				  (call-chain-port (current-output-port)))
  (print-error-message exn message-port)
  ;; TODO: how many levels should we remove to hide repl internals?
  (print-call-chain call-chain-port 0))

(define (cluckl-handle-exception exn)
  (let ((message (open-output-string))
	(call-chain (open-output-string)))
    (cluckl-display-exception exn message call-chain)
    (cluckl-write-error (string-trim (get-output-string message))
			(string-trim (get-output-string call-chain)))))

;;

(define (cluckl-iter)
  (handle-exceptions exn
    (cluckl-handle-exception exn)
    (let* ((message (read)))
      (cond
       ((eof-object? message) message)
       (else (cluckl-handle-message message))))))

(define (cluckl-loop in out)
  (handle-exceptions exn
    (begin
      (print-error-message exn (current-error-port))
      (print-call-chain (current-error-port) 0))
      (parameterize ((current-input-port in)
		     (current-output-port out)
		     (current-error-port out))
	(let loop () (and (not (eof-object? (cluckl-iter)))
			  (loop))))))

(define (cluckl-spawn in out)
  (define (thunk)
    (cluckl-loop in out)
    (with-mutex (cluckl-threads-mutex #f #f)
      (hash-table-delete! cluckl-threads (thread-name (current-thread)))))
  (with-mutex (cluckl-threads-mutex #f #f)
    (let ((job (thread-start! thunk)))
      (begin0 job
	(hash-table-set! cluckl-threads (thread-name job) job)))))

(define (cluckl-on socket)
  (let loop ()
    (let-values (((in out) (tcp-accept socket)))
      (cluckl-spawn in out))
    (loop)))

(define (cluckl-serve #!key
		      (port (current-cluckl-port))
		      (host (current-cluckl-host))
		      (backlog (current-cluckl-backlog))
		      (read-timeout #f))
  (parameterize ((tcp-read-timeout read-timeout))
    (define socket (tcp-listen port backlog host))
    (cluckl-on socket)))

(define (cluckl-connect #!key
			(port (current-cluckl-port))
			(host (current-cluckl-host)))
  (define no-value (gensym))
  (define history (pathname-expand (history-file)))
  (when (file-exists? history)
    (read-history! history))
  (define waiting (make-mutex))
  (define (prompt port)
    (mutex-lock! waiting #f #f)
    (let ((body (readline (current-cluckl-prompt))))
      (begin0 body
	(cond
	 ((or (eq? body #f)
	      (eof-object? body)
	      (equal? body ""))
	  (mutex-unlock! waiting))
	 (else
	  (add-history! body)
	  (write-history! history)
	  (let ((expr (handle-exceptions exn
			(begin0 no-value
			  (cluckl-display-exception exn)
			  (mutex-unlock! waiting))
			(read (open-input-string body)))))
	    (unless (eq? expr no-value)
	      (cluckl-write-eval expr port)
	      (flush-output port))))))))
  (define (show value)
    (display value)
    (newline)
    (flush-output))
  (receive (in out) (tcp-connect host port)
    (thread-start!
     (lambda ()
       (let loop ()
	 (define message (read in))
	 (unless (eof-object? message)
	   (let ((result (cluckl-message-get-result message))
		 (error (cluckl-message-get-error message))
		 (output (cluckl-message-get-output message)))
	     (cond
	      (result (show result))
	      (error (show error) (show (cluckl-message-get-callchain message)))
	      (output (show output)))
	     (when (or result error)
	       (mutex-unlock! waiting)))
	   (loop)))))
    (let loop ()
      (and (prompt out)
	   (loop)))
    (write-history! history)))
