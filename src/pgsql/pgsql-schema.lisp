;;;
;;; Tools to query the PostgreSQL Schema, either source or target
;;;

(in-package :pgloader.pgsql)

(defun fetch-pgsql-catalog (dbname
                            &key table source-catalog including excluding)
  "Fetch PostgreSQL catalogs for the target database. A PostgreSQL
   connection must be opened."
  (let* ((*identifier-case* :quote)
         (catalog   (make-catalog :name dbname))
         (including (cond ((and table (not including))
                           (make-including-expr-from-table table))

                          ((and source-catalog (not including))
                           (make-including-expr-from-catalog source-catalog))

                          (t
                           including))))

    (list-all-columns catalog
                      :table-type :table
                      :including including
                      :excluding excluding)

    (list-all-indexes catalog
                      :including including
                      :excluding excluding)

    (list-all-fkeys catalog
                    :including including
                    :excluding excluding)

    ;; fetch fkey we depend on with UNIQUE indexes but that have been
    ;; excluded from the target list, we still need to take care of them to
    ;; be able to DROP then CREATE those indexes again
    (list-missing-fk-deps catalog)

    (log-message :debug "fetch-pgsql-catalog: ~d tables, ~d indexes, ~d+~d fkeys"
                 (count-tables catalog)
                 (count-indexes catalog)
                 (count-fkeys catalog)
                 (loop :for table :in (table-list catalog)
                    :sum (loop :for index :in (table-index-list table)
                            :sum (length (index-fk-deps index)))))

    (when (and table (/= 1 (count-tables catalog)))
      (error "pgloader found ~d target tables for name ~a:~{~%  ~a~}"
             (count-tables catalog)
             (format-table-name table)
             (mapcar #'format-table-name (table-list catalog))))

    catalog))

(defun make-including-expr-from-catalog (catalog)
  "Return an expression suitable to be used as an :including parameter."
  (let (including current-schema)
    ;; The schema where to install the table or view in the target database
    ;; might be different from the schema where we find it in the source
    ;; table, thanks to the ALTER TABLE ... SET SCHEMA ... feature of
    ;; pgloader.
    ;;
    ;; The schema we want to lookup here is the target schema, so it's
    ;; (table-schema table) and not the schema where we found the table in
    ;; the catalog nested structure.
    ;;
    ;; Also, MySQL schema map to PostgreSQL databases, so we might have NIL
    ;; as a schema name here. In that case, we find the current PostgreSQL
    ;; schema and use that.
    (loop :for table :in (append (table-list catalog)
                                 (view-list catalog))
       :do (let* ((schema-name
                   (or (schema-name (table-schema table))
                       current-schema
                       (setf current-schema
                             (pomo:query "select current_schema()" :single))))
                  (table-expr
                   (format-table-name-as-including-exp table))
                  (schema-entry
                   (or (assoc schema-name including :test #'string=)
                       (progn (push (cons schema-name nil) including)
                              (assoc schema-name including :test #'string=)))))
             (push-to-end table-expr (cdr schema-entry))))
    ;; return the including alist
    including))

(defun make-including-expr-from-table (table)
  "Return an expression suitable to be used as an :including parameter."
  (let ((schema (or (table-schema table)
                    (query-table-schema table))))
    (list (cons (ensure-unquoted (schema-name schema))
                (list
                 (format-table-name-as-including-exp table))))))

(defun format-table-name-as-including-exp (table)
  "Return a table name suitable for a catalog lookup using ~ operator."
  (let ((table-name (table-name table)))
    (format nil "^~a$" (ensure-unquoted table-name))))

(defun query-table-schema (table)
  "Get PostgreSQL schema name where to locate TABLE-NAME by following the
  current search_path rules. A PostgreSQL connection must be opened."
  (make-schema :name
               (pomo:query (format nil
                                   (sql "/pgsql/query-table-schema.sql")
                                   (table-name table))
                           :single)))


(defvar *table-type* '((:table    . "r")
		       (:view     . "v")
                       (:index    . "i")
                       (:sequence . "S"))
  "Associate internal table type symbol with what's found in PostgreSQL
  pg_class.relkind column.")

(defun filter-list-to-where-clause (filter-list
                                    &optional
                                      not
                                      (schema-col "table_schema")
                                      (table-col  "table_name"))
  "Given an INCLUDING or EXCLUDING clause, turn it into a PostgreSQL WHERE
   clause."
  (loop :for (schema . table-name-list) :in filter-list
     :append (mapcar (lambda (table-name)
                       (format nil "(~a = '~a' and ~a ~:[~;NOT ~]~~ '~a')"
                               schema-col schema table-col not table-name))
                     table-name-list)))

(defun list-all-columns (catalog
                         &key
                           (table-type :table)
                           including
                           excluding
                         &aux
                           (table-type-name (cdr (assoc table-type *table-type*))))
  "Get the list of PostgreSQL column names per table."
  (loop :for (schema-name table-name table-oid name type typmod notnull default)
     :in
     (query nil
            (format nil
                    (sql "/pgsql/list-all-columns.sql")
                    table-type-name
                    including           ; do we print the clause?
                    (filter-list-to-where-clause including
                                                 nil
                                                 "n.nspname"
                                                 "c.relname")
                    excluding           ; do we print the clause?
                    (filter-list-to-where-clause excluding
                                                 nil
                                                 "n.nspname"
                                                 "c.relname")))
     :do
     (let* ((schema    (maybe-add-schema catalog schema-name))
            (table     (maybe-add-table schema table-name :oid table-oid))
            (field     (make-column :name name
                                    :type-name type
                                    :type-mod typmod
                                    :nullable (not notnull)
                                    :default default)))
       (add-field table field))
     :finally (return catalog)))

(defun list-all-indexes (catalog &key including excluding)
  "Get the list of PostgreSQL index definitions per table."
  (loop
     :for (schema-name name oid
                       table-schema table-name
                       primary unique sql conname condef)
     :in (query nil
                (format nil
                        (sql "/pgsql/list-all-indexes.sql")
                        including       ; do we print the clause?
                        (filter-list-to-where-clause including
                                                     nil
                                                     "rn.nspname"
                                                     "r.relname")
                        excluding       ; do we print the clause?
                        (filter-list-to-where-clause excluding
                                                     nil
                                                     "rn.nspname"
                                                     "r.relname")))
     :do (let* ((schema   (find-schema catalog schema-name))
                (tschema  (find-schema catalog table-schema))
                (table    (find-table tschema table-name))
                (pg-index
                 (make-index :name name
                             :oid oid
                             :schema schema
                             :table table
                             :primary primary
                             :unique unique
                             :columns nil
                             :sql sql
                             :conname (unless (eq :null conname) conname)
                             :condef  (unless (eq :null condef)  condef))))
           (maybe-add-index table name pg-index :key #'index-name))
     :finally (return catalog)))

(defun list-all-fkeys (catalog &key including excluding)
  "Get the list of PostgreSQL index definitions per table."
  (loop
     :for (schema-name table-name fschema-name ftable-name
                       conoid conname condef
                       cols fcols
                       updrule delrule mrule deferrable deferred)
     :in (query nil
                (format nil
                        (sql "/pgsql/list-all-fkeys.sql")
                        including       ; do we print the clause (table)?
                        (filter-list-to-where-clause including
                                                     nil
                                                     "n.nspname"
                                                     "c.relname")
                        excluding       ; do we print the clause (table)?
                        (filter-list-to-where-clause excluding
                                                     nil
                                                     "n.nspname"
                                                     "c.relname")
                        including       ; do we print the clause (ftable)?
                        (filter-list-to-where-clause including
                                                     nil
                                                     "nf.nspname"
                                                     "cf.relname")
                        excluding       ; do we print the clause (ftable)?
                        (filter-list-to-where-clause excluding
                                                     nil
                                                     "nf.nspname"
                                                     "cf.relname")))
     :do (flet ((pg-fk-rule-to-action (rule)
                  (case rule
                    (#\a "NO ACTION")
                    (#\r "RESTRICT")
                    (#\c "CASCADE")
                    (#\n "SET NULL")
                    (#\d "SET DEFAULT")))
                (pg-fk-match-rule-to-match-clause (rule)
                  (case rule
                    (#\f "FULL")
                    (#\p "PARTIAL")
                    (#\s "SIMPLE"))))
           (let* ((schema   (find-schema catalog schema-name))
                  (table    (find-table schema table-name))
                  (fschema  (find-schema catalog fschema-name))
                  (ftable   (find-table fschema ftable-name))
                  (fk
                   (make-fkey :name conname
                              :oid conoid
                              :condef condef
                              :table table
                              :columns (split-sequence:split-sequence #\, cols)
                              :foreign-table ftable
                              :foreign-columns (split-sequence:split-sequence #\, fcols)
                              :update-rule (pg-fk-rule-to-action updrule)
                              :delete-rule (pg-fk-rule-to-action delrule)
                              :match-rule (pg-fk-match-rule-to-match-clause mrule)
                              :deferrable deferrable
                              :initially-deferred deferred)))
             (if (and table ftable)
                 (add-fkey table fk)
                 (log-message :notice "Foreign Key ~a is ignored, one of its table is missing from pgloader table selection"
                              conname))))
     :finally (return catalog)))

(defun list-missing-fk-deps (catalog)
  "Add in the CATALOG the foreign keys we don't have to deal with directly
   but that the primary keys we are going to DROP then CREATE again depend
   on: we need to take care of those first."
  (destructuring-bind (pkey-oid-hash-table pkey-oid-list fkey-oid-list)
      (loop :with pk-hash := (make-hash-table)
         :for table :in (table-list catalog)
         :append (mapcar #'index-oid (table-index-list table)) :into pk
         :append (mapcar #'fkey-oid (table-fkey-list table)) :into fk
         :do (loop :for index :in (table-index-list table)
                :do (setf (gethash (index-oid index) pk-hash) index))
         :finally (return (list pk-hash pk fk)))

    (when pkey-oid-list
      (loop :for (schema-name table-name fschema-name ftable-name
                              conoid conname condef index-oid)
         :in (query nil
                    (format nil
                            (sql "/pgsql/list-missing-fk-deps.sql")
                            pkey-oid-list
                            (or fkey-oid-list (list -1))))
         ;;
         ;; We don't need to reference the main catalog entries for the tables
         ;; here, as the only goal is to be sure to DROP then CREATE again the
         ;; existing constraint that depend on the UNIQUE indexes we have to
         ;; DROP then CREATE again.
         ;;
         :do (let* ((schema  (make-schema :name schema-name))
                    (table   (make-table :name table-name :schema schema))
                    (fschema (make-schema :name fschema-name))
                    (ftable  (make-table :name ftable-name :schema fschema))
                    (index   (gethash index-oid pkey-oid-hash-table)))
               (push-to-end (make-fkey :name conname
                                       :oid conoid
                                       :condef condef
                                       :table table
                                       :foreign-table ftable)
                            (index-fk-deps index)))))))


;;;
;;; Extra utilities to introspect a PostgreSQL schema.
;;;
(defun list-schemas ()
  "Return the list of PostgreSQL schemas in the already established
   PostgreSQL connection."
  (pomo:query "SELECT nspname FROM pg_catalog.pg_namespace;" :column))

(defun list-table-oids (table-names)
  "Return an hash table mapping TABLE-NAME to its OID for all table in the
   TABLE-NAMES list. A PostgreSQL connection must be established already."
  (let ((oidmap (make-hash-table :size (length table-names) :test #'equal))
        (sql    (format nil (sql "/pgsql/list-table-oids.sql") table-names)))
    (when table-names
      (loop :for (name oid)
         :in (query nil sql)
         :do (setf (gethash name oidmap) oid)))
    oidmap))
