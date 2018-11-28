/*
* Copyright 2017 Philipp Salvisberg <philipp.salvisberg@trivadis.com>
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

CREATE OR REPLACE VIEW plscope_identifiers AS
WITH
   src AS (
      SELECT /*+ materialize */
             owner,
             type,
             name,
             line,
             text
        FROM dba_source
       WHERE owner LIKE nvl(sys_context('PLSCOPE', 'OWNER'), USER)
         AND type LIKE nvl(sys_context('PLSCOPE', 'OBJECT_TYPE'), '%')
         AND name LIKE nvl(sys_context('PLSCOPE', 'OBJECT_NAME'), '%')
   ),
   prep_ids AS (
      SELECT owner,
             name,
             signature,
             type,
             object_name,
             object_type,
             usage,
             usage_id,
             line,
             col,
             usage_context_id,
             origin_con_id
        FROM dba_identifiers
      UNION ALL
      SELECT owner,
             ':' || NVL(sql_id, type) AS name,  -- intermediate statement marker colon
             signature,
             type,
             object_name,
             object_type,
             'EXECUTE' AS usage, -- new, artificial usage
             usage_id,
             line,
             col,
             usage_context_id,
             origin_con_id
       FROM dba_statements
   ),
   fids AS (
      SELECT owner,
             name,
             signature,
             type,
             object_name,
             object_type,
             usage,
             usage_id,
             line,
             col,
             usage_context_id,
             origin_con_id
        FROM prep_ids
       WHERE owner LIKE nvl(sys_context('PLSCOPE', 'OWNER'), USER)
         AND object_type LIKE nvl(sys_context('PLSCOPE', 'OBJECT_TYPE'), '%')
         AND object_name LIKE nvl(sys_context('PLSCOPE', 'OBJECT_NAME'), '%')
   ),
   base_ids AS (
      SELECT fids.owner,
             fids.name,
             fids.signature,
             fids.type,
             fids.object_name,
             fids.object_type,
             fids.usage,
             fids.usage_id,
             CASE
                WHEN fk.usage_id IS NOT NULL OR fids.usage_context_id = 0 THEN
                   'YES'
                ELSE
                   'NO'
             END AS sane_fk,
             fids.line,
             fids.col,
             fids.usage_context_id,
             fids.origin_con_id
        FROM fids
        LEFT JOIN fids fk
          ON fk.owner = fids.owner
             AND fk.object_type = fids.object_type
             AND fk.object_name = fids.object_name
             AND fk.usage_id = fids.usage_context_id
   ),
   ids AS (
      SELECT owner,
             name,
             signature,
             type,
             object_name,
             object_type,
             usage,
             usage_id,
             line,
             col,
             CASE
                WHEN sane_fk = 'YES' THEN
                   usage_context_id
                ELSE
                   last_value(CASE WHEN sane_fk = 'YES' THEN usage_id END) IGNORE NULLS OVER (
                      PARTITION BY owner, object_name, object_type
                      ORDER BY line, col
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                   )
             END AS usage_context_id, -- fix broken hierarchies
             origin_con_id
        FROM base_ids
   ),
   tree AS (
       SELECT ids.owner,
              ids.object_type,
              ids.object_name,
              ids.line,
              ids.col,
              ids.name,
              replace(sys_connect_by_path(ids.name, '|'),'|','/') AS name_path,
              level as path_len,
              ids.type,
              ids.usage,
              ids.signature,
              ids.usage_id,
              ids.usage_context_id,
              ids.origin_con_id
         FROM ids
        START WITH ids.usage_context_id = 0
      CONNECT BY  PRIOR ids.usage_id    = ids.usage_context_id
              AND PRIOR ids.owner       = ids.owner
              AND PRIOR ids.object_type = ids.object_type
              AND PRIOR ids.object_name = ids.object_name
   )
 SELECT /*+use_hash(tree) use_hash(refs) */
        tree.owner,
        tree.object_type,
        tree.object_name,
        tree.line,
        tree.col,
        last_value (
           CASE
              WHEN tree.type in ('PROCEDURE', 'FUNCTION') AND tree.path_len = 2  THEN
                 tree.signature
           END
        ) IGNORE NULLS OVER (
           PARTITION BY tree.owner, tree.object_name, tree.object_type
           ORDER BY tree.line, tree.col, tree.path_len
        ) AS procedure_signature,
        last_value (
           CASE
              WHEN tree.type in ('PROCEDURE', 'FUNCTION') AND tree.path_len = 2  THEN
                 tree.name
           END
        ) IGNORE NULLS OVER (
           PARTITION BY tree.owner, tree.object_name, tree.object_type
           ORDER BY tree.line, tree.col, tree.path_len
        ) AS procedure_name,
        last_value (
           CASE
              WHEN tree.object_type = 'PACKAGE BODY'
                AND tree.type in ('PROCEDURE', 'FUNCTION')
                AND tree.path_len = 2
              THEN
                 CASE tree.usage
                    WHEN 'DECLARATION' THEN
                       'PRIVATE'
                    WHEN 'DEFINITION' THEN
                       'PUBLIC'
                 END
           END
        ) IGNORE NULLS OVER (
           PARTITION BY tree.owner, tree.object_name, tree.object_type
           ORDER BY tree.line, tree.col, tree.path_len
        ) AS procedure_scope,
        REPLACE(tree.name, ':', NULL) AS name, -- remove intermediate statement marker
        REPLACE(tree.name_path, ':', NULL) AS name_path, -- remove intermediate statement marker
        tree.path_len,
        tree.type,
        tree.usage,
        refs.owner AS ref_owner,
        refs.object_type AS ref_object_type,
        refs.object_name AS ref_object_name,
        regexp_replace(src.text, chr(10)||'+$', null) AS text, -- remove trailing new line character
        CASE
           WHEN tree.name_path LIKE '%:%' AND tree.usage != 'EXECUTE' THEN
              -- ensure that this is really a child of a statement
              last_value (
                 CASE
                    WHEN tree.usage = 'EXECUTE' THEN
                       tree.type
                 END
              ) IGNORE NULLS OVER (
                 PARTITION BY tree.owner, tree.object_name, tree.object_type
                 ORDER BY tree.line, tree.col, tree.path_len
              )
        END AS parent_statement_type,
        CASE
           WHEN tree.name_path LIKE '%:%' AND tree.usage != 'EXECUTE' THEN
              -- ensure that this is really a child of a statement
              last_value (
                 CASE
                    WHEN tree.usage = 'EXECUTE' THEN
                       tree.signature
                 END
              ) IGNORE NULLS OVER (
                 PARTITION BY tree.owner, tree.object_name, tree.object_type
                 ORDER BY tree.line, tree.col, tree.path_len
              )
        END AS parent_statement_signature,
        CASE
           WHEN tree.name_path LIKE '%:%' AND tree.usage != 'EXECUTE' THEN
              -- ensure that this is really a child of a statement
              last_value (
                 CASE
                    WHEN tree.usage = 'EXECUTE' THEN
                       tree.path_len
                 END
              ) IGNORE NULLS OVER (
                 PARTITION BY tree.owner, tree.object_name, tree.object_type
                 ORDER BY tree.line, tree.col, tree.path_len
              )
        END AS parent_statement_path_len,
        CASE
           WHEN tree.object_type IN ('PACKAGE BODY', 'PROCEDURE', 'FUNCTION', 'TYPE BODY')
              AND tree.usage = 'DECLARATION'
              AND tree.type NOT IN ('LABEL')
           THEN
              CASE
                 WHEN
                    count(
                       CASE
                          WHEN tree.usage NOT IN ('DECLARATION', 'ASSIGNMENT')
                             OR (tree.type IN ('FORMAL OUT', 'FORMAL IN OUT')
                                 AND tree.usage = 'ASSIGNMENT')
                          THEN
                             1
                       END
                    ) OVER (
                       PARTITION BY tree.owner, tree.object_name, tree.object_type, tree.signature
                    ) = 0
                 THEN
                    'NO'
                 ELSE
                    'YES'
              END
        END AS is_used, -- wrong result, if used in statements which do not register usage, such as a variable for dynamic_sql_stmt in EXECUTE IMMEDIATE. Bug 26351814.
        tree.signature,
        tree.usage_id,
        tree.usage_context_id,
        tree.origin_con_id
   FROM tree
   LEFT JOIN dba_identifiers refs
     ON refs.signature = tree.signature
        AND refs.usage = 'DECLARATION'
   LEFT JOIN src
     ON src.owner = tree.owner
        AND src.type = tree.object_type
        AND src.name = tree.object_name
        AND src.line = tree.line;
