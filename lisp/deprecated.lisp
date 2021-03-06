;;;; -*- mode: lisp -*-
;;;;
;;;; Copyright (c) 2013, Georgia Tech Research Corporation
;;;; All rights reserved.
;;;;
;;;; Author(s): Neil T. Dantam <ntd@gatech.edu>
;;;; Georgia Tech Humanoid Robotics Lab
;;;; Under Direction of Prof. Mike Stilman <mstilman@cc.gatech.edu>
;;;;
;;;;
;;;; This file is provided under the following "BSD-style" License:
;;;;
;;;;
;;;;   Redistribution and use in source and binary forms, with or
;;;;   without modification, are permitted provided that the following
;;;;   conditions are met:
;;;;
;;;;   * Redistributions of source code must retain the above copyright
;;;;     notice, this list of conditions and the following disclaimer.
;;;;
;;;;   * Redistributions in binary form must reproduce the above
;;;;     copyright notice, this list of conditions and the following
;;;;     disclaimer in the documentation and/or other materials provided
;;;;     with the distribution.
;;;;
;;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
;;;;   CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
;;;;   INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
;;;;   MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
;;;;   DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
;;;;   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;;;;   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
;;;;   USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
;;;;   AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
;;;;   LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
;;;;   ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;;;   POSSIBILITY OF SUCH DAMAGE.

;;; Wrapper Generation ;;;

