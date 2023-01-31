#lang racket/base

;; This module defines the structure types used to represent signatures
;; at compile time, plus some functions on those types.

(require (for-syntax racket/base
                     syntax/parse)
         racket/base
         racket/syntax
         syntax/parse
         "util.rkt"
         (for-template racket/base
                       "../keywords.rkt"))

(provide (rename-out [build-siginfo make-siginfo])
         siginfo-names
         siginfo-ctime-ids
         siginfo-rtime-ids
         ~bind-siginfo
         siginfo-subtype

         siginfo->key-expr
         siginfo->key-exprs
         ~bind-keys

         (struct-out signature)
         lookup-signature
         ~bind-signature
         ~bind-signature-ie
         signature-id
         tagged-signature-id
         opt-init-depends)

;; -----------------------------------------------------------------------------
;; siginfo

;; A siginfo contains information about the identity of a signature
;; and its super-signatures. Each of the three list fields are always
;; non-empty and the same length; the first element of each list
;; corresponds to the child signature, and each subsequent element
;; corresponds to the next super-signature in the inheritance chain.
(define-struct siginfo
  (names         ; (listof identifier?) - the identifiers bound by `define-signature`
   ctime-ids     ; (listof symbol?) - gensyms that uniquely identify the signature
                 ;   in the transformer environment
   rtime-ids     ; (listof identifier?) - identifiers bound to a gensym that
                 ;   uniquely identifies the signature at runtime; see
                 ;   Note [Signature runtime representation] in "../runtime.rkt"
   super-table)) ; (hash/c symbol? #t) - a hash that maps the elements of ctime-ids,
                 ;   to #t, used for efficient subtyping checks

;; build-siginfo : (listof symbol) (listof symbol) (listof identifier) -> siginfo
(define (build-siginfo names rtime-ids)
  (define ctime-ids 
    (cons (gensym)
          (if (null? (cdr names))
              null
              (siginfo-ctime-ids 
               (signature-siginfo
                (lookup-signature (cadr names)))))))
  (make-siginfo names
                ctime-ids
                rtime-ids 
                (make-immutable-hasheq (map (λ (x) `(,x . #t)) ctime-ids))))

;; Helper for bulk-binding attributes for siginfo values.
(define-syntax ~bind-siginfo
  (pattern-expander
   (syntax-parser
     [(_ x:id e:expr)
      #`{~and
         {~do (define tmp e)}
         #,@(if (empty-id? #'x) '()
                (list #'{~bind [x tmp]}))
         {~bind/nested
          x
          [{id 1} (siginfo-names tmp)]
          [self-id (car (siginfo-names tmp))]
          [{super-id 1} (cdr (siginfo-names tmp))]
          [{ctime-id 1} (siginfo-ctime-ids tmp)]
          [{rtime-id 1} (siginfo-rtime-ids tmp)]}}])))

;; siginfo-subtype : siginfo siginfo -> bool
(define (siginfo-subtype s1 s2)
  (hash-ref (siginfo-super-table s1)
            (car (siginfo-ctime-ids s2))
            (λ () #f)))

(define (build-key-expr tag rtime-id)
  (if tag
      #`(cons '#,tag #,rtime-id)
      rtime-id))

;; siginfo->key-expr : siginfo? (or/c symbol? #f) -> syntax?
;; Builds an expression that evaluates to this signature’s runtime key;
;; see Note [Signature runtime representation] in "../runtime.rkt".
(define (siginfo->key-expr info tag)
  (build-key-expr tag (car (siginfo-rtime-ids info))))

;; siginfo->key-exprs : siginfo? (or/c symbol? #f) -> (listof syntax?)
;; Builds a list of expressions that evaluate to runtime keys for this
;; signature and each of its super-signatures; see Note [Signature
;; runtime representation] in "../runtime.rkt".
(define (siginfo->key-exprs info tag)
  (map (λ (id) (build-key-expr tag id)) (siginfo-rtime-ids info)))

;; Helper for bulk-binding attributes for signature key expressions.
(define-syntax ~bind-keys
  (pattern-expander
   (syntax-parser
     [(_ x:id tag-e:expr info-e:expr)
      #`{~and
         {~do (define keys (siginfo->key-exprs info-e tag-e))}
         {~bind/nested
          x
          [{key 1} keys]
          [self-key (car keys)]
          [{super-key 1} (cdr keys)]}}])))

;; -----------------------------------------------------------------------------
;; signature

;; The compile-time value of a signature binding.
;; Note that a slightly modified variant of this structure is
;; sometimes used when processing imports and exports in a unit body, see
;; Note [Parsed signature imports and exports] in "import-export.rkt" for details.
(define-struct signature
  (siginfo       ; siginfo?
   vars          ; (listof identifier?)
   val-defs      ; (listof (cons/c (listof identifier?) syntax?))
   stx-defs      ; (listof (cons/c (listof identifier?) syntax?))
   post-val-defs ; (listof (cons/c (listof identifier?) syntax?))
   ctcs          ; (listof (or/c syntax? #f))
   orig-binder)  ; identifier?
  #:property prop:procedure
  (lambda (_ stx)
    (parameterize ((current-syntax-context stx))
      (raise-stx-err "illegal use of signature name"))))

;; lookup-signature : syntax-object -> signature
(define (lookup-signature id)
  (let ((s (lookup id "unknown signature")))
    (unless (signature? s)
      (raise-stx-err "not a signature" id))
    s))

(define (get-int-ids defs)
  (map (λ (def) (map car (car def))) defs))
(define (get-ext-ids defs)
  (map (λ (def) (map car (car def))) defs))

;; Helpers for bulk-binding attributes for signature and signature-ie
;; values; see Note [Parsed signature imports and exports] in
;; "import-export.rkt" for details about the latter.
(define-syntaxes [~bind-signature ~bind-signature-ie]
  (let ()
    (define (make ie?)
      (pattern-expander
       (syntax-parser
         [(_ x:id e:expr)
          #:with x-info (dotted-id #'x #'info)
          #`{~and
             {~do (define tmp e)}
             #,@(if (empty-id? #'x) '()
                    (list #'{~bind [x tmp]}))
             {~bind/nested
              x
              [{post-def.id 2} (map car (signature-post-val-defs tmp))]
              [{post-def.rhs 1} (map cdr (signature-post-val-defs tmp))]
              [{ctc 1} (signature-ctcs tmp)]
              #,@(if ie?
                     #'([{var.int-id 1} (map car (signature-vars tmp))]
                        [{var.ext-id 1} (map cdr (signature-vars tmp))]
                        [{val-def.int-id 2} (get-int-ids (signature-val-defs tmp))]
                        [{val-def.ext-id 2} (get-ext-ids (signature-val-defs tmp))]
                        [{val-def.rhs 1} (map cdr (signature-val-defs tmp))]
                        [{stx-def.int-id 2} (get-int-ids (signature-stx-defs tmp))]
                        [{stx-def.ext-id 2} (get-ext-ids (signature-stx-defs tmp))]
                        [{stx-def.rhs 1} (map cdr (signature-stx-defs tmp))])

                     #'([{var-id 1} (signature-vars tmp)]
                        [{val-def.id 2} (map car (signature-val-defs tmp))]
                        [{val-def.rhs 1} (map cdr (signature-val-defs tmp))]
                        [{stx-def.id 2} (map car (signature-stx-defs tmp))]
                        [{stx-def.rhs 1} (map cdr (signature-stx-defs tmp))]))}

             {~bind-siginfo #,(dotted-id #'x #'info) (signature-siginfo tmp)}}])))

    (values (make #f) (make #t))))

(define-syntax-class signature-id
  #:description #f
  #:attributes [value info
                {info.id 1} info.self-id {info.super-id 1}
                {info.ctime-id 1}
                {info.rtime-id 1}
                {var-id 1}
                {val-def.id 2} {val-def.rhs 1}
                {stx-def.id 2} {stx-def.rhs 1}
                {post-def.id 2} {post-def.rhs 1}
                {ctc 1}]
  #:commit
  (pattern {~var || (static/extract signature? "identifier bound to a signature")}
    #:and {~bind-signature || (attribute value)}))

(define-syntax-class tagged-signature-id
  #:description "tagged signature identifier"
  #:attributes [tag-id tag-sym sig-id value info
                {info.id 1} info.self-id {info.super-id 1}
                {info.ctime-id 1}
                {info.rtime-id 1}
                {var-id 1}
                {val-def.id 2} {val-def.rhs 1}
                {stx-def.id 2} {stx-def.rhs 1}
                {post-def.id 2} {post-def.rhs 1}
                {ctc 1}
                {key 1} self-key {super-key 1}]
  #:commit
  #:literals [tag]
  (pattern (tag ~! tag-id:id {~and sig-id :signature-id})
    #:attr tag-sym (syntax-e #'tag-id)
    #:and {~bind-keys || (attribute tag-sym) (attribute info)})
  (pattern {~and sig-id :signature-id}
    #:attr tag-id #f
    #:attr tag-sym #f
    #:and {~bind-keys || (attribute tag-sym) (attribute info)}))

(define-splicing-syntax-class opt-init-depends
  #:description #f
  #:attributes [{dep 1} {tag-id 1} {tag-sym 1} {sig-id 1} {value 1} {info 1}
                {info.id 2} {info.self-id 1} {info.super-id 2}
                {info.ctime-id 2}
                {info.rtime-id 2}
                {var-id 2}
                {val-def.id 3} {val-def.rhs 2}
                {stx-def.id 3} {stx-def.rhs 2}
                {post-def.id 3} {post-def.rhs 2}
                {ctc 2}
                {key 2} {self-key 1} {super-key 2}]
  #:commit
  #:literals [init-depend]
  (pattern (init-depend ~! {~and dep :tagged-signature-id} ...))
  ;; Handling the optionality this way rather than wrapping the
  ;; pattern with ~optional avoids having to deal with #f attributes.
  (pattern {~seq} #:with [{~and dep :tagged-signature-id} ...] #'[]))