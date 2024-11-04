# Changelog

## Unreleased

- remove unnecessary parens from generated SQL to avoid hitting TOO_DEEP_RECURSION https://github.com/plausible/ecto_ch/pull/207

## 0.4.0 (2024-10-15)

- use `UNION DISTINCT` instead of `UNION` for `Ecto.Query.union/2` https://github.com/plausible/ecto_ch/pull/204

## 0.3.10 (2024-09-27)

- improve support for 128 and 256 bit integers https://github.com/plausible/ecto_ch/pull/192
- remove implicit `readonly=1` setting from `Repo.all` https://github.com/plausible/ecto_ch/pull/199

## 0.3.9 (2024-08-15)

- add support for 128 and 256 bit integers https://github.com/plausible/ecto_ch/pull/181
- drop `:array_join` support (please use ARRAY join hint instead) https://github.com/plausible/ecto_ch/pull/190
- adapt to Ecto v3.12 https://github.com/plausible/ecto_ch/pull/190
- support naive DateTime64 https://github.com/plausible/ecto_ch/pull/189

## 0.3.8 (2024-07-01)

- add DateTime64 precision https://github.com/plausible/ecto_ch/pull/179

## 0.3.7 (2024-06-15)

- add `alter_update_all/2` https://github.com/plausible/ecto_ch/pull/172

## 0.3.6 (2024-05-10)

- deprecate `:array_join` and support ARRAY join hint https://github.com/plausible/ecto_ch/pull/160

## 0.3.5 (2024-05-01)

- add `to_inline_sql/2` which is similar to `to_sql/2` but inlines the parameters into SQL https://github.com/plausible/ecto_ch/pull/157

## 0.3.4 (2024-04-07)

- support join strictness (ASOF, ANY, ANTI, SEMI) https://github.com/plausible/ecto_ch/pull/156

## 0.3.3 (2024-04-04)

- allow `Map(K,V)` params https://github.com/plausible/ecto_ch/pull/155

## 0.3.2 (2023-12-19)

- use DateTime64 for usec timestamps https://github.com/plausible/ecto_ch/pull/142

## 0.3.1 (2023-11-11)

- raise on `validate: true` in `CHECK` constraints https://github.com/plausible/ecto_ch/pull/124
- add support for unsafe hints https://github.com/plausible/ecto_ch/pull/102
- lookup types for aliased Ecto.Schema fields https://github.com/plausible/ecto_ch/pull/137

## 0.3.0 (2023-09-13)

- ensure all columns are for the same table in `ecto.ch.schema` mix task https://github.com/plausible/ecto_ch/pull/118
- switch from `CREATE INDEX` to `ALTER TABLE ... ADD INDEX` syntax for indexes https://github.com/plausible/ecto_ch/pull/120
- raise on `CREATE INDEX CONCURRENTLY` https://github.com/plausible/ecto_ch/pull/121
- switch from `DROP INDEX` to `ALTER TABLE ... DROP INDEX` syntax for indexes https://github.com/plausible/ecto_ch/pull/122
- add support for structured `:options` in migrations https://github.com/plausible/ecto_ch/pull/116
- add `:default_table_options` option https://github.com/plausible/ecto_ch/pull/123

## 0.2.2 (2023-08-29)

- use our http client for `structure_load` https://github.com/plausible/ecto_ch/pull/111

## 0.2.1 (2023-08-28)

- added constraint support in migrations https://github.com/plausible/ecto_ch/pull/108

## 0.2.0 (2023-07-28)

- refactor dumpers and loaders https://github.com/plausible/ecto_ch/pull/92 -- this is the reason for minor version bumping
- improve `ecto.ch.schema` mix task https://github.com/plausible/ecto_ch/pull/83

## 0.1.11 (2023-06-12)

- add support for `:array_join` and `:left_array_join` types https://github.com/plausible/ecto_ch/pull/76
- add preliminary support for inserts via `:input` https://github.com/plausible/ecto_ch/pull/79

## 0.1.10 (2023-06-01)

- add support for `type(..., :any)` https://github.com/plausible/ecto_ch/pull/78

## 0.1.9 (2023-05-24)

- update `:ch`

## 0.1.8 (2023-05-24)

- fix string types in schemaless inserts https://github.com/plausible/ecto_ch/pull/75

## 0.1.7 (2023-05-24)

- add `insert_stream` https://github.com/plausible/ecto_ch/pull/74

## 0.1.6 (2023-05-23)

- make types more strict https://github.com/plausible/ecto_ch/pull/69

## 0.1.5 (2023-05-23)

- require `:ch` to be `~> 0.1.10` https://github.com/plausible/ecto_ch/pull/71

## 0.1.4 (2023-05-05)

- improve `:array` type handling https://github.com/plausible/ecto_ch/pull/67

## 0.1.3 (2023-05-01)

- fix `in` params https://github.com/plausible/ecto_ch/pull/64

## 0.1.2 (2023-04-28)

- add `mix ecto.load` support https://github.com/plausible/ecto_ch/pull/60

## 0.1.1 (2023-04-26)

- add `:default_table_engine` option https://github.com/plausible/ecto_ch/pull/58
- add `ecto.ch.schema` mix task https://github.com/plausible/ecto_ch/pull/59
