# Versioned migrations --------------------------------------------------------------------------
#
#   julia --project manage.jl makemigrations      # write migrations/0002_add_post_status.jl
#   julia --project manage.jl migrate             # apply everything pending
#   julia --project manage.jl migrate 0001        # go back to 0001 (unapplies later ones)
#   julia --project manage.jl migrate zero        # unapply all of the project's migrations
#   julia --project manage.jl showmigrations
#   julia --project manage.jl sqlmigrate 0002 [--backwards]
#
# Each app has a directory of migration files `NNNN_name.jl`. Juango's own apps (auth,
# contenttypes, sessions, admin, flatpages) ship theirs in src/assets/migrations/<label>/ and are
# migrated only when installed. Models of an `App` use its migrations/ folder; everything
# else belongs to "project" (directory `settings.MIGRATIONS_DIR`), unless a model sets
# `Meta(app_label=...)` and `settings.MIGRATION_MODULES` maps that app to a directory.
# An app without migration files is synchronised instead (tables and columns are created,
# never altered), which is how Juango behaved before migrations existed.

module Migrations

using Dates
import ..Juango
using ..Juango: Column, Table, Index, ConstraintSpec, Q, F, Value, CombinedExpression, Func, get_model, objects, save!, create, update!, SchemaState, copy_state, getcolumn, hascolumn, with_column, same_definition,
    backend, execute, atomic, settings, table_exists, table_columns, models_state, sync_models!, modelmeta,
    all_models, create_table_sql, drop_table_sql, rename_table_sql, add_column_sql, drop_column_sql,
    rename_column_sql, alter_column_sql, backfill_value, quote_name, VERSION_STRING, Decimal, @dec_str

export Migration, CreateModel, DeleteModel, RenameModel, AddField, RemoveField, AlterField, RenameField,
       AlterUniqueTogether, AlterPrimaryKey, AddIndex, RemoveIndex, AddConstraint, RemoveConstraint, RunSQL, RunJulia, SeparateDatabaseAndState, Column, Index,
       AlterModelTableComment, CreateExtension, HStoreExtension, TrigramExtension, UnaccentExtension, BtreeGistExtension, BtreeGinExtension, CITextExtension,
       ConstraintSpec, Q, F, Value, CombinedExpression, Func, get_model, objects, save!, create, update!,
       Decimal, @dec_str

include("operations.jl")
include("loader.jl")
include("executor.jl")
include("autodetector.jl")
include("writer.jl")

end # module Migrations

using .Migrations: makemigrations, showmigrations, sqlmigrate, squashmigrations, optimizemigration
migrate(; kw...) = Migrations.migrate(; kw...)