(defun var-sym (alist name thing)
  (cdr (assoc (cons name thing) alist :test #'equal)))



(defun bind-counts (var-alist var type body)
  (let ((data (var-sym var-alist var :data))
        (offset (var-sym var-alist var :offset))
        (stride (var-sym var-alist var :stride))
        (rows (var-sym var-alist var :rows))
        (cols (var-sym var-alist var :cols))
        (inc (var-sym var-alist var :inc))
        (length (var-sym var-alist var :length)))
    (case type
      (:matrix
       `((let ((,rows (matrix-rows ,var))
               (,cols (matrix-cols ,var))
               (,stride (matrix-stride ,var))
               (,offset (matrix-offset ,var))
               (,data (matrix-data ,var)))
           (declare (type fixnum ,offset ,stride ,rows ,cols))
           ;; check overflow
           (unless (matrix-counts-in-bounds-p
                    (length ,data) ,offset ,stride ,rows ,cols)
             (matrix-storage-error "Argument ~A is out of bounds" ',var))
           ,@body)))
      (:vector
       (bind-counts var-alist var :matrix
                    `((let ((,inc (matrix-counts-vector-increment ,rows ,cols ,stride))
                            (,length (* ,rows ,cols)))
                        (declare (type fixnum ,inc ,length))
                        ,@body))))
      (otherwise body))))


(defun make-var-sym (name thing)
  (cons (cons name thing) (prefix-gensym (string thing) name)))

(defun length-check (alist var type params)
  (let ((checks))
    (labels ((new-check (a b)
               (push `(assert (= ,a ,b)) checks))
             (swap-rowcol (a)
               (ecase a (:rows :cols) (:cols :rows)))
             (get-var (param)
               (destructuring-bind (thing var) param
                 (ecase thing
                   (:length (var-sym alist var thing))
                   ((:rows :cols)
                    `(if ,(var-sym alist var :transpose)
                         ,(var-sym alist var (swap-rowcol thing))
                         ,(var-sym alist var thing))))))
             (collect (first rest)
               (loop for param in rest
                  when (and (consp param) (find (first param) '(:length :rows :cols)))
                  collect (if (listp (second param))
                              (new-check (var-sym alist var (first param)) (get-var (second param)))
                              (new-check (get-var first) (get-var param))))))
      (case type
        ((:vector :matrix) (collect nil params))
        (otherwise (collect (car params) (cdr params)))))
    checks))


;; Checks
;;  * Matrix in bounds
;;  * Argument dimensons match
;;  * Argument element types match

(defmacro def-la-wrapper ((c-name lisp-name) result-type &rest args)
  (declare (ignore result-type)) ;; todo: optimize with declarations
  (let ((normal-arglist (loop for (name type . params) in args
                           when (and (not (eq type 'transpose-t))
                                     (or (null params)
                                         (find type '(:vector :matrix))
                                         (equal '(:inout) params)))
                           collect name))
        (inout-args (loop for (name type . params) in args
                         when (find :inout params)
                         collect name))
        (transpose-args (loop for (name type . params) in args
                           when (eq type 'transpose-t)
                           collect `(,name ,type ,@args)))
        (matrix-args (loop for (name type) in args
                        when (or (eq type :vector) (eq type :matrix))
                        collect name))
        (var-alist (loop for (name type . params) in args
                      append (append
                              (when (eq type 'transpose-t)
                                (destructuring-bind ((trans matrix)) params
                                  (assert (eq :transpose trans))
                                  (list (cons (cons matrix :transpose) name))))
                              (when (eq type :vector)
                                (list (make-var-sym name :inc)
                                      (make-var-sym name :length)))
                              (when (or (eq type :matrix) (eq type :vector))
                                (list (make-var-sym name :rows)
                                      (make-var-sym name :offset)
                                      (make-var-sym name :cols)
                                      (make-var-sym name :data)
                                      (make-var-sym name :stride)))))))
    (labels ((var-symbol (name type)
               (cdr (assoc (cons name type) var-alist :test #'equal)))
             (true-arg (name type params)
               (cond
                 ((eq type :vector)
                  (list (var-symbol name :data) (var-symbol name :inc)))
                 ((eq type :matrix)
                  (list (var-symbol name :data) (var-symbol name :stride)))
                 (params
                  (dolist (p params)
                    (when (and (consp p) (find (first p) '(:rows :length :cols)))
                      (return-from true-arg (list (var-symbol (second p) (first p))))))
                  (list name))
                 (t (list name)))))
      `(defun ,lisp-name (,@normal-arglist
                          ,@(when transpose-args
                                  (list '&key (loop for (name) in transpose-args
                                                 collect name))))
         ;; declare types
         ,@(when matrix-args `((declare (type double-matrix ,@matrix-args))))
         ;; bind counts
         ,@(reduce
            (lambda (body arg)
              (destructuring-bind (name type &rest params) arg
                (declare (ignore params))
                (bind-counts var-alist name type body)))
            args
            :initial-value
            ;; check sizes
            `(,@(loop
                   for (name type . params) in args
                   append (length-check var-alist name type params))
                ;; funcall
                (,c-name ,@(loop for (name type . params) in args
                              append (true-arg name type params)))))
         ;;output
         ,@(cond
            ((null inout-args) nil)
            ((= 1 (length inout-args)) inout-args)
            (t (list (cons 'values inout-args))))))))

(defmacro def-la ((c-name lisp-name &key (size-type 'size-t) by-reference)
                  result-type &rest args)
  (let ((c-lisp-name (gensym (string lisp-name))))
    `(progn (def-la-cfun (,c-name ,c-lisp-name
                                  :by-reference ,by-reference
                                  :size-type ,size-type) ,result-type
              ,@args)
            (def-la-wrapper (,c-lisp-name ,lisp-name) ,result-type
              ,@args))))



(defmacro def-blas (name result-type &body args)
  (cons
   'progn
   (loop
      with strname = (string name)
      for prefix in '(d) ;'(s d)
      for strprefix = (string-downcase (string prefix))
      for prefix-type = (ecase prefix
                          (d :double)
                          (s :float))
      for typed-args = (loop for (name type . params) in args
                          collect `(,name ,(case type
                                                 ((:float :double)
                                                  prefix-type)
                                                 (otherwise type))
                                          ,@params))
      collect
        `(def-la (,(string-downcase (concatenate 'string strprefix strname "_"))
                   ,(intern (string-upcase (concatenate 'string strprefix strname))
                            (find-package (symbol-package name)))
                   :by-reference t
                   :size-type blas-size-t)
             ,(case result-type
                    ((:float :double)
                     prefix-type)
                    (otherwise result-type))
           ,@typed-args))))
