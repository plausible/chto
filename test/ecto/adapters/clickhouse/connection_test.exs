defmodule Ecto.Adapters.ClickHouse.ConnectionTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.ClickHouse
  alias Ecto.Adapters.ClickHouse.Connection
  alias Ecto.Migration.Reference

  import Ecto.Query
  import Ecto.Migration, only: [table: 1, table: 2, index: 3, constraint: 3]
  require Ecto.Adapters.ClickHouse.API
  import Ecto.Adapters.ClickHouse.API, only: [with_cte_expression: 3]

  defmodule Comment do
    use Ecto.Schema

    schema "comments" do
      field(:content, :string)
    end
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:content, :string)
      has_many(:comments, Comment)
    end
  end

  defmodule Schema do
    use Ecto.Schema

    schema "schema" do
      field(:x, Ch, type: "UInt8")
      field(:y, Ch, type: "UInt16")
      field(:z, Ch, type: "UInt64")
      field(:meta, :map)

      has_many(:comments, Ecto.Adapters.ClickHouse.ConnectionTest.Schema2,
        references: :x,
        foreign_key: :z
      )

      has_one(:permalink, Ecto.Adapters.ClickHouse.ConnectionTest.Schema3,
        references: :y,
        foreign_key: :id
      )
    end
  end

  defmodule Schema2 do
    use Ecto.Schema

    schema "schema2" do
      belongs_to(:post, Ecto.Adapters.ClickHouse.ConnectionTest.Schema,
        references: :x,
        foreign_key: :z
      )
    end
  end

  defmodule Schema3 do
    use Ecto.Schema

    schema "schema3" do
      field(:binary, :binary)
    end
  end

  defp plan(query, operation) do
    {query, _cast_params, dump_params} =
      Ecto.Adapter.Queryable.plan_query(operation, ClickHouse, query)

    {query, dump_params}
  end

  defp all(query) do
    {query, params} = plan(query, :all)

    query
    |> Connection.all(params)
    |> IO.iodata_to_binary()
  end

  defp update_all(query) do
    {query, params} = plan(query, :update_all)
    query |> Connection.update_all(params) |> IO.iodata_to_binary()
  end

  defp delete_all(query) do
    {query, params} = plan(query, :delete_all)
    query |> Connection.delete_all(params) |> IO.iodata_to_binary()
  end

  defp alter_update_all(query) do
    {query, params} = plan(query, :update_all)
    query |> Connection.alter_update_all(params) |> IO.iodata_to_binary()
  end

  defp insert(prefix, table, header, rows, on_conflict, returning, placeholders \\ []) do
    Connection.insert(prefix, table, header, rows, on_conflict, returning, placeholders)
    |> IO.iodata_to_binary()
  end

  defp update(prefix, table, fields, filters, returning) do
    Connection.update(prefix, table, fields, filters, returning) |> IO.iodata_to_binary()
  end

  defp delete(prefix, table, filters, returning) do
    Connection.delete(prefix, table, filters, returning) |> IO.iodata_to_binary()
  end

  defp execute_ddl(query) do
    query
    |> Connection.execute_ddl()
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  test "from" do
    query = Schema |> select([r], r.x)
    assert all(query) == ~s[SELECT s0."x" FROM "schema" AS s0]
  end

  test "from with hints" do
    # With string
    query = Schema |> from(hints: "USE INDEX FOO") |> select([r], r.x)
    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 USE INDEX FOO}

    # With list of strings
    query = Schema |> from(hints: ["INDEXED BY FOO", "INDEXED BY BAR"]) |> select([r], r.x)
    assert all(query) == ~s[SELECT s0."x" FROM "schema" AS s0 INDEXED BY FOO INDEXED BY BAR]
  end

  # TODO merge with test above once ecto 3.10.4 is released
  @tag :skip
  test "from with unsafe hints" do
    # # With unsafe fragment
    # hint = "USE INDEX BAR"
    # query = Schema |> from(hints: unsafe_fragment(^hint)) |> select([r], r.x)
    # assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 USE INDEX BAR}

    # # With list of string and unsafe fragment
    # hint = "USE INDEX BAR"
    # query = Schema |> from(hints: ["USE INDEX FOO", unsafe_fragment(^hint)]) |> select([r], r.x)
    # assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 USE INDEX FOO USE INDEX BAR}
  end

  test "from without schema" do
    query = "posts" |> select([r], r.x)
    assert all(query) == ~s[SELECT p0."x" FROM "posts" AS p0]

    # query = "posts" |> select([r], fragment("?", r))
    # assert all(query) == ~s[SELECT p0 FROM "posts" AS p0]

    query = "Posts" |> select([r], r.x)
    assert all(query) == ~s[SELECT P0."x" FROM "Posts" AS P0]

    query = "0posts" |> select([:x])
    assert all(query) == ~s{SELECT t0."x" FROM "0posts" AS t0}
  end

  test "from with subquery" do
    query =
      "posts"
      |> select([r], %{x: r.x, y: r.y})
      |> subquery()
      |> select([r], r.x)

    assert all(query) == """
           SELECT s0."x" \
           FROM (SELECT sp0."x" AS "x",sp0."y" AS "y" FROM "posts" AS sp0) AS s0\
           """

    query =
      "posts"
      |> select([r], %{x: r.x, z: r.y})
      |> subquery()
      |> select([r], r)

    assert all(query) == """
           SELECT s0."x",s0."z" \
           FROM (SELECT sp0."x" AS "x",sp0."y" AS "z" FROM "posts" AS sp0) AS s0\
           """

    query =
      "posts"
      |> select([r], %{x: r.x, z: r.y})
      |> subquery()
      |> select([r], r)
      |> subquery()
      |> select([r], r)

    assert all(query) == """
           SELECT s0."x",s0."z" \
           FROM (\
           SELECT ss0."x" AS "x",ss0."z" AS "z" \
           FROM (\
           SELECT ssp0."x" AS "x",ssp0."y" AS "z" \
           FROM "posts" AS ssp0\
           ) AS ss0\
           ) AS s0\
           """
  end

  test "common table expression" do
    iteration_query =
      "categories"
      |> join(:inner, [c], t in "tree", on: t.id == c.parent_id)
      |> select([c, t], %{id: c.id, depth: fragment("? + 1", t.depth)})

    cte_query =
      "categories"
      |> where([c], is_nil(c.parent_id))
      |> select([c], %{id: c.id, depth: fragment("1")})
      |> union_all(^iteration_query)

    query =
      Schema
      |> recursive_ctes(true)
      |> with_cte("tree", as: ^cte_query)
      |> join(:inner, [r], t in "tree", on: t.id == r.category_id)
      |> select([r, t], %{x: r.x, category_id: t.id, depth: type(t.depth, :integer)})

    assert all(query) ==
             """
             WITH RECURSIVE "tree" AS \
             (SELECT sc0."id" AS "id",1 AS "depth" FROM "categories" AS sc0 WHERE (isNull(sc0."parent_id")) \
             UNION ALL \
             (SELECT c0."id",t1."depth" + 1 FROM "categories" AS c0 \
             INNER JOIN "tree" AS t1 ON t1."id" = c0."parent_id")) \
             SELECT s0."x",t1."id",CAST(t1."depth" AS Int64) \
             FROM "schema" AS s0 \
             INNER JOIN "tree" AS t1 ON t1."id" = s0."category_id"\
             """
  end

  test "common table expression with expression instead of subquery" do
    query =
      Schema
      |> with_cte_expression(fragment("123"), as: "value")
      |> select([], fragment("value"))

    assert all(query) == "WITH 123 AS \"value\" SELECT value FROM \"schema\" AS s0"
  end

  test "reference common table in union" do
    comments_scope_query =
      "comments"
      |> where([c], is_nil(c.deleted_at))
      |> select([c], %{entity_id: c.entity_id, text: c.text})

    posts_query =
      "posts"
      |> join(:inner, [p], c in "comments_scope", on: c.entity_id == p.guid)
      |> select([p, c], [p.title, c.text])

    videos_query =
      "videos"
      |> join(:inner, [v], c in "comments_scope", on: c.entity_id == v.guid)
      |> select([v, c], [v.title, c.text])

    query =
      posts_query
      |> union_all(^videos_query)
      |> with_cte("comments_scope", as: ^comments_scope_query)

    assert all(query) ==
             """
             WITH "comments_scope" AS (\
             SELECT sc0."entity_id" AS "entity_id",sc0."text" AS "text" \
             FROM "comments" AS sc0 WHERE (isNull(sc0."deleted_at"))) \
             SELECT p0."title",c1."text" \
             FROM "posts" AS p0 \
             INNER JOIN "comments_scope" AS c1 ON c1."entity_id" = p0."guid" \
             UNION ALL \
             (SELECT v0."title",c1."text" \
             FROM "videos" AS v0 \
             INNER JOIN "comments_scope" AS c1 ON c1."entity_id" = v0."guid")\
             """
  end

  @raw_sql_cte """
  SELECT * FROM categories WHERE c.parent_id IS NULL \
  UNION ALL \
  SELECT * FROM categories AS c, category_tree AS ct WHERE ct.id = c.parent_id\
  """

  test "fragment common table expression" do
    query =
      Schema
      |> recursive_ctes(true)
      |> with_cte("tree", as: fragment(@raw_sql_cte))
      |> join(:inner, [p], c in "tree", on: c.id == p.category_id)
      |> select([r], r.x)

    assert all(query) ==
             """
             WITH RECURSIVE "tree" AS (#{@raw_sql_cte}) \
             SELECT s0."x" \
             FROM "schema" AS s0 \
             INNER JOIN "tree" AS t1 ON t1."id" = s0."category_id"\
             """
  end

  test "common table expression update_all" do
    cte_query =
      from(
        x in Schema,
        order_by: [asc: :id],
        limit: 10,
        select: %{id: x.id}
      )

    query =
      Schema
      |> with_cte("target_rows", as: ^cte_query)
      |> join(:inner, [row], target in "target_rows", on: target.id == row.id)
      |> update(set: [x: 123])

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support UPDATE statements/,
                 fn -> Connection.update_all(query) end
  end

  test "common table expression delete_all" do
    cte_query = from(x in Schema, order_by: [asc: :id], limit: 10, select: %{id: x.id})

    query =
      Schema
      |> with_cte("target_rows", as: ^cte_query)

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support CTEs \(WITH\) on DELETE statements/,
                 fn -> delete_all(query) end
  end

  test "select" do
    query = Schema |> select([r], {r.x, r.y})
    assert all(query) == ~s[SELECT s0."x",s0."y" FROM "schema" AS s0]

    query = Schema |> select([r], [r.x, r.y])
    assert all(query) == ~s[SELECT s0."x",s0."y" FROM "schema" AS s0]

    query = Schema |> select([r], struct(r, [:x, :y]))
    assert all(query) == ~s[SELECT s0."x",s0."y" FROM "schema" AS s0]
  end

  test "aggregates" do
    query = Schema |> select(count())
    assert all(query) == ~S[SELECT count(*) FROM "schema" AS s0]

    query = Schema |> select([s], count(s.x))
    assert all(query) == ~S[SELECT count(s0."x") FROM "schema" AS s0]

    query = Schema |> select([s], count(s.x, :distinct))
    assert all(query) == ~S[SELECT countDistinct(s0."x") FROM "schema" AS s0]
  end

  test "aggregate filters" do
    query = Schema |> select([r], count(r.x) |> filter(r.x > 10))
    assert all(query) == ~s[SELECT count(s0."x") FILTER (WHERE s0."x" > 10) FROM "schema" AS s0]

    query = Schema |> select([r], count(r.x) |> filter(r.x > 10 and r.x < 50))

    assert all(query) ==
             ~s[SELECT count(s0."x") FILTER (WHERE (s0."x" > 10) AND (s0."x" < 50)) FROM "schema" AS s0]

    query = Schema |> select([r], count() |> filter(r.x > 10))
    assert all(query) == ~s[SELECT count(*) FILTER (WHERE s0."x" > 10) FROM "schema" AS s0]
  end

  test "distinct" do
    query = Schema |> distinct([r], true) |> select([r], {r.x, r.y})
    assert all(query) == ~s[SELECT DISTINCT s0."x",s0."y" FROM "schema" AS s0]

    query = Schema |> distinct([r], false) |> select([r], {r.x, r.y})
    assert all(query) == ~s[SELECT s0."x",s0."y" FROM "schema" AS s0]

    query = Schema |> distinct(true) |> select([r], {r.x, r.y})
    assert all(query) == ~s[SELECT DISTINCT s0."x",s0."y" FROM "schema" AS s0]

    query = Schema |> distinct(false) |> select([r], {r.x, r.y})
    assert all(query) == ~s[SELECT s0."x",s0."y" FROM "schema" AS s0]

    query = Schema |> distinct([r], [r.x, r.y]) |> select([r], {r.x, r.y})
    assert all(query) == ~s[SELECT DISTINCT ON (s0."x",s0."y") s0."x",s0."y" FROM "schema" AS s0]
  end

  test "coalesce" do
    query = Schema |> select([s], coalesce(s.x, 5))
    assert all(query) == ~s[SELECT coalesce(s0."x",5) FROM "schema" AS s0]
  end

  test "where" do
    query =
      Schema
      |> where([r], r.x == 42)
      |> where([r], r.y != 43)
      |> select([r], r.x)

    assert all(query) ==
             ~s[SELECT s0."x" FROM "schema" AS s0 WHERE (s0."x" = 42) AND (s0."y" != 43)]

    query = Schema |> where([r], {r.x, r.y} > {1, 2}) |> select([r], r.x)
    assert all(query) == ~s[SELECT s0."x" FROM "schema" AS s0 WHERE ((s0."x",s0."y") > (1,2))]
  end

  # TODO remove (kept for smaller diffs)
  test "where with big AND chain (NOT) gets many parens" do
    assert all(from e in "events", where: true and true and true and true and true, select: true) ==
             """
             SELECT true FROM "events" AS e0 WHERE (1 AND 1 AND 1 AND 1 AND 1)\
             """
  end

  # TODO remove (kept for smaller diffs)
  test "many where clauses get flat AND chain" do
    assert all(
             from e in "events",
               where: true,
               where: true,
               where: true,
               where: true,
               where: true,
               select: true
           ) == """
           SELECT true FROM "events" AS e0 WHERE (1) AND (1) AND (1) AND (1) AND (1)\
           """
  end

  test "single where with AND/OR chains" do
    assert all(
             from e in "events",
               where: true and true and true and true and true,
               select: true
           ) ==
             """
             SELECT true FROM "events" AS e0 WHERE (1 AND 1 AND 1 AND 1 AND 1)\
             """

    assert all(
             from e in "events",
               where: true or true or true or true or true,
               select: true
           ) ==
             """
             SELECT true FROM "events" AS e0 WHERE (1 OR 1 OR 1 OR 1 OR 1)\
             """

    # :) explain syntax select 1 AND 1 AND 1 OR 1 OR 1 OR 1 AND 1 OR 1;
    # SELECT (1 AND 1 AND 1) OR 1 OR 1 OR (1 AND 1) OR 1
    assert all(
             from e in "events",
               where: (true and true and true) or true or true or (true and true) or true,
               select: true
           ) ==
             """
             SELECT true FROM "events" AS e0 WHERE (\
             (1 AND 1 AND 1) OR 1 OR 1 OR (1 AND 1) OR 1\
             )\
             """

    assert all(
             from e in "events",
               where: (true and true and true) or true or true or (true and (true or true)),
               select: true
           ) ==
             """
             SELECT true FROM "events" AS e0 WHERE (\
             (1 AND 1 AND 1) OR 1 OR 1 OR (1 AND (1 OR 1))\
             )\
             """
  end

  test "many where with AND/OR chains" do
    assert all(
             from e in "events",
               where: fragment("1"),
               where: fragment("2"),
               where: fragment("3"),
               where: fragment("4"),
               where: fragment("5"),
               select: true
           ) == """
           SELECT true FROM "events" AS e0 WHERE (1) AND (2) AND (3) AND (4) AND (5)\
           """

    assert all(
             from e in "events",
               or_where: fragment("1"),
               or_where: fragment("2"),
               or_where: fragment("3"),
               or_where: fragment("4"),
               or_where: fragment("5"),
               select: true
           ) == """
           SELECT true FROM "events" AS e0 WHERE (1) OR (2) OR (3) OR (4) OR (5)\
           """

    # NOTE: when multiple :where/:or_where are used, the order is preserved using parens with left-to-right precedence
    assert all(
             from e in "events",
               where: fragment("1"),
               where: fragment("2"),
               where: fragment("3"),
               or_where: fragment("4"),
               or_where: fragment("5"),
               where: fragment("6"),
               where: fragment("7"),
               or_where: fragment("8"),
               select: true
           ) == """
           SELECT true FROM "events" AS e0 WHERE ((((1) AND (2) AND (3)) OR (4) OR (5)) AND (6) AND (7)) OR (8)\
           """
  end

  test "many where with AND/OR chains inside" do
    assert all(
             from e in "events",
               where: true and true and true,
               where: true and true,
               select: true
           ) == """
           SELECT true FROM "events" AS e0 WHERE (1 AND 1 AND 1) AND (1 AND 1)\
           """

    assert all(
             from e in "events",
               where: true and true and true,
               or_where: true and true,
               select: true
           ) == """
           SELECT true FROM "events" AS e0 WHERE ((1 AND 1 AND 1)) OR (1 AND 1)\
           """
  end

  test "or_where" do
    query =
      Schema
      |> or_where([r], r.x == 42)
      |> or_where([r], r.y != 43)
      |> select([r], r.x)

    assert all(query) ==
             ~s[SELECT s0."x" FROM "schema" AS s0 WHERE (s0."x" = 42) OR (s0."y" != 43)]

    query =
      Schema
      |> or_where([r], r.x == 42)
      |> or_where([r], r.y != 43)
      |> where([r], r.z == 44)
      |> select([r], r.x)

    assert all(query) ==
             ~s[SELECT s0."x" FROM "schema" AS s0 WHERE ((s0."x" = 42) OR (s0."y" != 43)) AND (s0."z" = 44)]
  end

  test "nested dynamic" do
    dynamic = dynamic([e], e.site_id == ^1)

    assert all(from e in "events", where: ^dynamic, select: count()) ==
             """
             SELECT count(*) FROM "events" AS e0 WHERE (e0."site_id" = {$0:Int64})\
             """

    dynamic = dynamic([e], ^dynamic and e.timestamp < ^~D[2025-01-01])

    assert all(from e in "events", where: ^dynamic, select: count()) ==
             """
             SELECT count(*) FROM "events" AS e0 WHERE ((e0."site_id" = {$0:Int64}) AND (e0."timestamp" < {$1:Date}))\
             """

    dynamic = dynamic([e], ^dynamic and e.timestamp >= ^~D[2024-01-01])

    assert all(from e in "events", where: ^dynamic, select: count()) ==
             """
             SELECT count(*) FROM "events" AS e0 WHERE ((e0."site_id" = {$0:Int64}) AND (e0."timestamp" < {$1:Date}) AND (e0."timestamp" >= {$2:Date}))\
             """

    # imagine:
    # (has_key(t, :"meta.key", ^"content-platform") and
    #    get_by_key(t, :"meta.key", ^"content-platform") in ^["(none)", "web", "app"]) or
    #   (^true and not has_key(t, :"meta.key", ^"content-platform"))
    dynamic = dynamic([e], ^dynamic and ((true and false) or (true and not true)))

    assert all(from e in "events", where: ^dynamic, select: count()) ==
             """
             SELECT count(*) FROM "events" AS e0 WHERE ((e0."site_id" = {$0:Int64}) AND (e0."timestamp" < {$1:Date}) AND (e0."timestamp" >= {$2:Date}) AND ((1 AND 0) OR (1 AND not(1))))\
             """
  end

  test "order_by" do
    query = Schema |> order_by([r], r.x) |> select([r], r.x)
    assert all(query) == ~s[SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x"]

    query = Schema |> order_by([r], [r.x, r.y]) |> select([r], r.x)
    assert all(query) == ~s[SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x",s0."y"]

    query = Schema |> order_by([r], asc: r.x, desc: r.y) |> select([r], r.x)

    assert all(query) ==
             ~s[SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x",s0."y" DESC]

    query = Schema |> order_by([r], []) |> select([r], r.x)
    assert all(query) == ~s[SELECT s0."x" FROM "schema" AS s0]

    query =
      Schema |> order_by([r], asc_nulls_first: r.x, desc_nulls_first: r.y) |> select([r], r.x)

    assert all(query) ==
             ~s[SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x" ASC NULLS FIRST,s0."y" DESC NULLS FIRST]

    query = Schema |> order_by([r], asc_nulls_last: r.x, desc_nulls_last: r.y) |> select([r], r.x)

    assert all(query) ==
             ~s[SELECT s0."x" FROM "schema" AS s0 ORDER BY s0."x" ASC NULLS LAST,s0."y" DESC NULLS LAST]
  end

  test "union, union all, and union distinct" do
    base_query =
      Schema
      |> select([r], r.x)
      |> order_by(fragment("rand()"))
      |> offset(10)
      |> limit(5)

    union_query1 =
      Schema
      |> select([r], r.y)
      |> order_by([r], r.y)
      |> offset(20)
      |> limit(40)

    union_query2 =
      Schema
      |> select([r], r.z)
      |> order_by([r], r.z)
      |> offset(30)
      |> limit(60)

    query =
      base_query
      |> union(^union_query1)
      |> union(^union_query2)

    assert all(query) ==
             """
             SELECT s0."x" FROM "schema" AS s0 ORDER BY rand() LIMIT 5 OFFSET 10 \
             UNION DISTINCT (SELECT s0."y" FROM "schema" AS s0 ORDER BY s0."y" LIMIT 40 OFFSET 20) \
             UNION DISTINCT (SELECT s0."z" FROM "schema" AS s0 ORDER BY s0."z" LIMIT 60 OFFSET 30)\
             """

    query =
      base_query
      |> union_all(^union_query1)
      |> union_all(^union_query2)

    assert all(query) ==
             """
             SELECT s0."x" FROM "schema" AS s0 ORDER BY rand() LIMIT 5 OFFSET 10 \
             UNION ALL (SELECT s0."y" FROM "schema" AS s0 ORDER BY s0."y" LIMIT 40 OFFSET 20) \
             UNION ALL (SELECT s0."z" FROM "schema" AS s0 ORDER BY s0."z" LIMIT 60 OFFSET 30)\
             """
  end

  test "except and except all" do
    base_query =
      Schema
      |> select([r], r.x)
      |> order_by(fragment("rand()"))
      |> offset(10)
      |> limit(5)

    except_query1 =
      Schema
      |> select([r], r.y)
      |> order_by([r], r.y)
      |> offset(20)
      |> limit(40)

    except_query2 =
      Schema
      |> select([r], r.z)
      |> order_by([r], r.z)
      |> offset(30)
      |> limit(60)

    query =
      base_query
      |> except(^except_query1)
      |> except(^except_query2)

    assert all(query) ==
             """
             SELECT s0."x" FROM "schema" AS s0 ORDER BY rand() LIMIT 5 OFFSET 10 \
             EXCEPT (SELECT s0."y" FROM "schema" AS s0 ORDER BY s0."y" LIMIT 40 OFFSET 20) \
             EXCEPT (SELECT s0."z" FROM "schema" AS s0 ORDER BY s0."z" LIMIT 60 OFFSET 30)\
             """

    assert_raise Ecto.QueryError, ~r/ClickHouse does not support EXCEPT ALL/, fn ->
      base_query
      |> except_all(^except_query1)
      |> except_all(^except_query2)
      |> all()
    end
  end

  test "intersect and intersect all" do
    base_query =
      Schema
      |> select([r], r.x)
      |> order_by(fragment("rand()"))
      |> offset(10)
      |> limit(5)

    intersect_query1 =
      Schema
      |> select([r], r.y)
      |> order_by([r], r.y)
      |> offset(20)
      |> limit(40)

    intersect_query2 =
      Schema
      |> select([r], r.z)
      |> order_by([r], r.z)
      |> offset(30)
      |> limit(60)

    query =
      base_query
      |> intersect(^intersect_query1)
      |> intersect(^intersect_query2)

    assert all(query) ==
             """
             SELECT s0."x" FROM "schema" AS s0 ORDER BY rand() LIMIT 5 OFFSET 10 \
             INTERSECT (SELECT s0."y" FROM "schema" AS s0 ORDER BY s0."y" LIMIT 40 OFFSET 20) \
             INTERSECT (SELECT s0."z" FROM "schema" AS s0 ORDER BY s0."z" LIMIT 60 OFFSET 30)\
             """

    assert_raise Ecto.QueryError, ~r/ClickHouse does not support INTERSECT ALL/, fn ->
      base_query
      |> intersect_all(^intersect_query1)
      |> intersect_all(^intersect_query2)
      |> all()
    end
  end

  test "limit and offset" do
    query = Schema |> limit([r], 3) |> select([], true)
    assert all(query) == ~s[SELECT true FROM "schema" AS s0 LIMIT 3]

    query = Schema |> offset([r], 5) |> select([], true)
    assert all(query) == ~s[SELECT true FROM "schema" AS s0 OFFSET 5]

    query = Schema |> offset([r], 5) |> limit([r], 3) |> select([], true)
    assert all(query) == ~s[SELECT true FROM "schema" AS s0 LIMIT 3 OFFSET 5]
  end

  test "lock" do
    assert_raise ArgumentError,
                 "ClickHouse does not support locks",
                 fn ->
                   Schema
                   |> lock("LOCK IN SHARE MODE")
                   |> select([], true)
                   |> all()
                 end

    assert_raise ArgumentError,
                 "ClickHouse does not support locks",
                 fn ->
                   Schema
                   |> lock([p], fragment("UPDATE on ?", p))
                   |> select([], true)
                   |> all()
                 end
  end

  test "string escape" do
    query = "schema" |> where(foo: "'\\  ") |> select([], true)
    assert all(query) == ~s[SELECT true FROM "schema" AS s0 WHERE (s0."foo" = '''\\\\  ')]

    query = "schema" |> where(foo: "'") |> select([], true)
    assert all(query) == ~s[SELECT true FROM "schema" AS s0 WHERE (s0."foo" = '''')]
  end

  test "binary ops" do
    query = Schema |> select([r], r.x == 2)
    assert all(query) == ~s[SELECT s0."x" = 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x != 2)
    assert all(query) == ~s[SELECT s0."x" != 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x <= 2)
    assert all(query) == ~s[SELECT s0."x" <= 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x >= 2)
    assert all(query) == ~s[SELECT s0."x" >= 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x < 2)
    assert all(query) == ~s[SELECT s0."x" < 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x > 2)
    assert all(query) == ~s[SELECT s0."x" > 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x + 2)
    assert all(query) == ~s[SELECT s0."x" + 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x - 2)
    assert all(query) == ~s[SELECT s0."x" - 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x * 2)
    assert all(query) == ~s[SELECT s0."x" * 2 FROM "schema" AS s0]

    query = Schema |> select([r], r.x / 2)
    assert all(query) == ~s[SELECT s0."x" / 2 FROM "schema" AS s0]
  end

  test "is_nil" do
    query = Schema |> select([r], is_nil(r.x))
    assert all(query) == ~s[SELECT isNull(s0."x") FROM "schema" AS s0]

    query = Schema |> select([r], not is_nil(r.x))
    assert all(query) == ~s[SELECT isNotNull(s0."x") FROM "schema" AS s0]

    query = "schema" |> select([r], r.x == is_nil(r.y))
    assert all(query) == ~s[SELECT s0."x" = isNull(s0."y") FROM "schema" AS s0]
  end

  test "not" do
    assert all(from e in "events", select: not e.is_bounce) ==
             ~s[SELECT not(e0."is_bounce") FROM "events" AS e0]

    assert all(from e in "events", select: not is_nil(e.name)) ==
             ~s[SELECT isNotNull(e0."name") FROM "events" AS e0]

    assert all(from e in "events", select: not like(e.name, "page%")) ==
             ~s[SELECT notLike(e0."name", 'page%') FROM "events" AS e0]

    assert all(from e in "events", select: not ilike(e.name, "page%")) ==
             ~s[SELECT notILike(e0."name", 'page%') FROM "events" AS e0]
  end

  @decimal64_2 Ecto.ParameterizedType.init(Ch, type: "Decimal64(2)")
  test "order_by and types" do
    query =
      "schema3"
      |> order_by([e], type(fragment("?", e.binary), ^@decimal64_2))
      |> select(true)

    assert all(query) ==
             ~s[SELECT true FROM "schema3" AS s0 ORDER BY CAST(s0."binary" AS Decimal(18, 2))]
  end

  test "fragments" do
    query = Schema |> select([r], fragment("now()"))
    assert all(query) == ~s[SELECT now() FROM "schema" AS s0]

    query = Schema |> select([r], fragment("fun(?)", r))
    assert all(query) == ~s[SELECT fun(s0) FROM "schema" AS s0]

    query = Schema |> select([r], fragment("lcase(?)", r.x))
    assert all(query) == ~s[SELECT lcase(s0."x") FROM "schema" AS s0]

    query =
      Schema
      |> select([r], r.x)
      |> where([], fragment(~s|? = "query\\?"|, ^10))

    assert all(query) == ~s[SELECT s0."x" FROM "schema" AS s0 WHERE ({$0:Int64} = "query?")]

    value = 13
    query = Schema |> select([r], fragment("lcase(?, ?)", r.x, ^value))
    assert all(query) == ~s[SELECT lcase(s0."x", {$0:Int64}) FROM "schema" AS s0]

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse adapter does not support keyword or interpolated fragments/,
                 fn ->
                   Schema
                   |> select([], fragment(title: 2))
                   |> all()
                 end
  end

  test "literals" do
    query = "schema" |> where(foo: true) |> select([], true)
    # TODO is true?
    assert all(query) == ~s{SELECT true FROM "schema" AS s0 WHERE (s0."foo" = 1)}

    query = "schema" |> where(foo: false) |> select([], true)
    assert all(query) == ~s{SELECT true FROM "schema" AS s0 WHERE (s0."foo" = 0)}

    query = "schema" |> where(foo: "abc") |> select([], true)
    assert all(query) == ~s{SELECT true FROM "schema" AS s0 WHERE (s0."foo" = 'abc')}

    query = "schema" |> where(foo: 123) |> select([], true)
    assert all(query) == ~s{SELECT true FROM "schema" AS s0 WHERE (s0."foo" = 123)}

    query = "schema" |> where(foo: 123.0) |> select([], true)

    assert all(query) ==
             ~s{SELECT true FROM "schema" AS s0 WHERE (s0."foo" = 123.0)}

    name = "y"

    query =
      "schema"
      |> where(fragment("? = ?", literal(^name), "Main"))
      |> select([], true)

    assert all(query) == ~s|SELECT true FROM "schema" AS s0 WHERE ("y" = 'Main')|
  end

  test "selected_as" do
    query = from(s in "schema", select: %{y: selected_as(s.y, :y2)})
    assert all(query) == ~s[SELECT s0."y" AS "y2" FROM "schema" AS s0]
  end

  test "tagged type" do
    query = Schema |> select([], type(^"601d74e4-a8d3-4b6e-8365-eddb4c893327", Ecto.UUID))
    assert all(query) == ~s[SELECT CAST({$0:String} AS UUID) FROM "schema" AS s0]
  end

  test "tagged :any type doesn't add CAST(...) call" do
    query = from e in "events", select: type(e.count + 1, e.some_column)
    assert all(query) == ~s[SELECT e0."count" + 1 FROM "events" AS e0]

    query = from e in "events", select: type(e.count + 1, :any)
    assert all(query) == ~s[SELECT e0."count" + 1 FROM "events" AS e0]
  end

  test "tagged column type" do
    query = from s in Schema, select: type(s.x + 1, s.y)
    assert all(query) == ~s[SELECT CAST(s0."x" + 1 AS UInt16) FROM "schema" AS s0]
  end

  test "tagged unknown type" do
    query = from e in "events", select: type(e.count + 1, :time)

    assert_raise Ecto.QueryError,
                 ~r/unknown or ambiguous \(for ClickHouse\) Ecto type :time in query/,
                 fn -> all(query) end

    query = from e in "events", select: type(e.count + 1, :decimal)

    assert_raise Ecto.QueryError,
                 ~r/unknown or ambiguous \(for ClickHouse\) Ecto type :decimal in query/,
                 fn -> all(query) end
  end

  # TODO tautology?
  test "string type" do
    query = Schema |> select([], type(^"test", :string))
    assert all(query) == ~s[SELECT CAST({$0:String} AS String) FROM "schema" AS s0]
  end

  test "json_extract_path" do
    query = Schema |> select([s], json_extract_path(s.meta, [0, 1]))
    assert all(query) == ~s{SELECT JSON_QUERY(s0."meta", '$[0][1]') FROM "schema" AS s0}

    query = Schema |> select([s], json_extract_path(s.meta, ["a", "b"]))
    assert all(query) == ~s{SELECT JSON_QUERY(s0."meta", '$.a.b') FROM "schema" AS s0}

    query = Schema |> select([s], json_extract_path(s.meta, ["'a"]))
    assert all(query) == ~s{SELECT JSON_QUERY(s0."meta", '$.''a') FROM "schema" AS s0}

    query = Schema |> select([s], json_extract_path(s.meta, ["\"a"]))
    assert all(query) == ~s{SELECT JSON_QUERY(s0."meta", '$.\\"a') FROM "schema" AS s0}

    query = Schema |> select([s], s.meta["author"]["name"])
    assert all(query) == ~s{SELECT JSON_QUERY(s0."meta", '$.author.name') FROM "schema" AS s0}
  end

  test "nested expressions" do
    z = 123

    query =
      (r in Schema)
      |> from([])
      |> select([r], (r.x > 0 and r.y > ^(-z)) or true)

    assert all(query) ==
             ~s[SELECT ((s0."x" > 0) AND (s0."y" > {$0:Int64})) OR 1 FROM "schema" AS s0]
  end

  test "in expression" do
    query = Schema |> select([e], 1 in [1, e.x, 3])
    assert all(query) == ~s[SELECT 1 IN (1,s0."x",3) FROM "schema" AS s0]

    query = Schema |> select([e], 1 in ^[])
    assert all(query) == ~s[SELECT 0 FROM "schema" AS s0]

    query = Schema |> select([e], 1 in ^[1, 2, 3])
    assert all(query) == ~s[SELECT 1 IN ({$0:Int64},{$1:Int64},{$2:Int64}) FROM "schema" AS s0]

    query = Schema |> select([e], 1 in [1, ^2, 3])
    assert all(query) == ~s[SELECT 1 IN (1,{$0:Int64},3) FROM "schema" AS s0]

    query = Schema |> select([e], e.x == ^0 or e.x in ^[1, 2, 3] or e.x == ^4)

    assert all(query) ==
             ~s[SELECT (s0."x" = {$0:Int64}) OR (s0."x" IN ({$1:Int64},{$2:Int64},{$3:Int64})) OR (s0."x" = {$4:Int64}) FROM "schema" AS s0]

    query = Schema |> select([e], e in [1, 2, 3])

    assert all(query) ==
             ~s|SELECT s0 IN (1,2,3) FROM "schema" AS s0|
  end

  test "in subquery" do
    posts =
      "posts"
      |> where(title: ^"hello")
      |> select([p], p.id)
      |> subquery()

    query =
      "comments"
      |> where([c], c.post_id in subquery(posts))
      |> select([c], c.x)

    assert all(query) ==
             """
             SELECT c0."x" FROM "comments" AS c0 \
             WHERE (c0."post_id" IN (SELECT sp0."id" FROM "posts" AS sp0 WHERE (sp0."title" = {$0:String})))\
             """

    posts =
      "posts"
      |> where(title: parent_as(:comment).subtitle)
      |> select([p], p.id)
      |> subquery()

    query =
      "comments"
      |> from(as: :comment)
      |> where([c], c.post_id in subquery(posts))
      |> select([c], c.x)

    assert all(query) ==
             """
             SELECT c0."x" FROM "comments" AS c0 \
             WHERE (c0."post_id" IN (SELECT sp0."id" FROM "posts" AS sp0 WHERE (sp0."title" = c0."subtitle")))\
             """
  end

  test "having" do
    query =
      Schema
      |> having([p], p.x == p.x)
      |> select([p], p.x)

    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 HAVING (s0."x" = s0."x")}

    query =
      Schema
      |> having([p], p.x == p.x)
      |> having([p], p.y == p.y)
      |> select([p], [p.y, p.x])

    assert all(query) ==
             """
             SELECT s0."y",s0."x" \
             FROM "schema" AS s0 \
             HAVING (s0."x" = s0."x") \
             AND (s0."y" = s0."y")\
             """
  end

  test "or_having" do
    query =
      Schema
      |> or_having([p], p.x == p.x)
      |> select([p], p.x)

    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 HAVING (s0."x" = s0."x")}

    query =
      Schema
      |> or_having([p], p.x == p.x)
      |> or_having([p], p.y == p.y)
      |> select([p], [p.y, p.x])

    assert all(query) ==
             """
             SELECT s0."y",s0."x" \
             FROM "schema" AS s0 \
             HAVING (s0."x" = s0."x") \
             OR (s0."y" = s0."y")\
             """
  end

  test "group by" do
    query =
      Schema
      |> group_by([r], r.x)
      |> select([r], r.x)

    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 GROUP BY s0."x"}

    query =
      Schema
      |> group_by([r], 2)
      |> select([r], r.x)

    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 GROUP BY 2}

    query =
      Schema
      |> group_by([r], [r.x, r.y])
      |> select([r], r.x)

    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0 GROUP BY s0."x",s0."y"}

    query =
      Schema
      |> group_by([r], [])
      |> select([r], r.x)

    assert all(query) == ~s{SELECT s0."x" FROM "schema" AS s0}
  end

  test "interpolated values" do
    cte1 =
      "schema1"
      |> select([m], %{id: m.id, smth: ^true})
      |> where([], fragment("?", ^1))

    union =
      "schema1"
      |> select([m], {m.id, ^true})
      |> where([], fragment("?", ^5))

    union_all =
      "schema2"
      |> select([m], {m.id, ^false})
      |> where([], fragment("?", ^6))

    query =
      Schema
      |> with_cte("cte1", as: ^cte1)
      |> with_cte("cte2", as: fragment("SELECT * FROM schema WHERE ?", ^2))
      |> select([m], {m.id, ^0})
      |> join(:inner, [], Schema2, on: fragment("?", ^true))
      |> join(:inner, [], Schema2, on: fragment("?", ^false))
      |> where([], fragment("?", ^true))
      |> where([], fragment("?", ^false))
      |> having([], fragment("?", ^true))
      |> having([], fragment("?", ^false))
      |> group_by([], fragment("?", ^3))
      |> group_by([], fragment("?", ^4))
      |> union(^union)
      |> union_all(^union_all)
      |> order_by([], fragment("?", ^7))
      |> limit([], ^8)
      |> offset([], ^9)

    assert all(query) ==
             """
             WITH \
             "cte1" AS (\
             SELECT ss0."id" AS "id",{$0:Bool} AS "smth" FROM "schema1" AS ss0 \
             WHERE ({$1:Int64})\
             ),\
             "cte2" AS (\
             SELECT * FROM schema WHERE {$2:Int64}\
             ) \
             SELECT s0."id",{$3:Int64} FROM "schema" AS s0 \
             INNER JOIN "schema2" AS s1 ON {$4:Bool} \
             INNER JOIN "schema2" AS s2 ON {$5:Bool} \
             WHERE ({$6:Bool}) AND ({$7:Bool}) \
             GROUP BY {$8:Int64},{$9:Int64} \
             HAVING ({$10:Bool}) AND ({$11:Bool}) \
             ORDER BY {$16:Int64} \
             LIMIT {$17:Int64} \
             OFFSET {$18:Int64} \
             UNION DISTINCT \
             (SELECT s0."id",{$12:Bool} FROM "schema1" AS s0 \
             WHERE ({$13:Int64})) \
             UNION ALL \
             (SELECT s0."id",{$14:Bool} FROM "schema2" AS s0 \
             WHERE ({$15:Int64}))\
             """
  end

  test "fragments allow ? to be escaped with backslash" do
    query =
      (e in "schema")
      |> from(
        where: fragment(~s|? = "query\\?"|, e.start_time),
        select: true
      )

    assert all(query) == ~s|SELECT true FROM "schema" AS s0 WHERE (s0."start_time" = "query?")|
  end

  test "update_all" do
    error_message =
      ~r/ClickHouse does not support UPDATE statements -- use ALTER TABLE ... UPDATE instead/

    query =
      (m in Schema)
      |> from(update: [set: [x: 0]])

    assert_raise Ecto.QueryError, error_message, fn ->
      update_all(query)
    end

    query =
      (m in Schema)
      |> from(update: [set: [x: 0], inc: [y: 1, z: -3]])

    assert_raise Ecto.QueryError, error_message, fn ->
      update_all(query)
    end

    query =
      (e in Schema)
      |> from(where: e.x == 123, update: [set: [x: 0]])

    assert_raise Ecto.QueryError, error_message, fn ->
      update_all(query)
    end

    query =
      (m in Schema)
      |> from(update: [set: [x: ^0]])

    assert_raise Ecto.QueryError, error_message, fn ->
      update_all(query)
    end

    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> update([_], set: [x: 0])

    assert_raise Ecto.QueryError, error_message, fn ->
      update_all(query)
    end

    query =
      (e in Schema)
      |> from(
        where: e.x == 123,
        update: [set: [x: 0]],
        join: q in Schema2,
        on: e.x == q.z
      )

    assert_raise Ecto.QueryError, error_message, fn ->
      update_all(query)
    end

    query =
      from(
        p in Post,
        where: p.title == ^"foo",
        select: p.content,
        update: [set: [title: "bar"]]
      )

    assert_raise Ecto.QueryError, error_message, fn ->
      update_all(query)
    end
  end

  test "update_all with prefix" do
    query =
      (m in Schema)
      |> from(update: [set: [x: 0]])
      |> Map.put(:prefix, "prefix")

    assert_raise Ecto.QueryError, fn ->
      update_all(query)
    end

    query =
      (m in Schema)
      |> from(prefix: "first", update: [set: [x: 0]])
      |> Map.put(:prefix, "prefix")

    assert_raise Ecto.QueryError, fn ->
      update_all(query)
    end
  end

  test "update all with returning" do
    query =
      from(p in Post, update: [set: [title: "foo"]])
      |> select([p], p)

    assert_raise Ecto.QueryError, fn ->
      update_all(query)
    end

    query =
      from(m in Schema, update: [set: [x: ^1]])
      |> where([m], m.x == ^2)
      |> select([m], m.x == ^3)

    assert_raise Ecto.QueryError, fn ->
      update_all(query)
    end
  end

  test "alter_update_all" do
    assert alter_update_all(from m in Schema, update: [set: [x: 0]]) ==
             """
             ALTER TABLE "schema" UPDATE "x"=0 WHERE 1\
             """

    assert alter_update_all(from m in Schema, update: [set: [x: 0], inc: [y: 1, z: -3]]) == """
           ALTER TABLE "schema" UPDATE "x"=0,"y"="y"+1,"z"="z"+-3 WHERE 1\
           """

    assert alter_update_all(from e in Schema, where: e.x == 123, update: [set: [x: 0]]) == """
           ALTER TABLE "schema" UPDATE "x"=0 WHERE ("x" = 123)\
           """

    assert alter_update_all(from m in Schema, update: [set: [x: ^0]]) == """
           ALTER TABLE "schema" UPDATE "x"={$0:Int64} WHERE 1\
           """

    assert alter_update_all(from e in "events", update: [push: [tags: "cool"]]) == """
           ALTER TABLE "events" UPDATE "tags"=arrayPushBack("tags",'cool') WHERE 1\
           """

    assert alter_update_all(from e in "events", update: [push: [tags: ^"cool"]]) == """
           ALTER TABLE "events" UPDATE "tags"=arrayPushBack("tags",{$0:String}) WHERE 1\
           """

    assert alter_update_all(from e in "events", update: [pull: [tags: "not cool"]]) == """
           ALTER TABLE "events" UPDATE "tags"=arrayFilter(x->x!='not cool',"tags") WHERE 1\
           """

    assert alter_update_all(from e in "events", update: [pull: [tags: ^"not cool"]]) == """
           ALTER TABLE "events" UPDATE "tags"=arrayFilter(x->x!={$0:String},"tags") WHERE 1\
           """

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support JOIN in ALTER TABLE ... UPDATE statements/,
                 fn ->
                   Schema
                   |> join(:inner, [p], q in Schema2, on: p.x == q.z)
                   |> update([_], set: [x: 0])
                   |> alter_update_all()
                 end

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support JOIN in ALTER TABLE ... UPDATE statements/,
                 fn ->
                   alter_update_all(
                     from e in Schema,
                       where: e.x == 123,
                       update: [set: [x: 0]],
                       join: q in Schema2,
                       on: e.x == q.z
                   )
                 end

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support RETURNING in ALTER TABLE ... UPDATE statements/,
                 fn ->
                   alter_update_all(
                     from p in Post,
                       where: p.title == ^"foo",
                       select: p.content,
                       update: [set: [title: "bar"]]
                   )
                 end
  end

  test "alter_update_all with prefix" do
    assert alter_update_all(
             (m in Schema)
             |> from(update: [set: [x: 0]])
             |> Map.put(:prefix, "prefix")
           ) == """
           ALTER TABLE "prefix"."schema" UPDATE "x"=0 WHERE 1\
           """

    assert alter_update_all(
             (m in Schema)
             |> from(prefix: "first", update: [set: [x: 0]])
             |> Map.put(:prefix, "prefix")
           ) == """
           ALTER TABLE "first"."schema" UPDATE "x"=0 WHERE 1\
           """
  end

  test "alter_update_all with returning" do
    assert_raise Ecto.QueryError, fn ->
      from(p in Post, update: [set: [title: "foo"]])
      |> select([p], p)
      |> alter_update_all()
    end

    assert_raise Ecto.QueryError, fn ->
      from(m in Schema, update: [set: [x: ^1]])
      |> where([m], m.x == ^2)
      |> select([m], m.x == ^3)
      |> alter_update_all()
    end
  end

  test "delete_all" do
    assert delete_all(Schema) == ~s{DELETE FROM "schema" WHERE 1}

    query = from(e in Schema, where: e.x == 123)
    assert delete_all(query) == ~s{DELETE FROM "schema" WHERE ("x" = 123)}

    query = from(e in Schema, where: e.x == ^123)
    assert delete_all(query) == ~s[DELETE FROM "schema" WHERE ("x" = {$0:Int64})]

    query = from(e in Schema, where: e.x == 123, select: e.x)

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support RETURNING on DELETE statements/,
                 fn -> delete_all(query) end
  end

  test "delete all with returning" do
    query = Post |> Ecto.Queryable.to_query() |> select([m], m)

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support RETURNING on DELETE statements/,
                 fn -> delete_all(query) end
  end

  test "delete all with prefix" do
    query =
      Schema
      |> Ecto.Queryable.to_query()
      |> Map.put(:prefix, "prefix")

    assert delete_all(query) == ~s{DELETE FROM "prefix"."schema" WHERE 1}

    query =
      Schema
      |> from(prefix: "first")
      |> Map.put(:prefix, "prefix")

    assert delete_all(query) == ~s{DELETE FROM "first"."schema" WHERE 1}
  end

  test "CTE alter_update_all" do
    cte_query =
      from(x in Schema,
        order_by: [asc: :id],
        limit: 10,
        lock: "FOR UPDATE SKIP LOCKED",
        select: %{id: x.id}
      )

    query =
      Schema
      |> with_cte("target_rows", as: ^cte_query)
      |> update(set: [x: 123])

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support CTEs in ALTER TABLE ... UPDATE statements/,
                 fn -> alter_update_all(query) end
  end

  test "returning alter_update_all" do
    query =
      Schema
      |> select([r, t], r)
      |> update(set: [x: 123])

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support RETURNING in ALTER TABLE ... UPDATE statements/,
                 fn -> alter_update_all(query) end
  end

  test "join alter_update_all" do
    query =
      Schema
      |> join(:inner, [s], e in "events", on: s.id == e.event_id)
      |> update(set: [x: 123])

    assert_raise Ecto.QueryError,
                 ~r/ClickHouse does not support JOIN in ALTER TABLE ... UPDATE statements/,
                 fn -> alter_update_all(query) end
  end

  # TODO alter_delete_all

  describe "windows" do
    test "one window" do
      query =
        Schema
        |> select([r], r.x)
        |> windows([r], w: [partition_by: r.x])

      assert all(query) ==
               """
               SELECT s0."x" \
               FROM "schema" AS s0 WINDOW "w" AS (PARTITION BY s0."x")\
               """
    end

    test "two windows" do
      query =
        Schema
        |> select([r], r.x)
        |> windows([r], w1: [partition_by: r.x], w2: [partition_by: r.y])

      assert all(query) ==
               """
               SELECT s0."x" \
               FROM "schema" AS s0 WINDOW "w1" AS (PARTITION BY s0."x"),\
               "w2" AS (PARTITION BY s0."y")\
               """
    end

    test "count over window" do
      query =
        Schema
        |> windows([r], w: [partition_by: r.x])
        |> select([r], count(r.x) |> over(:w))

      assert all(query) ==
               """
               SELECT count(s0."x") OVER "w" \
               FROM "schema" AS s0 WINDOW "w" AS (PARTITION BY s0."x")\
               """
    end

    test "count over all" do
      query =
        Schema
        |> select([r], count(r.x) |> over)

      assert all(query) == ~s{SELECT count(s0."x") OVER () FROM "schema" AS s0}
    end

    test "row_number over all" do
      query =
        Schema
        |> select(row_number |> over)

      assert all(query) == ~s{SELECT row_number() OVER () FROM "schema" AS s0}
    end

    test "nth_value over all" do
      query =
        Schema
        |> select([r], nth_value(r.x, 42) |> over)

      assert all(query) ==
               """
               SELECT nth_value(s0."x",42) OVER () \
               FROM "schema" AS s0\
               """
    end

    test "lag/2 over all" do
      query =
        Schema
        |> select([r], lag(r.x, 42) |> over)

      assert all(query) == ~s{SELECT lag(s0."x",42) OVER () FROM "schema" AS s0}
    end

    test "custom aggregation over all" do
      query =
        Schema
        |> select([r], fragment("custom_function(?)", r.x) |> over)

      assert all(query) ==
               """
               SELECT custom_function(s0."x") OVER () \
               FROM "schema" AS s0\
               """
    end

    test "partition by and order by on window" do
      query =
        Schema
        |> windows([r], w: [partition_by: [r.x, r.z], order_by: r.x])
        |> select([r], r.x)

      assert all(query) ==
               """
               SELECT s0."x" \
               FROM "schema" AS s0 WINDOW "w" AS (PARTITION BY s0."x",s0."z" ORDER BY s0."x")\
               """
    end

    test "partition by and order by on over" do
      query =
        Schema
        |> select([r], count(r.x) |> over(partition_by: [r.x, r.z], order_by: r.x))

      assert all(query) ==
               """
               SELECT count(s0."x") OVER (PARTITION BY s0."x",s0."z" ORDER BY s0."x") \
               FROM "schema" AS s0\
               """
    end

    test "frame clause" do
      query =
        Schema
        |> select(
          [r],
          count(r.x)
          |> over(
            partition_by: [r.x, r.z],
            order_by: r.x,
            frame: fragment("ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING")
          )
        )

      assert all(query) ==
               """
               SELECT count(s0."x") OVER (\
               PARTITION BY s0."x",\
               s0."z" \
               ORDER BY s0."x" \
               ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING\
               ) \
               FROM "schema" AS s0\
               """
    end
  end

  test "join" do
    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> select([], true)

    assert all(query) ==
             """
             SELECT true \
             FROM "schema" AS s0 \
             INNER JOIN "schema2" AS s1 ON s0."x" = s1."z"\
             """

    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> join(:inner, [], Schema, on: true)
      |> select([], true)

    assert all(query) ==
             """
             SELECT true FROM "schema" AS s0 INNER JOIN "schema2" AS s1 ON s0."x" = s1."z" \
             INNER JOIN "schema" AS s2 ON 1\
             """
  end

  @tag :capture_log
  test "array join" do
    assert all(
             from at in "arrays_test",
               join: a in "arr",
               on: true,
               hints: "ARRAY",
               select: [at.s, a]
           ) ==
             """
             SELECT a0."s",a1 FROM "arrays_test" AS a0 ARRAY JOIN "arr" AS a1\
             """
  end

  @tag :capture_log
  test "left array join" do
    assert all(
             from at in "arrays_test",
               left_join: a in "arr",
               on: true,
               hints: "ARRAY",
               select: [at.s, a]
           ) ==
             """
             SELECT a0."s",a1 FROM "arrays_test" AS a0 LEFT ARRAY JOIN "arr" AS a1\
             """
  end

  test "join with nothing bound" do
    query =
      Schema
      |> join(:inner, [], q in Schema2, on: q.z == q.z)
      |> select([], true)

    assert all(query) ==
             """
             SELECT true \
             FROM "schema" AS s0 \
             INNER JOIN "schema2" AS s1 ON s1."z" = s1."z"\
             """
  end

  test "join without schema" do
    query =
      "posts"
      |> join(:inner, [p], q in "comments", on: p.x == q.z)
      |> select([], true)

    assert all(query) ==
             """
             SELECT true \
             FROM "posts" AS p0 \
             INNER JOIN "comments" AS c1 ON p0."x" = c1."z"\
             """
  end

  test "join with subquery" do
    posts =
      "posts"
      |> where(title: ^"hello")
      |> select([r], %{x: r.x, y: r.y})
      |> subquery()

    query =
      "comments"
      |> join(:inner, [c], p in subquery(posts), on: true)
      |> select([_, p], p.x)

    assert all(query) ==
             """
             SELECT s1."x" FROM "comments" AS c0 \
             INNER JOIN (\
             SELECT sp0."x" AS "x",sp0."y" AS "y" \
             FROM "posts" AS sp0 \
             WHERE (sp0."title" = {$0:String})\
             ) AS s1 ON 1\
             """

    posts =
      "posts"
      |> where(title: ^"hello")
      |> select([r], %{x: r.x, z: r.y})
      |> subquery()

    query =
      "comments"
      |> join(:inner, [c], p in subquery(posts), on: true)
      |> select([_, p], p)

    assert all(query) ==
             """
             SELECT s1."x",s1."z" FROM "comments" AS c0 \
             INNER JOIN (\
             SELECT sp0."x" AS "x",sp0."y" AS "z" \
             FROM "posts" AS sp0 \
             WHERE (sp0."title" = {$0:String})\
             ) AS s1 ON 1\
             """

    posts =
      "posts"
      |> where(title: parent_as(:comment).subtitle)
      |> select([r], r.title)
      |> subquery()

    query =
      "comments"
      |> from(as: :comment)
      |> join(:inner, [c], p in subquery(posts), on: true)
      |> select([_, p], p)

    assert all(query) ==
             """
             SELECT s1."title" \
             FROM "comments" AS c0 \
             INNER JOIN (\
             SELECT sp0."title" AS "title" \
             FROM "posts" AS sp0 \
             WHERE (sp0."title" = c0."subtitle")\
             ) AS s1 ON 1\
             """
  end

  test "join with prefix" do
    query =
      Schema
      |> join(:inner, [p], q in Schema2, on: p.x == q.z)
      |> select([], true)
      |> Map.put(:prefix, "prefix")

    assert all(query) ==
             """
             SELECT true \
             FROM "prefix"."schema" AS s0 \
             INNER JOIN "prefix"."schema2" AS s1 ON s0."x" = s1."z"\
             """

    query =
      Schema
      |> from(prefix: "first")
      |> join(:inner, [p], q in Schema2, on: p.x == q.z, prefix: "second")
      |> select([], true)
      |> Map.put(:prefix, "prefix")

    assert all(query) ==
             """
             SELECT true \
             FROM "first"."schema" AS s0 \
             INNER JOIN "second"."schema2" AS s1 ON s0."x" = s1."z"\
             """
  end

  test "join with fragment" do
    query =
      Schema
      |> join(
        :inner,
        [p],
        q in fragment(
          "SELECT * FROM schema2 AS s2 WHERE s2.id = ? AND s2.field = ?",
          p.x,
          ^10
        ),
        on: true
      )
      |> select([p], {p.id, ^0})
      |> where([p], p.id > 0 and p.id < ^100)

    # TODO ON true?

    assert all(query) ==
             """
             SELECT s0."id",{$0:Int64} \
             FROM "schema" AS s0 \
             INNER JOIN \
             (\
             SELECT * \
             FROM schema2 AS s2 \
             WHERE s2.id = s0."x" AND s2.field = {$1:Int64}\
             ) AS f1 ON 1 \
             WHERE ((s0."id" > 0) AND (s0."id" < {$2:Int64}))\
             """
  end

  test "join with fragment and on defined" do
    query =
      Schema
      |> join(:inner, [p], q in fragment("SELECT * FROM schema2"), on: q.id == p.id)
      |> select([p], {p.id, ^0})

    assert all(query) ==
             """
             SELECT s0."id",{$0:Int64} \
             FROM "schema" AS s0 \
             INNER JOIN \
             (SELECT * FROM schema2) AS f1 ON f1."id" = s0."id"\
             """
  end

  test "join with query interpolation" do
    inner = Ecto.Queryable.to_query(Schema2)

    query =
      (p in Schema)
      |> from(left_join: c in ^inner, on: true, select: {p.id, c.id})

    assert all(query) ==
             """
             SELECT s0."id",s1."id" \
             FROM "schema" AS s0 \
             LEFT JOIN "schema2" AS s1 ON 1\
             """
  end

  test "cross join" do
    query =
      (p in Schema)
      |> from(cross_join: c in Schema2, select: {p.id, c.id})

    assert all(query) ==
             """
             SELECT s0."id",s1."id" \
             FROM "schema" AS s0 \
             CROSS JOIN "schema2" AS s1\
             """
  end

  test "join produces correct bindings" do
    query = from(p in Schema, join: c in Schema2, on: true)
    query = from(p in query, join: c in Schema2, on: true, select: {p.id, c.id})

    assert all(query) ==
             """
             SELECT s0."id",s2."id" \
             FROM "schema" AS s0 \
             INNER JOIN "schema2" AS s1 ON 1 \
             INNER JOIN "schema2" AS s2 ON 1\
             """
  end

  describe "query interpolation parameters" do
    test "self join on subquery" do
      subquery = select(Schema, [r], %{x: r.x, y: r.y})

      query =
        subquery
        |> join(:inner, [c], p in subquery(subquery), on: true)

      assert all(query) ==
               """
               SELECT s0."x",s0."y" \
               FROM "schema" AS s0 \
               INNER JOIN (SELECT ss0."x" AS "x",ss0."y" AS "y" FROM "schema" AS ss0) \
               AS s1 ON 1\
               """
    end

    test "self join on subquery with fragment" do
      subquery = select(Schema, [r], %{string: fragment("lower(?)", ^"string")})

      query =
        subquery
        |> join(:inner, [c], p in subquery(subquery), on: true)

      assert all(query) ==
               """
               SELECT lower({$0:String}) \
               FROM "schema" AS s0 \
               INNER JOIN (SELECT lower({$1:String}) AS "string" FROM "schema" AS ss0) \
               AS s1 ON 1\
               """
    end

    test "join on subquery with simple select" do
      subquery = select(Schema, [r], %{x: ^999, w: ^888})

      query =
        Schema
        |> select([r], %{y: ^666})
        |> join(:inner, [c], p in subquery(subquery), on: true)
        |> where([a, b], a.x == ^111)

      assert all(query) ==
               """
               SELECT {$0:Int64} \
               FROM "schema" AS s0 \
               INNER JOIN (SELECT {$1:Int64} AS "x",{$2:Int64} AS "w" FROM "schema" AS ss0) AS s1 ON 1 \
               WHERE (s0."x" = {$3:Int64})\
               """
    end
  end

  test "association join belongs_to" do
    query =
      Schema2
      |> join(:inner, [c], p in assoc(c, :post))
      |> select([], true)

    assert all(query) ==
             """
             SELECT true \
             FROM "schema2" AS s0 \
             INNER JOIN "schema" AS s1 ON s1."x" = s0."z"\
             """
  end

  test "association join has_many" do
    query =
      Schema
      |> join(:inner, [p], c in assoc(p, :comments))
      |> select([], true)

    assert all(query) ==
             """
             SELECT true \
             FROM "schema" AS s0 \
             INNER JOIN "schema2" AS s1 ON s1."z" = s0."x"\
             """
  end

  test "association join has_one" do
    query =
      Schema
      |> join(:inner, [p], pp in assoc(p, :permalink))
      |> select([], true)

    assert all(query) ==
             """
             SELECT true \
             FROM "schema" AS s0 \
             INNER JOIN "schema3" AS s1 ON s1."id" = s0."y"\
             """
  end

  describe "clickhouse joins blog" do
    # https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1#inner-join
    test "INNER JOIN" do
      assert all(
               from m in "movies",
                 inner_join: g in "genres",
                 on: m.id == g.movie_id,
                 order_by: [desc: m.year, asc: m.name, asc: g.genre],
                 limit: 10,
                 select: [selected_as(m.name, :name), selected_as(g.genre, :genre)]
             ) == """
             SELECT m0."name" AS "name",g1."genre" AS "genre" \
             FROM "movies" AS m0 \
             INNER JOIN "genres" AS g1 ON m0."id" = g1."movie_id" \
             ORDER BY m0."year" DESC,m0."name",g1."genre" \
             LIMIT 10\
             """
    end

    # https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1#left--right--full-outer-join
    test "(LEFT / RIGHT / FULL) OUTER JOIN" do
      assert all(
               from m in "movies",
                 left_join: g in "genres",
                 on: m.id == g.movie_id,
                 where: g.movie_id == 0,
                 order_by: [desc: m.year, asc: m.name],
                 limit: 10,
                 select: m.name
             ) == """
             SELECT m0."name" \
             FROM "movies" AS m0 \
             LEFT JOIN "genres" AS g1 ON m0."id" = g1."movie_id" \
             WHERE (g1."movie_id" = 0) \
             ORDER BY m0."year" DESC,m0."name" \
             LIMIT 10\
             """
    end

    # https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1#cross-join
    test "CROSS JOIN" do
      assert all(
               from m in "movies",
                 cross_join: g in "genres",
                 limit: 10,
                 select: [m.name, m.id, g.movie_id, g.genre]
             ) == """
             SELECT m0."name",m0."id",g1."movie_id",g1."genre" \
             FROM "movies" AS m0 \
             CROSS JOIN "genres" AS g1 \
             LIMIT 10\
             """
    end

    # https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1#left--right-semi-join
    test "(LEFT / RIGHT) SEMI JOIN" do
      assert all(
               from a in "actors",
                 left_join: r in "roles",
                 on: a.id == r.actor_id,
                 hints: "SEMI",
                 where: fragment("toYear(created_at)") == "2023",
                 order_by: [asc: :id],
                 limit: 10,
                 select: [a.first_name, a.last_name]
             ) == """
             SELECT a0."first_name",a0."last_name" \
             FROM "actors" AS a0 \
             SEMI LEFT JOIN "roles" AS r1 ON a0."id" = r1."actor_id" \
             WHERE (toYear(created_at) = '2023') \
             ORDER BY a0."id" \
             LIMIT 10\
             """
    end

    # https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1#left--right-anti-join
    test "(LEFT / RIGHT) ANTI JOIN" do
      assert all(
               from m in "movies",
                 left_join: g in "genres",
                 on: m.id == g.movie_id,
                 hints: "ANTI",
                 order_by: [desc: :year, asc: :name],
                 limit: 10,
                 select: m.name
             ) == """
             SELECT m0."name" \
             FROM "movies" AS m0 \
             ANTI LEFT JOIN "genres" AS g1 ON m0."id" = g1."movie_id" \
             ORDER BY m0."year" DESC,m0."name" \
             LIMIT 10\
             """
    end

    # https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1#left--right--inner-any-join
    test "(LEFT / RIGHT / INNER) ANY JOIN" do
      left_table = from v in fragment("VALUES('c UInt32', 1, 2, 3)"), select: v.c
      right_table = from v in fragment("VALUES('c UInt32', 2, 2, 3, 3, 4)"), select: v.c

      query =
        "left_table"
        |> with_cte("left_table", as: ^left_table)
        |> with_cte("right_table", as: ^right_table)

      assert all(
               from l in query,
                 left_join: r in "right_table",
                 on: l.c == r.c,
                 hints: "ANY",
                 select: [selected_as(l.c, :l_c), selected_as(r.c, :r_c)]
             ) == """
             WITH \
             "left_table" AS (SELECT sf0."c" AS "c" FROM VALUES('c UInt32', 1, 2, 3) AS sf0),\
             "right_table" AS (SELECT sf0."c" AS "c" FROM VALUES('c UInt32', 2, 2, 3, 3, 4) AS sf0) \
             SELECT l0."c" AS "l_c",r1."c" AS "r_c" \
             FROM "left_table" AS l0 \
             ANY LEFT JOIN "right_table" AS r1 ON l0."c" = r1."c"\
             """

      assert all(
               from l in query,
                 right_join: r in "right_table",
                 on: l.c == r.c,
                 hints: "ANY",
                 select: [selected_as(l.c, :l_c), selected_as(r.c, :r_c)]
             ) == """
             WITH \
             "left_table" AS (SELECT sf0."c" AS "c" FROM VALUES('c UInt32', 1, 2, 3) AS sf0),\
             "right_table" AS (SELECT sf0."c" AS "c" FROM VALUES('c UInt32', 2, 2, 3, 3, 4) AS sf0) \
             SELECT l0."c" AS "l_c",r1."c" AS "r_c" \
             FROM "left_table" AS l0 \
             ANY RIGHT JOIN "right_table" AS r1 ON l0."c" = r1."c"\
             """

      assert all(
               from l in query,
                 inner_join: r in "right_table",
                 on: l.c == r.c,
                 hints: "ANY",
                 select: [selected_as(l.c, :l_c), selected_as(r.c, :r_c)]
             ) == """
             WITH \
             "left_table" AS (SELECT sf0."c" AS "c" FROM VALUES('c UInt32', 1, 2, 3) AS sf0),\
             "right_table" AS (SELECT sf0."c" AS "c" FROM VALUES('c UInt32', 2, 2, 3, 3, 4) AS sf0) \
             SELECT l0."c" AS "l_c",r1."c" AS "r_c" \
             FROM "left_table" AS l0 \
             ANY INNER JOIN "right_table" AS r1 ON l0."c" = r1."c"\
             """
    end

    # https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1#asof-join
    test "ASOF JOIN" do
      assert all(
               from t in "trades",
                 left_join: q in "quotes",
                 on: t.symbol == q.symbol and t.time >= q.time,
                 hints: "ASOF",
                 select: [
                   t.symbol,
                   t.volume,
                   selected_as(t.time, :trade_time),
                   selected_as(q.time, :closest_quote_time),
                   selected_as(q.price, :quote_price),
                   selected_as(t.volume * q.price, :final_price)
                 ]
             ) == """
             SELECT \
             t0."symbol",\
             t0."volume",\
             t0."time" AS "trade_time",\
             q1."time" AS "closest_quote_time",\
             q1."price" AS "quote_price",\
             t0."volume" * q1."price" AS "final_price" \
             FROM "trades" AS t0 \
             ASOF LEFT JOIN "quotes" AS q1 ON (t0."symbol" = q1."symbol") AND (t0."time" >= q1."time")\
             """
    end

    test "invalid type" do
      expected_message =
        ~r/unsupported JOIN strictness or type passed in hints: \["INVALID"\]\nsupported: "ASOF", "ANY", "ANTI", "SEMI", "ARRAY"/

      assert_raise Ecto.QueryError, expected_message, fn ->
        all(
          from t1 in "table_1",
            left_join: t2 in "table_2",
            on: t1.a == t2.b and t2.t <= t1.t,
            hints: "INVALID",
            select: count()
        )
      end
    end
  end

  test "insert" do
    query = insert(nil, "schema", [:x, :y], [[:x, :y]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema"("x","y")}

    query = insert("prefix", "schema", [:x, :y], [[:x, :y]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "prefix"."schema"("x","y")}

    query = insert(nil, "schema", [:x, :y], [[:x, :y], [nil, :z]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema"("x","y")}

    # TODO raise something like "ClickHouse does not support DEFAULT VALUES on INSERT statements" ?
    query = insert(nil, "schema", [], [[]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "schema"}

    query = insert("prefix", "schema", [], [[]], {:raise, [], []}, [])
    assert query == ~s{INSERT INTO "prefix"."schema"}

    assert_raise ArgumentError,
                 "ClickHouse does not support RETURNING on INSERT statements",
                 fn ->
                   insert(nil, "schema", [:x, :y], [[:x, :y]], {:raise, [], []}, [:id])
                 end

    assert_raise ArgumentError,
                 "ClickHouse does not support RETURNING on INSERT statements",
                 fn ->
                   insert(nil, "schema", [:x, :y], [[:x, :y], [nil, :z]], {:raise, [], []}, [:id])
                 end
  end

  test "insert with on_conflict" do
    # since ClickHouse doesn't support on conflict and unique constraints
    # and ecto defaults to :raise (which makes it impossible to know if on_conflict comes from the user or from ecto),
    # on_conflict argument is ignored

    query = insert(nil, "schema", [:x, :y], [[:x, :y]], {:nothing, [], []}, [])
    assert query == ~s{INSERT INTO "schema"("x","y")}

    query = insert(nil, "schema", [:x, :y], [[:x, :y]], {:nothing, [], [:x, :y]}, [])
    assert query == ~s{INSERT INTO "schema"("x","y")}

    conflict_target = []
    query = insert(nil, "schema", [:x, :y], [[:x, :y]], {:replace_all, [], conflict_target}, [])
    assert query == ~s{INSERT INTO "schema"("x","y")}

    query =
      insert(nil, "schema", [:x, :y], [[:x, :y]], {:replace_all, [], {:constraint, :foo}}, [])

    assert query == ~s{INSERT INTO "schema"("x","y")}

    query = insert(nil, "schema", [:x, :y], [[:x, :y]], {:replace_all, [], [:id]}, [])

    assert query == ~s{INSERT INTO "schema"("x","y")}
  end

  # TODO what is that supposed to evaluate to?
  test "insert with query" do
    select_query = from("schema", select: [:id])

    query =
      insert(
        nil,
        "schema",
        [:x, :y, :z],
        [[:x, {select_query, 2}, :z], [nil, nil, {select_query, 1}]],
        {:raise, [], []},
        []
      )

    assert query == ~s{INSERT INTO "schema"("x","y","z")}
  end

  test "insert with query as rows" do
    select =
      from(s in "schema", select: %{foo: fragment("3"), bar: s.bar}, where: true) |> plan(:all)

    insert = insert(nil, "schema", [:foo, :bar], select, {:raise, [], []}, [])

    assert insert ==
             ~s{INSERT INTO "schema"("foo","bar") SELECT 3,s0."bar" FROM "schema" AS s0 WHERE (1)}

    select =
      (s in "schema")
      |> from(select: %{foo: fragment("3"), bar: s.bar})
      |> plan(:all)

    insert = insert(nil, "schema", [:foo, :bar], select, {:raise, [], []}, [])
    assert insert == ~s{INSERT INTO "schema"("foo","bar") SELECT 3,s0."bar" FROM "schema" AS s0}
  end

  test "update" do
    error_message = ~r/ClickHouse does not support UPDATE statements/

    assert_raise ArgumentError, error_message, fn ->
      update(nil, "schema", [:x, :y], [id: 1], [])
    end

    assert_raise ArgumentError, error_message, fn ->
      update(nil, "schema", [:x, :y], [id: 1], [])
    end

    assert_raise ArgumentError, error_message, fn ->
      update("prefix", "schema", [:x, :y], [id: 1], [])
    end
  end

  test "delete" do
    query = delete(nil, "schema", [x: 1, y: 2], [])
    assert query == ~s[DELETE FROM "schema" WHERE "x"={$0:Int64} AND "y"={$1:Int64}]

    query = delete("prefix", "schema", [x: 1, y: 2], [])
    assert query == ~s[DELETE FROM "prefix"."schema" WHERE "x"={$0:Int64} AND "y"={$1:Int64}]

    query = delete(nil, "schema", [x: nil, y: 1], [])
    assert query == ~s[DELETE FROM "schema" WHERE isNull("x") AND "y"={$1:Int64}]
  end

  test "executing a string during migration" do
    assert execute_ddl("example") == ["example"]
  end

  test "create table" do
    create =
      {:create, table(:posts, engine: "MergeTree"),
       [
         {:add, :name, :string, [default: "Untitled", null: false, primary_key: true]},
         {:add, :token, :binary, [null: false]},
         # TODO
         #  {:add, :price, :numeric, [precision: 8, scale: 2, default: {:fragment, "expr"}]},
         {:add, :on_hand, :integer, [default: 0, null: true]},
         {:add, :likes, :integer, [default: 0, null: false]},
         {:add, :published_at, :utc_datetime, [null: true, primary_key: true]},
         {:add, :is_active, :boolean, [default: true]},
         {:add, :notes, :text, []},
         {:add, :meta, :text, []}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" (\
             "name" String DEFAULT 'Untitled' NOT NULL,\
             "token" String NOT NULL,\
             "on_hand" Int32 DEFAULT 0 NULL,\
             "likes" Int32 DEFAULT 0 NOT NULL,\
             "published_at" DateTime NULL,\
             "is_active" Bool DEFAULT 1,\
             "notes" text,\
             "meta" text,\
             PRIMARY KEY ("name","published_at")\
             ) ENGINE=MergeTree\
             """
           ]
  end

  test "create table uses :default_table_engine if set" do
    prev = Application.get_env(:ecto_ch, :default_table_engine)
    :ok = Application.put_env(:ecto_ch, :default_table_engine, "Memory")
    on_exit(fn -> Application.put_env(:ecto_ch, :default_table_engine, prev) end)

    create = {:create, table(:posts), []}
    assert execute_ddl(create) == [~s{CREATE TABLE "posts" () ENGINE=Memory}]
  end

  test "create table uses :default_table_options if set" do
    prev = Application.get_env(:ecto_ch, :default_table_options)

    :ok =
      Application.put_env(:ecto_ch, :default_table_options,
        cluster: "little-giant",
        order_by: "tuple()"
      )

    on_exit(fn -> Application.put_env(:ecto_ch, :default_table_options, prev) end)

    create = {:create, table(:posts), []}

    assert execute_ddl(create) == [
             ~s{CREATE TABLE "posts" ON CLUSTER "little-giant" () ENGINE=TinyLog ORDER BY tuple()}
           ]
  end

  test "create table merged options with :default_table_options" do
    prev = Application.get_env(:ecto_ch, :default_table_options)

    :ok =
      Application.put_env(:ecto_ch, :default_table_options,
        cluster: "little-giant",
        order_by: "tuple()"
      )

    on_exit(fn -> Application.put_env(:ecto_ch, :default_table_options, prev) end)

    create =
      {:create, table(:posts, options: [order_by: "timestamp"]),
       [{:add, :timestamp, :UInt64, []}]}

    assert execute_ddl(create) == [
             ~s{CREATE TABLE "posts" ON CLUSTER "little-giant" ("timestamp" UInt64) ENGINE=TinyLog ORDER BY timestamp}
           ]
  end

  test "create index uses :cluster from :default_table_options" do
    prev = Application.get_env(:ecto_ch, :default_table_options)

    :ok =
      Application.put_env(:ecto_ch, :default_table_options,
        cluster: "little-giant",
        order_by: "tuple()"
      )

    on_exit(fn -> Application.put_env(:ecto_ch, :default_table_options, prev) end)

    create =
      {:create,
       index(:posts, ["lower(permalink)"], options: [type: :bloom_filter, granularity: 8126])}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "posts" ON CLUSTER "little-giant" \
             ADD INDEX "posts_lower_permalink_index" (lower(permalink)) \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]
  end

  test "TinyLog engine is used if :default_table_engine is nil" do
    prev = Application.get_env(:ecto_ch, :default_table_engine)
    :ok = Application.put_env(:ecto_ch, :default_table_engine, nil)
    on_exit(fn -> Application.put_env(:ecto_ch, :default_table_engine, prev) end)

    create = {:create, table(:posts), []}
    assert execute_ddl(create) == [~s{CREATE TABLE "posts" () ENGINE=TinyLog}]
  end

  test "create empty table" do
    create = {:create, table(:posts), []}
    assert execute_ddl(create) == [~s{CREATE TABLE "posts" () ENGINE=TinyLog}]
  end

  test "create table with prefix" do
    create =
      {:create, table(:posts, prefix: :foo),
       [{:add, :name, :string, [default: "Untitled", null: false]}]}

    assert execute_ddl(create) == [
             ~s{CREATE TABLE "foo"."posts" ("name" String DEFAULT 'Untitled' NOT NULL) ENGINE=TinyLog}
           ]

    create =
      {:create, table(:posts, prefix: :foo),
       [{:add, :category_0, %Reference{table: :categories}, []}]}

    assert_raise ArgumentError, "ClickHouse does not support FOREIGN KEY", fn ->
      execute_ddl(create)
    end
  end

  test "create table with serial primary key" do
    create =
      {:create, table(:posts, engine: "MergeTree"),
       [
         {:add, :id, :serial, [primary_key: true]}
       ]}

    assert_raise ArgumentError,
                 "type :serial is not supported as ClickHouse does not support AUTOINCREMENT",
                 fn -> execute_ddl(create) end
  end

  test "create table with references" do
    create =
      {:create, table(:posts),
       [
         {:add, :category_0, %Reference{table: :categories}, []},
         {:add, :category_1, %Reference{table: :categories, name: :foo_bar}, []},
         {:add, :category_2, %Reference{table: :categories, on_delete: :nothing}, []},
         {:add, :category_3, %Reference{table: :categories, on_delete: :delete_all},
          [null: false]},
         {:add, :category_4, %Reference{table: :categories, on_delete: :nilify_all}, []},
         {:add, :category_5, %Reference{table: :categories, prefix: :foo, on_delete: :nilify_all},
          []},
         {:add, :category_6,
          %Reference{table: :categories, with: [here: :there], on_delete: :nilify_all}, []},
         {:add, :category_7,
          %Reference{table: :tags, with: [that: :this], on_delete: :nilify_all}, []}
       ]}

    assert_raise ArgumentError, "ClickHouse does not support FOREIGN KEY", fn ->
      execute_ddl(create)
    end
  end

  test "create table with options" do
    create =
      {:create, table(:posts, engine: "MergeTree", options: "ORDER BY tuple()"),
       [
         {:add, :content, :string, []}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" ("content" String) \
             ENGINE=MergeTree \
             ORDER BY tuple()\
             """
           ]
  end

  test "create table with list as options" do
    assert_raise FunctionClauseError, fn ->
      {:create, table(:posts, options: ["WITH FOO=BAR"]),
       [
         {:add, :created_at, :datetime, []}
       ]}
      |> execute_ddl()
    end
  end

  test "create table with keyword options" do
    create =
      {:create,
       table(:posts,
         engine: "ReplicatedMergeTree",
         options: [
           on_cluster: "cluster-name",
           order_by: "tuple()",
           partition_by: "created_at",
           sample_by: "created_at",
           ttl: "created_at + INTERVAL 12 HOUR",
           settings: "index_granularity = 8192, storage_policy = 'default'"
         ]
       ),
       [
         {:add, :created_at, :datetime, []}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" ON CLUSTER "cluster-name" ("created_at" datetime) \
             ENGINE=ReplicatedMergeTree \
             ORDER BY tuple() \
             PARTITION BY created_at \
             SAMPLE BY created_at \
             TTL created_at + INTERVAL 12 HOUR \
             SETTINGS index_granularity = 8192, storage_policy = 'default'\
             """
           ]
  end

  test "create table with composite key" do
    create =
      {:create, table(:posts, engine: "MergeTree"),
       [
         {:add, :a, :integer, [primary_key: true]},
         {:add, :b, :integer, [primary_key: true]},
         {:add, :name, :string, []}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" (\
             "a" Int32,\
             "b" Int32,\
             "name" String,\
             PRIMARY KEY ("a","b")\
             ) ENGINE=MergeTree\
             """
           ]
  end

  test "create table with a map column, and a map default with values" do
    create =
      {:create, table(:posts),
       [
         {:add, :a, :map, [default: %{foo: "bar", baz: "boom"}]}
       ]}

    assert_raise ArgumentError, ~r/type :map is ambiguous/, fn -> execute_ddl(create) end

    create =
      {:create, table(:posts),
       [
         {:add, :a, :JSON, []}
       ]}

    assert execute_ddl(create) == [
             ~s{CREATE TABLE "posts" ("a" JSON) ENGINE=TinyLog}
           ]

    create =
      {:create, table(:posts),
       [
         {:add, :a, :"Map(String,String)", [default: Ecto.Migration.fragment("Map('foo','bar')")]}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" (\
             "a" Map(String,String) DEFAULT Map('foo','bar')\
             ) ENGINE=TinyLog\
             """
           ]
  end

  test "create table with sql keyword as column name" do
    create = {:create, table(:posts), [{:add, :order, :integer, []}]}

    assert execute_ddl(create) == [
             ~s[CREATE TABLE "posts" ("order" Int32) ENGINE=TinyLog]
           ]
  end

  test "create table with time columns" do
    create =
      {:create, table(:posts),
       [{:add, :published_at, :time, []}, {:add, :submitted_at, :time, []}]}

    assert_raise ArgumentError, "type :time is not supported", fn ->
      execute_ddl(create)
    end
  end

  test "create table with utc_datetime columns" do
    create =
      {:create, table(:posts),
       [
         {:add, :published_at, :utc_datetime_usec, []},
         {:add, :submitted_at, :utc_datetime, []}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" (\
             "published_at" DateTime64(6),\
             "submitted_at" DateTime\
             ) ENGINE=TinyLog\
             """
           ]
  end

  test "create table with naive_datetime columns" do
    create =
      {:create, table(:posts),
       [
         {:add, :published_at, :naive_datetime_usec, []},
         {:add, :submitted_at, :naive_datetime, []}
       ]}

    assert execute_ddl(create) == [
             """
             CREATE TABLE "posts" (\
             "published_at" DateTime64(6),\
             "submitted_at" DateTime\
             ) ENGINE=TinyLog\
             """
           ]
  end

  test "create table with an unsupported type" do
    assert_raise ArgumentError, fn ->
      {:create, table(:posts),
       [
         {:add, :a, {:a, :b, :c}, [default: %{}]}
       ]}
      |> execute_ddl()
    end
  end

  test "drop table" do
    drop = {:drop, table(:posts), :restrict}
    assert execute_ddl(drop) == [~s|DROP TABLE "posts"|]
  end

  test "drop table with options" do
    drop =
      {:drop, table(:posts, options: [on_cluster: "cluster-name", order_by: "tuple()"]),
       :restrict}

    assert execute_ddl(drop) == [~s|DROP TABLE "posts" ON CLUSTER "cluster-name"|]
  end

  test "drop table with prefixes" do
    drop = {:drop, table(:posts, prefix: :foo), :restrict}
    assert execute_ddl(drop) == [~s|DROP TABLE "foo"."posts"|]
  end

  test "drop constraint" do
    drop = {:drop, constraint(:products, "price_must_be_positive", prefix: :foo), :restrict}

    assert execute_ddl(drop) == [
             ~s|ALTER TABLE "foo"."products" DROP CONSTRAINT "price_must_be_positive"|
           ]
  end

  # TODO?
  @tag :skip
  test "drop constraint on cluster"

  test "drop_if_exists constraint" do
    drop =
      {:drop_if_exists, constraint(:products, "price_must_be_positive", prefix: :foo), :restrict}

    assert execute_ddl(drop) == [
             ~s|ALTER TABLE "foo"."products" DROP CONSTRAINT IF EXISTS "price_must_be_positive"|
           ]
  end

  test "alter table" do
    alter =
      {:alter, table(:posts),
       [
         {:add, :title, :string, [default: "Untitled", size: 100, null: false]},
         {:add, :author_id, %Reference{table: :author}, []}
       ]}

    # TODO
    # CONSTRAINT "posts_author_id_fkey" REFERENCES "author"("id")
    # no FOREIGN KEY, need better error message
    assert_raise ArgumentError, "ClickHouse does not support FOREIGN KEY", fn ->
      execute_ddl(alter)
    end

    alter =
      {:alter, table(:posts),
       [
         {:add, :title, :string, [default: "Untitled", null: false]},
         {:add, :author_id, :integer, []}
       ]}

    assert execute_ddl(alter) == [
             """
             ALTER TABLE "posts" \
             ADD COLUMN "title" String DEFAULT 'Untitled' NOT NULL\
             """,
             """
             ALTER TABLE "posts" ADD COLUMN "author_id" Int32\
             """
           ]
  end

  test "alter table with options" do
    alter =
      {:alter, table(:posts, options: [on_cluster: "cluster-name", order_by: "tuple()"]),
       [
         {:add, :title, :string, [default: "Untitled", null: false]},
         {:add, :author_id, :integer, []}
       ]}

    assert execute_ddl(alter) == [
             """
             ALTER TABLE "posts" ON CLUSTER "cluster-name" \
             ADD COLUMN "title" String DEFAULT 'Untitled' NOT NULL\
             """,
             """
             ALTER TABLE "posts" ON CLUSTER "cluster-name" ADD COLUMN "author_id" Int32\
             """
           ]
  end

  test "alter table with datetime not null" do
    alter =
      {:alter, table(:posts),
       [
         {:add, :title, :string, [default: "Untitled", size: 100, null: false]},
         {:add, :when, :utc_datetime, [null: false]}
       ]}

    assert execute_ddl(alter) == [
             """
             ALTER TABLE "posts" \
             ADD COLUMN "title" String DEFAULT 'Untitled' NOT NULL\
             """,
             """
             ALTER TABLE "posts" \
             ADD COLUMN "when" DateTime NOT NULL\
             """
           ]
  end

  test "alter table with prefix" do
    alter =
      {:alter, table(:posts, prefix: :foo),
       [
         {:add, :title, :string, [default: "Untitled", size: 100, null: false]},
         {:add, :author_id, :integer, []}
       ]}

    assert execute_ddl(alter) == [
             """
             ALTER TABLE "foo"."posts" \
             ADD COLUMN "title" String DEFAULT 'Untitled' NOT NULL\
             """,
             """
             ALTER TABLE "foo"."posts" \
             ADD COLUMN "author_id" Int32\
             """
           ]
  end

  test "alter column errors for :modify column" do
    alter =
      {:alter, table(:posts),
       [
         {:modify, :price, :UInt128, []}
       ]}

    assert execute_ddl(alter) == [
             ~s{ALTER TABLE "posts" MODIFY COLUMN "price" UInt128}
           ]
  end

  test "alter table removes column" do
    alteration = {
      :alter,
      table(:posts),
      [{:remove, :price, :integer, [unsigned: true, size: 32]}]
    }

    assert execute_ddl(alteration) == [
             """
             ALTER TABLE "posts" \
             DROP COLUMN "price"\
             """
           ]
  end

  # TODO
  test "alter table with primary key" do
    alter = {:alter, table(:posts), [{:add, :my_pk, :integer, [primary_key: true]}]}

    assert execute_ddl(alter) == [
             """
             ALTER TABLE "posts" \
             ADD COLUMN "my_pk" Int32\
             """
           ]
  end

  test "create index" do
    create =
      {:create,
       index(:posts, [:category_id, :permalink],
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert execute_ddl(create) ==
             [
               """
               ALTER TABLE "posts" \
               ADD INDEX "posts_category_id_permalink_index" ("category_id","permalink") \
               TYPE bloom_filter GRANULARITY 8126\
               """
             ]

    create =
      {:create,
       index(:posts, ["lower(permalink)"],
         name: "posts$main",
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "posts" \
             ADD INDEX "posts$main" (lower(permalink)) \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]
  end

  # TODO
  test "create index with table options" do
    create =
      {:create,
       index(:posts, [:category_id, :permalink],
         options: [
           type: :bloom_filter,
           granularity: 8126,
           cluster: "cluster-name"
         ]
       )}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "posts" ON CLUSTER "cluster-name" \
             ADD INDEX "posts_category_id_permalink_index" ("category_id","permalink") \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]
  end

  test "create index if not exists" do
    create =
      {:create_if_not_exists,
       index(:posts, [:category_id, :permalink],
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "posts" \
             ADD INDEX IF NOT EXISTS "posts_category_id_permalink_index" ("category_id","permalink") \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]
  end

  test "create index with prefix" do
    create =
      {:create,
       index(:posts, [:category_id, :permalink],
         prefix: :foo,
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "foo"."posts" \
             ADD INDEX "posts_category_id_permalink_index" ("category_id","permalink") \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]

    create =
      {:create,
       index(:posts, ["lower(permalink)"],
         name: "posts$main",
         prefix: :foo,
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "foo"."posts" \
             ADD INDEX "posts$main" (lower(permalink)) \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]
  end

  # TODO
  test "create index with comment" do
    create =
      {:create,
       index(:posts, [:category_id, :permalink],
         prefix: :foo,
         comment: "comment",
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "foo"."posts" \
             ADD INDEX "posts_category_id_permalink_index" ("category_id","permalink") \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]
  end

  test "create unique index" do
    create = {:create, index(:posts, [:permalink], unique: true)}

    assert_raise ArgumentError, "ClickHouse does not support UNIQUE INDEX", fn ->
      execute_ddl(create)
    end
  end

  test "create unique index if not exists" do
    create = {:create_if_not_exists, index(:posts, [:permalink], unique: true)}

    assert_raise ArgumentError, "ClickHouse does not support UNIQUE INDEX", fn ->
      execute_ddl(create)
    end
  end

  test "create unique index with condition" do
    create = {:create, index(:posts, [:permalink], unique: true, where: "public IS 1")}

    assert_raise ArgumentError, "ClickHouse does not support UNIQUE INDEX", fn ->
      execute_ddl(create)
    end

    create = {:create, index(:posts, [:permalink], unique: true, where: :public)}

    assert_raise ArgumentError, "ClickHouse does not support UNIQUE INDEX", fn ->
      execute_ddl(create)
    end
  end

  # TODO + where:
  test "create index concurrently" do
    create =
      {:create,
       index(:posts, [:permalink],
         concurrently: true,
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert_raise ArgumentError, "ClickHouse does not support CREATE INDEX CONCURRENTLY", fn ->
      execute_ddl(create)
    end
  end

  test "create unique index concurrently" do
    create = {:create, index(:posts, [:permalink], concurrently: true, unique: true)}

    assert_raise ArgumentError, "ClickHouse does not support UNIQUE INDEX", fn ->
      execute_ddl(create)
    end
  end

  # TODO
  test "create an index using a different type" do
    create =
      {:create,
       index(:posts, [:permalink],
         using: :hash,
         options: [type: :bloom_filter, granularity: 8126]
       )}

    assert execute_ddl(create) == [
             """
             ALTER TABLE "posts" \
             ADD INDEX "posts_permalink_index" ("permalink") \
             TYPE bloom_filter GRANULARITY 8126\
             """
           ]
  end

  test "drop index" do
    drop = {:drop, index(:posts, [:id], name: "posts$main"), :restrict}
    assert execute_ddl(drop) == [~s|ALTER TABLE "posts" DROP INDEX "posts$main"|]
  end

  test "drop index with table options" do
    drop =
      {:drop, index(:posts, [:id], options: [on_cluster: "cluster-name", order_by: "tuple()"]),
       :restrict}

    assert execute_ddl(drop) == [
             ~s|ALTER TABLE "posts" ON CLUSTER "cluster-name" DROP INDEX "posts_id_index"|
           ]
  end

  test "drop index with prefix" do
    drop = {:drop, index(:posts, [:id], name: "posts$main", prefix: :foo), :restrict}
    assert execute_ddl(drop) == [~s|ALTER TABLE "foo"."posts" DROP INDEX "posts$main"|]
  end

  test "drop index if exists" do
    drop = {:drop_if_exists, index(:posts, [:id], name: "posts$main"), :restrict}
    assert execute_ddl(drop) == [~s|ALTER TABLE "posts" DROP INDEX IF EXISTS "posts$main"|]
  end

  test "drop index concurrently" do
    drop = {:drop, index(:posts, [:id], name: "posts$main", concurrently: true), :restrict}

    assert_raise ArgumentError, "ClickHouse does not support DROP INDEX CONCURRENTLY", fn ->
      execute_ddl(drop)
    end
  end

  test "create check constraint" do
    create =
      {:create,
       constraint(:products, "price_must_be_positive", check: "price > 0", validate: false)}

    assert execute_ddl(create) == [
             ~s|ALTER TABLE "products" ADD CONSTRAINT "price_must_be_positive" CHECK (price > 0)|
           ]

    create =
      {:create,
       constraint(:products, "price_must_be_positive",
         check: "price > 0",
         prefix: "foo",
         validate: false
       )}

    assert execute_ddl(create) == [
             ~s|ALTER TABLE "foo"."products" ADD CONSTRAINT "price_must_be_positive" CHECK (price > 0)|
           ]
  end

  test "create check constraint if not exists" do
    create =
      {:create_if_not_exists,
       constraint(:products, "price_must_be_positive", check: "price > 0", validate: false)}

    assert execute_ddl(create) == [
             ~s|ALTER TABLE "products" ADD CONSTRAINT IF NOT EXISTS "price_must_be_positive" CHECK (price > 0)|
           ]
  end

  @tag skip: true
  test "create exclusion constraint" do
    create =
      {:create,
       constraint(:products, "price_must_be_positive",
         exclude: ~s|gist (int4range("from", "to", '[]') WITH &&)|
       )}

    assert execute_ddl(create) == []
  end

  @tag skip: true
  test "create constraint with comment" do
    create =
      {:create,
       constraint(:products, "price_must_be_positive",
         check: "price > 0",
         prefix: "foo",
         comment: "comment"
       )}

    assert execute_ddl(create) == []
  end

  test "rename table" do
    rename = {:rename, table(:posts), table(:new_posts)}

    # https://clickhouse.com/docs/en/sql-reference/statements/rename/#rename-table
    assert execute_ddl(rename) == [
             ~s|RENAME TABLE "posts" TO "new_posts"|
           ]
  end

  test "rename table with options" do
    rename =
      {:rename, table(:posts, options: [cluster: "cluster-name"]),
       table(:new_posts, options: [on_cluster: "cluster-name", order_by: "tuple()"])}

    assert execute_ddl(rename) == [
             ~s|RENAME TABLE "posts" TO "new_posts" ON CLUSTER "cluster-name"|
           ]
  end

  test "rename table with prefix" do
    rename = {:rename, table(:posts, prefix: :foo), table(:new_posts, prefix: :bar)}

    assert execute_ddl(rename) == [
             ~s|RENAME TABLE "foo"."posts" TO "bar"."new_posts"|
           ]
  end

  test "rename column" do
    rename = {:rename, table(:posts), :given_name, :first_name}

    assert execute_ddl(rename) == [
             ~s|ALTER TABLE "posts" RENAME COLUMN "given_name" TO "first_name"|
           ]
  end

  test "rename column in prefixed table" do
    rename = {:rename, table(:posts, prefix: :foo), :given_name, :first_name}

    assert execute_ddl(rename) == [
             ~s|ALTER TABLE "foo"."posts" RENAME COLUMN "given_name" TO "first_name"|
           ]
  end

  test "drop column" do
    drop_column = {:alter, table(:posts), [{:remove, :summary}]}

    assert execute_ddl(drop_column) == [
             """
             ALTER TABLE "posts" \
             DROP COLUMN "summary"\
             """
           ]
  end

  test "arrays" do
    query =
      Schema
      |> select([], fragment("?", [1, 2, 3]))

    assert all(query) == ~s{SELECT [1,2,3] FROM "schema" AS s0}
  end

  test "maps" do
    assert all(select(Schema, [], fragment("?[site_id]", ^%{}))) ==
             ~s|SELECT {$0:Map(Nothing,Nothing)}[site_id] FROM "schema" AS s0|

    assert all(select(Schema, [], fragment("?[site_id]", ^%{1 => "UTC"}))) ==
             ~s|SELECT {$0:Map(Int64,String)}[site_id] FROM "schema" AS s0|
  end

  test "preloading" do
    query = from(p in Post, preload: [:comments], select: p)

    assert all(query) == ~s{SELECT p0."id",p0."title",p0."content" FROM "posts" AS p0}
  end

  test "autoincrement support" do
    table = table(:posts, engine: "MergeTree")
    serial = {:create, table, [{:add, :id, :serial, [primary_key: true]}]}
    bigserial = {:create, table, [{:add, :id, :bigserial, [primary_key: true]}]}
    id = {:create, table, [{:add, :id, :id, [primary_key: true]}]}
    integer = {:create, table, [{:add, :id, :integer, [primary_key: true]}]}

    assert_raise ArgumentError, ~r/type :serial is not supported/, fn -> execute_ddl(serial) end

    assert_raise ArgumentError, ~r/type :bigserial is not supported/, fn ->
      execute_ddl(bigserial)
    end

    assert_raise ArgumentError, ~r/type :id is ambiguous/, fn -> execute_ddl(id) end

    assert execute_ddl(integer) == [
             ~s/CREATE TABLE "posts" ("id" Int32,PRIMARY KEY ("id")) ENGINE=MergeTree/
           ]
  end

  # https://github.com/plausible/ecto_ch/issues/178
  test "DateTime64 params" do
    assert all(
             from e in "events",
               where: e.timestamp > ^~U[2024-06-28 20:02:17.3Z],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(1)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~U[2024-06-28 20:02:17.38Z],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(2)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~U[2024-06-28 20:02:17.382Z],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(3)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~U[2024-06-28 20:02:17.3827Z],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(4)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~U[2024-06-28 20:02:17.38278Z],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(5)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~U[2024-06-28 20:02:17.382780Z],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(6)})\
           """
  end

  # https://github.com/plausible/ecto_ch/pull/189
  test "naive DateTime64 params" do
    assert all(
             from e in "events",
               where: e.timestamp > ^~N[2024-06-28 20:02:17.3],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(1)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~N[2024-06-28 20:02:17.38],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(2)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~N[2024-06-28 20:02:17.382],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(3)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~N[2024-06-28 20:02:17.3827],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(4)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~N[2024-06-28 20:02:17.38278],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(5)})\
           """

    assert all(
             from e in "events",
               where: e.timestamp > ^~N[2024-06-28 20:02:17.382780],
               select: e.timestamp
           ) == """
           SELECT e0."timestamp" FROM "events" AS e0 WHERE (e0."timestamp" > {$0:DateTime64(6)})\
           """
  end

  test "build_params/3" do
    params =
      [
        1,
        "a",
        true,
        ~D[2024-04-12],
        ~U[2024-04-12 09:55:54.329788Z],
        ~U[2024-04-12 09:55:54Z]
      ]

    assert to_string(Connection.build_params(_ix = 0, _len = 0, params)) == ""
    assert to_string(Connection.build_params(_ix = 1, _len = 0, params)) == ""
    assert to_string(Connection.build_params(_ix = 2, _len = 0, params)) == ""

    assert to_string(Connection.build_params(_ix = 0, _len = 1, params)) ==
             "{$0:Int64}"

    assert to_string(Connection.build_params(_ix = 0, _len = 2, params)) ==
             "{$0:Int64},{$1:String}"

    assert to_string(Connection.build_params(_ix = 1, _len = 1, params)) ==
             "{$1:String}"

    assert to_string(Connection.build_params(_ix = 1, _len = 2, params)) ==
             "{$1:String},{$2:Bool}"

    assert to_string(Connection.build_params(_ix = 2, _len = 1, params)) ==
             "{$2:Bool}"

    assert to_string(Connection.build_params(_ix = 2, _len = 2, params)) ==
             "{$2:Bool},{$3:Date}"

    assert to_string(Connection.build_params(_ix = 2, _len = 3, params)) ==
             "{$2:Bool},{$3:Date},{$4:DateTime64(6)}"

    assert to_string(Connection.build_params(_ix = 1, _len = 4, params)) ==
             "{$1:String},{$2:Bool},{$3:Date},{$4:DateTime64(6)}"

    assert to_string(Connection.build_params(_ix = 0, _len = 5, params)) ==
             "{$0:Int64},{$1:String},{$2:Bool},{$3:Date},{$4:DateTime64(6)}"

    assert to_string(Connection.build_params(_ix = 0, _len = 6, params)) ==
             "{$0:Int64},{$1:String},{$2:Bool},{$3:Date},{$4:DateTime64(6)},{$5:DateTime}"

    assert to_string(
             Connection.build_params(
               _ix = 0,
               _len = 6,
               Enum.map(params, &Connection.mark_inline/1)
             )
           ) ==
             "1,'a',true,'2024-04-12'::date,'2024-04-12 09:55:54.329788'::DateTime64(6,'Etc/UTC'),'2024-04-12 09:55:54'::DateTime('Etc/UTC')"
  end

  # https://clickhouse.com/docs/en/sql-reference/data-types/int-uint
  test "integer boundaries" do
    import Bitwise

    param = fn value ->
      to_string(Connection.build_params(_ix = 0, _len = 1, [value]))
    end

    inline_param = fn value ->
      to_string(Connection.build_params(_ix = 0, _len = 1, [Connection.mark_inline(value)]))
    end

    # Int256 (from below)
    assert param.(-(1 <<< 255)) == "{$0:Int256}"
    assert param.(-(1 <<< 255) + 1) == "{$0:Int256}"
    assert param.(-(1 <<< 127) - 1) == "{$0:Int256}"

    assert inline_param.(-(1 <<< 255)) ==
             "-57896044618658097711785492504343953926634992332820282019728792003956564819968::Int256"

    assert inline_param.(-(1 <<< 255) + 1) ==
             "-57896044618658097711785492504343953926634992332820282019728792003956564819967::Int256"

    assert inline_param.(-(1 <<< 127) - 1) == "-170141183460469231731687303715884105729::Int256"

    # Int128 (from below)
    assert param.(-(1 <<< 127)) == "{$0:Int128}"
    assert param.(-(1 <<< 127) + 1) == "{$0:Int128}"
    assert param.(-(1 <<< 63) - 1) == "{$0:Int128}"

    assert inline_param.(-(1 <<< 127)) == "-170141183460469231731687303715884105728::Int128"
    assert inline_param.(-(1 <<< 127) + 1) == "-170141183460469231731687303715884105727::Int128"
    assert inline_param.(-(1 <<< 63) - 1) == "-9223372036854775809::Int128"

    # Int64
    assert param.(-(1 <<< 63)) == "{$0:Int64}"
    assert param.(-(1 <<< 63) + 1) == "{$0:Int64}"
    assert param.(-(1 <<< 31) - 1) == "{$0:Int64}"
    assert param.(0) == "{$0:Int64}"
    assert param.((1 <<< 63) - 1) == "{$0:Int64}"

    assert inline_param.(-(1 <<< 63)) == "-9223372036854775808"
    assert inline_param.(-(1 <<< 63) + 1) == "-9223372036854775807"
    assert inline_param.(-(1 <<< 31) - 1) == "-2147483649"
    assert inline_param.(0) == "0"
    assert inline_param.((1 <<< 63) - 1) == "9223372036854775807"

    # UInt64
    assert param.(1 <<< 63) == "{$0:UInt64}"
    assert param.((1 <<< 64) - 1) == "{$0:UInt64}"
    assert inline_param.(1 <<< 63) == "9223372036854775808"
    assert inline_param.((1 <<< 64) - 1) == "18446744073709551615"

    # UInt128
    assert param.(1 <<< 64) == "{$0:UInt128}"
    assert param.((1 <<< 128) - 1) == "{$0:UInt128}"
    assert inline_param.(1 <<< 64) == "18446744073709551616::UInt128"
    assert inline_param.((1 <<< 128) - 1) == "340282366920938463463374607431768211455::UInt128"

    # UInt256
    assert param.(1 <<< 128) == "{$0:UInt256}"
    assert param.((1 <<< 256) - 1) == "{$0:UInt256}"
    assert inline_param.(1 <<< 128) == "340282366920938463463374607431768211456::UInt256"

    assert inline_param.((1 <<< 256) - 1) ==
             "115792089237316195423570985008687907853269984665640564039457584007913129639935::UInt256"
  end
end
