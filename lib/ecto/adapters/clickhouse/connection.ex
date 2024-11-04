defmodule Ecto.Adapters.ClickHouse.Connection do
  @moduledoc false

  @behaviour Ecto.Adapters.SQL.Connection
  @dialyzer :no_improper_lists

  require Logger
  alias Ecto.SubQuery
  alias Ecto.Query.{QueryExpr, ByExpr, JoinExpr, BooleanExpr, WithExpr, Tagged}

  @parent_as __MODULE__

  @impl true
  def child_spec(opts) do
    Ch.child_spec(opts)
  end

  @impl true
  def prepare_execute(conn, _name, statement, params, opts) do
    query = Ch.Query.build(statement, opts[:command])
    DBConnection.prepare_execute(conn, query, params, opts)
  end

  @impl true
  def execute(conn, query, params, opts) do
    DBConnection.execute(conn, query, params, opts)
  end

  # TODO what should be done about transactions? probably will need to build custom Repo.stream
  @impl true
  def query(conn, statement, params, opts) do
    Ch.query(conn, statement, params, opts)
  end

  @impl true
  def query_many(_conn, _statement, _params, _opts) do
    raise "not implemented"
  end

  @impl true
  def stream(conn, statement, params, opts) do
    Ch.stream(conn, statement, params, opts)
  end

  @impl true
  def to_constraints(_exception, _opts) do
    raise "not implemented"
  end

  @impl true
  def all(query, params \\ [], as_prefix \\ []) do
    if Map.get(query, :lock) do
      raise ArgumentError, "ClickHouse does not support locks"
    end

    sources = create_names(query, as_prefix)

    cte = cte(query, sources, params)
    from = from(query, sources, params)
    select = select(query, sources, params)
    join = join(query, sources, params)
    where = where(query, sources, params)
    group_by = group_by(query, sources, params)
    having = having(query, sources, params)
    window = window(query, sources, params)
    order_by = order_by(query, sources, params)
    limit = limit(query, sources, params)
    offset = offset(query, sources, params)
    combinations = combinations(query, params)

    [
      cte,
      select,
      from,
      join,
      where,
      group_by,
      having,
      window,
      order_by,
      limit,
      offset,
      combinations
    ]
  end

  @dialyzer {:no_return, update_all: 1, update_all: 2}
  @impl true
  def update_all(query, _prefix \\ nil) do
    raise Ecto.QueryError,
      query: query,
      message:
        "ClickHouse does not support UPDATE statements -- use ALTER TABLE ... UPDATE instead"
  end

  # https://clickhouse.com/docs/en/sql-reference/statements/alter/update
  # https://clickhouse.com/docs/en/guides/developer/mutations#updating-data
  def alter_update_all(query, params \\ []) do
    # TODO link to https://clickhouse.com/blog/handling-updates-and-deletes-in-clickhouse#updating-and-deleting-using-joins
    unless query.joins == [] do
      raise Ecto.QueryError,
        query: query,
        message:
          "Ecto.Adapters.ClickHouse does not support JOIN in ALTER TABLE ... UPDATE statements"
    end

    if query.select do
      raise Ecto.QueryError,
        query: query,
        message:
          "Ecto.Adapters.ClickHouse does not support RETURNING in ALTER TABLE ... UPDATE statements"
    end

    if query.with_ctes do
      raise Ecto.QueryError,
        query: query,
        message:
          "Ecto.Adapters.ClickHouse does not support CTEs in ALTER TABLE ... UPDATE statements"
    end

    %{sources: sources} = query
    {table, _schema, prefix} = elem(sources, 0)
    fields = update_fields(query, sources, params)

    where =
      case query.wheres do
        [] -> " WHERE 1"
        _ -> where(query, {{nil, nil, nil}}, params)
      end

    ["ALTER TABLE ", quote_table(prefix, table), " UPDATE ", fields, where]
  end

  defp update_fields(%{updates: updates} = query, sources, params) do
    fields =
      for %{expr: expression} <- updates, {op, kw} <- expression, {key, value} <- kw do
        update_op(op, quote_name(key), value, sources, params, query)
      end

    Enum.intersperse(fields, ?,)
  end

  defp update_op(:set, quoted_key, value, sources, params, query) do
    [quoted_key, ?= | expr(value, sources, params, query)]
  end

  defp update_op(:inc, quoted_key, value, sources, params, query) do
    [quoted_key, ?=, quoted_key, ?+ | expr(value, sources, params, query)]
  end

  defp update_op(:push, quoted_key, value, sources, params, query) do
    [quoted_key, ?=, "arrayPushBack(", quoted_key, ?,, expr(value, sources, params, query), ?)]
  end

  defp update_op(:pull, quoted_key, value, sources, params, query) do
    [
      quoted_key,
      ?=,
      "arrayFilter(x->x!=",
      expr(value, sources, params, query),
      ?,,
      quoted_key,
      ?)
    ]
  end

  defp update_op(command, _quoted_key, _value, _sources, _params, query) do
    raise Ecto.QueryError,
      query: query,
      message: "Ecto.Adapters.ClickHouse does not support update operation #{inspect(command)}"
  end

  @impl true
  def delete_all(query, params \\ []) do
    unless query.joins == [] do
      raise Ecto.QueryError,
        query: query,
        message: "ClickHouse does not support JOIN on DELETE statements"
    end

    if query.select do
      raise Ecto.QueryError,
        query: query,
        message: "ClickHouse does not support RETURNING on DELETE statements"
    end

    if query.with_ctes do
      raise Ecto.QueryError,
        query: query,
        message: "ClickHouse does not support CTEs (WITH) on DELETE statements"
    end

    %{sources: sources} = query
    {table, _schema, prefix} = elem(sources, 0)

    where =
      case query.wheres do
        [] -> " WHERE 1"
        _ -> where(query, {{nil, nil, nil}}, params)
      end

    ["DELETE FROM ", quote_table(prefix, table) | where]
  end

  @impl true
  def ddl_logs(_), do: []

  @impl true
  def table_exists_query(table) do
    {"SELECT name FROM system.tables WHERE name={$0:String} LIMIT 1", [table]}
  end

  @impl true
  def execute_ddl(command) do
    Ecto.Adapters.ClickHouse.Migration.execute_ddl(command)
  end

  @impl true
  def insert(prefix, table, header, rows, _on_conflict, returning, _placeholders) do
    unless returning == [] do
      raise ArgumentError, "ClickHouse does not support RETURNING on INSERT statements"
    end

    insert(prefix, table, header, rows)
  end

  def insert(prefix, table, header, rows) do
    insert =
      case header do
        [] ->
          ["INSERT INTO " | quote_table(prefix, table)]

        _not_empty ->
          fields = [?(, intersperse_map(header, ?,, &quote_name/1), ?)]
          ["INSERT INTO ", quote_table(prefix, table) | fields]
      end

    case rows do
      {%Ecto.Query{} = query, params} -> [insert, ?\s | all(query, params)]
      rows when is_list(rows) -> insert
    end
  end

  @impl true
  def update(_prefix, _table, _fields, _filters, _returning) do
    raise ArgumentError,
          "ClickHouse does not support UPDATE statements -- use ALTER TABLE ... UPDATE instead"
  end

  @impl true
  # https://clickhouse.com/docs/en/sql-reference/statements/delete
  def delete(prefix, table, filters, returning) do
    unless returning == [] do
      raise ArgumentError, "ClickHouse does not support RETURNING on DELETE statements"
    end

    filters =
      filters
      |> Enum.with_index()
      |> intersperse_map(" AND ", fn
        {{field, nil}, _idx} ->
          ["isNull(", quote_name(field), ?)]

        {{field, value}, idx} ->
          [quote_name(field), ?=, build_param(idx, value)]
      end)

    ["DELETE FROM ", quote_table(prefix, table), " WHERE ", filters]
  end

  @impl true
  def explain_query(conn, query, params, opts) do
    explain =
      case Keyword.get(opts, :type, :plan) do
        :ast -> "EXPLAIN AST "
        :syntax -> "EXPLAIN SYNTAX "
        :query_tree -> "EXPLAIN QUERY TREE "
        :plan -> "EXPLAIN PLAN "
        :pipeline -> "EXPLAIN PIPELINE "
        :table_override -> "EXPLAIN TABLE OVERRIDE"
      end

    explain_query = [explain | query]

    with {:ok, %{rows: rows}} <- query(conn, explain_query, params, opts) do
      {:ok, rows}
    end
  end

  binary_ops = [
    ==: " = ",
    !=: " != ",
    <=: " <= ",
    >=: " >= ",
    <: " < ",
    >: " > ",
    +: " + ",
    -: " - ",
    *: " * ",
    /: " / ",
    # TODO ilike()
    ilike: " ILIKE ",
    # TODO like()
    like: " LIKE ",
    # TODO in()
    in: " IN "
  ]

  @binary_ops Keyword.keys(binary_ops)

  for {op, str} <- binary_ops do
    defp handle_call(unquote(op), 2), do: {:binary_op, unquote(str)}
  end

  defp handle_call(fun, _arity), do: {:fun, Atom.to_string(fun)}

  defp select(%{select: %{fields: fields}, distinct: distinct} = query, sources, params) do
    [
      "SELECT ",
      distinct(distinct, sources, params, query)
      | select_fields(fields, sources, params, query)
    ]
  end

  defp select_fields([], _sources, _params, _query), do: "true"

  defp select_fields(fields, sources, params, query) do
    intersperse_map(fields, ?,, fn
      # TODO raise
      # this is useful in array joins lie
      #
      #     "arrays_test"
      #     |> join(:array, [a], r in "arr")
      #     |> select([a, r], {a.s, fragment("?", r)})
      #
      {:&, _, [idx]} ->
        {_, source, _} = elem(sources, idx)
        source

      {k, v} ->
        [expr(v, sources, params, query), " AS " | quote_name(k)]

      v ->
        expr(v, sources, params, query)
    end)
  end

  defp distinct(nil, _sources, _params, _query), do: []
  defp distinct(%{expr: true}, _sources, _params, _query), do: "DISTINCT "
  defp distinct(%{expr: false}, _sources, _params, _query), do: []

  defp distinct(%{expr: exprs}, sources, params, query) when is_list(exprs) do
    [
      "DISTINCT ON (",
      intersperse_map(exprs, ?,, &order_by_expr(&1, sources, params, query)) | ") "
    ]
  end

  defp from(%{from: %{source: source, hints: hints}} = query, sources, params) do
    {from, name} = get_source(query, sources, params, 0, source)
    [" FROM ", from, " AS ", name | hints(hints)]
  end

  def cte(
        %{with_ctes: %WithExpr{recursive: recursive, queries: [_ | _] = queries}} = query,
        sources,
        params
      ) do
    recursive_opt = if recursive, do: "RECURSIVE ", else: ""

    ctes =
      intersperse_map(queries, ?,, fn {name, _opts, cte} ->
        [quote_name(name), " AS ", cte_query(cte, sources, params, query)]
      end)

    ["WITH ", recursive_opt, ctes, " "]
  end

  def cte(%{with_ctes: _}, _sources, _params), do: []

  defp cte_query(%Ecto.Query{} = query, sources, params, parent_query) do
    query = put_in(query.aliases[@parent_as], {parent_query, sources})
    [?(, all(query, params, subquery_as_prefix(sources)), ?)]
  end

  defp cte_query(%QueryExpr{expr: expr}, sources, params, query) do
    expr(expr, sources, params, query)
  end

  defp join(%{joins: []}, _sources, _params), do: []

  defp join(%{joins: joins} = query, sources, params) do
    Enum.map(joins, fn
      %JoinExpr{qual: qual, ix: ix, source: source, on: %QueryExpr{expr: on_exrp}, hints: hints} ->
        {join, name} = get_source(query, sources, params, ix, source)

        [
          join_hints(hints, query),
          join_qual(qual, hints),
          join,
          " AS ",
          name
          | join_on(qual, on_exrp, hints, sources, params, query)
        ]
    end)
  end

  # TODO maybe add GLOBAL and PASTE
  valid_join_strictness_hints = ["ASOF", "ANY", "ANTI", "SEMI"]
  valid_join_hints = valid_join_strictness_hints ++ ["ARRAY"]

  for hint <- valid_join_strictness_hints do
    hints = List.wrap(hint)

    defp join_hints(unquote(hints), _query) do
      unquote(" " <> Enum.join(hints, " "))
    end
  end

  defp join_hints(["ARRAY"], _query), do: []
  defp join_hints([], _query), do: []

  defp join_hints(hints, query) do
    supported = unquote(valid_join_hints) |> Enum.map(&inspect/1) |> Enum.join(", ")

    raise Ecto.QueryError,
      query: query,
      message: """
      unsupported JOIN strictness or type passed in hints: #{inspect(hints)}
      supported: #{supported}
      """
  end

  defp join_on(:cross, true, _hints, _sources, _params, _query), do: []

  defp join_on(_qual, true, ["ARRAY"], _sources, _params, _query) do
    []
  end

  defp join_on(_qual, expr, _hints, sources, params, query) do
    [" ON " | expr(expr, sources, params, query)]
  end

  defp join_qual(:inner, ["ARRAY"]), do: " ARRAY JOIN "
  defp join_qual(:inner, _hints), do: " INNER JOIN "
  defp join_qual(:left, ["ARRAY"]), do: " LEFT ARRAY JOIN "
  defp join_qual(:left, _hints), do: " LEFT JOIN "
  defp join_qual(:right, _hints), do: " RIGHT JOIN "
  defp join_qual(:full, _hints), do: " FULL JOIN "
  defp join_qual(:cross, _hints), do: " CROSS JOIN "

  defp join_qual(qual, _hints) do
    raise ArgumentError, "join type #{inspect(qual)} is not supported"
  end

  defp where(%{wheres: wheres} = query, sources, params) do
    boolean(" WHERE ", wheres, sources, params, query)
  end

  defp having(%{havings: havings} = query, sources, params) do
    boolean(" HAVING ", havings, sources, params, query)
  end

  defp group_by(%{group_bys: []}, _sources, _params), do: []

  defp group_by(%{group_bys: group_bys} = query, sources, params) do
    [
      " GROUP BY "
      | intersperse_map(group_bys, ?,, fn %ByExpr{expr: expr} ->
          intersperse_map(expr, ?,, &expr(&1, sources, params, query))
        end)
    ]
  end

  defp window(%{windows: []}, _sources, _params), do: []

  defp window(%{windows: windows} = query, sources, params) do
    [
      " WINDOW "
      | intersperse_map(windows, ?,, fn {name, %{expr: kw}} ->
          [quote_name(name), " AS " | window_exprs(kw, sources, params, query)]
        end)
    ]
  end

  defp window_exprs(kw, sources, params, query) do
    [
      ?(,
      intersperse_map(kw, ?\s, &window_expr(&1, sources, params, query)),
      ?)
    ]
  end

  defp window_expr({:partition_by, fields}, sources, params, query) do
    ["PARTITION BY " | intersperse_map(fields, ?,, &expr(&1, sources, params, query))]
  end

  defp window_expr({:order_by, fields}, sources, params, query) do
    ["ORDER BY " | intersperse_map(fields, ?,, &order_by_expr(&1, sources, params, query))]
  end

  defp window_expr({:frame, {:fragment, _, _} = fragment}, sources, params, query) do
    expr(fragment, sources, params, query)
  end

  defp order_by(%{order_bys: []}, _sources, _params), do: []

  defp order_by(%{order_bys: order_bys} = query, sources, params) do
    [
      " ORDER BY "
      | intersperse_map(order_bys, ?,, fn %{expr: expr} ->
          intersperse_map(expr, ?,, &order_by_expr(&1, sources, params, query))
        end)
    ]
  end

  defp order_by_expr({dir, expr}, sources, params, query) do
    str = expr(expr, sources, params, query)

    case dir do
      :asc ->
        str

      :desc ->
        [str | " DESC"]

      :asc_nulls_first ->
        [str | " ASC NULLS FIRST"]

      :desc_nulls_first ->
        [str | " DESC NULLS FIRST"]

      :asc_nulls_last ->
        [str | " ASC NULLS LAST"]

      :desc_nulls_last ->
        [str | " DESC NULLS LAST"]

      _ ->
        raise Ecto.QueryError,
          query: query,
          message: "ClickHouse does not support #{dir} in ORDER BY"
    end
  end

  defp limit(%{limit: nil}, _sources, _params), do: []

  defp limit(%{limit: %{expr: expr}} = query, sources, params) do
    [" LIMIT ", expr(expr, sources, params, query)]
  end

  defp offset(%{offset: nil}, _sources, _params), do: []

  defp offset(%{offset: %{expr: expr}} = query, sources, params) do
    [" OFFSET ", expr(expr, sources, params, query)]
  end

  defp combinations(%{combinations: combinations}, params) do
    Enum.map(combinations, &combination(&1, params))
  end

  defp combination({:union, query}, params), do: [" UNION DISTINCT (", all(query, params), ?)]
  defp combination({:union_all, query}, params), do: [" UNION ALL (", all(query, params), ?)]

  defp combination({:except, query}, params), do: [" EXCEPT (", all(query, params), ?)]
  defp combination({:intersect, query}, params), do: [" INTERSECT (", all(query, params), ?)]

  defp combination({:except_all, query}, _params) do
    raise Ecto.QueryError,
      query: query,
      message: "ClickHouse does not support EXCEPT ALL"
  end

  defp combination({:intersect_all, query}, _params) do
    raise Ecto.QueryError,
      query: query,
      message: "ClickHouse does not support INTERSECT ALL"
  end

  defp hints([_ | _] = hints) do
    [" " | intersperse_map(hints, ?\s, &hint/1)]
  end

  defp hints([]), do: []

  defp hint(hint) when is_binary(hint), do: hint

  # TODO remove once it's no longer used in plausible/analytics
  #      https://github.com/elixir-ecto/ecto/pull/4254
  defp hint({k, v}) when is_atom(k) and is_integer(v) do
    [Atom.to_string(k), ?\s, Integer.to_string(v)]
  end

  defp boolean(_name, [], _sources, _params, _query), do: []

  defp boolean(name, [%{expr: expr}], sources, params, query) do
    [name | maybe_paren_expr(expr, sources, params, query)]
  end

  defp boolean(name, [%{expr: expr, op: op} | exprs], sources, params, query) do
    {_last_op, result} =
      Enum.reduce(exprs, {op, maybe_paren_expr(expr, sources, params, query)}, fn
        %BooleanExpr{expr: expr, op: op}, {op, acc} ->
          {op, [acc, operator_to_boolean(op) | logical_expr(op, expr, sources, params, query)]}

        %BooleanExpr{expr: expr, op: op}, {_, acc} ->
          {op,
           [?(, acc, ?), operator_to_boolean(op) | logical_expr(op, expr, sources, params, query)]}
      end)

    [name | result]
  end

  defp operator_to_boolean(:and), do: " AND "
  defp operator_to_boolean(:or), do: " OR "

  defp parens_for_select([first_expr | _] = expression) do
    if is_binary(first_expr) and String.match?(first_expr, ~r/^\s*select/i) do
      [?(, expression, ?)]
    else
      expression
    end
  end

  defp paren_expr(expr, sources, params, query) do
    [?(, expr(expr, sources, params, query), ?)]
  end

  defp expr({_type, [literal]}, sources, params, query) do
    expr(literal, sources, params, query)
  end

  defp expr({:^, [], [ix]}, _sources, params, _query) do
    build_param(ix, Enum.at(params, ix))
  end

  defp expr({:^, [], [ix, len]}, _sources, params, _query) when len > 0 do
    [?(, build_params(ix, len, params), ?)]
  end

  # using an empty array literal since empty tuples are not allowed in ClickHouse
  defp expr({:^, [], [_, 0]}, _sources, _params, _query), do: "[]"

  defp expr({{:., _, [{:&, _, [ix]}, field]}, _, []}, sources, _params, _query)
       when is_atom(field) do
    quote_qualified_name(field, sources, ix)
  end

  defp expr({{:., _, [{:parent_as, _, [as]}, field]}, _, []}, _sources, _params, query)
       when is_atom(field) do
    {ix, sources} = get_parent_sources_ix(query, as)
    quote_qualified_name(field, sources, ix)
  end

  defp expr({:&, _, [ix]}, sources, _params, _query) do
    {_, source, _} = elem(sources, ix)
    source
  end

  defp expr({:&, _, [idx, fields, _counter]}, sources, _params, query) do
    {_, name, schema} = elem(sources, idx)

    if is_nil(schema) and is_nil(fields) do
      raise Ecto.QueryError,
        query: query,
        message:
          "ClickHouse requires a schema module when using selector " <>
            "#{inspect(name)} but none was given. " <>
            "Please specify a schema or specify exactly which fields from " <>
            "#{inspect(name)} you desire"
    end

    intersperse_map(fields, ?,, &[name, ?. | quote_name(&1)])
  end

  defp expr({:in, _, [_left, []]}, _sources, _params, _query), do: "0"

  defp expr({:in, _, [left, right]}, sources, params, query) when is_list(right) do
    args = intersperse_map(right, ?,, &expr(&1, sources, params, query))
    [expr(left, sources, params, query), " IN (", args, ?)]
  end

  defp expr({:in, _, [_, {:^, _, [_ix, 0]}]}, _sources, _params, _query), do: "0"

  defp expr({:in, _, [left, right]}, sources, params, query) do
    [expr(left, sources, params, query), " IN ", expr(right, sources, params, query)]
  end

  defp expr({:is_nil, _, [arg]}, sources, params, query) do
    ["isNull(", expr(arg, sources, params, query), ?)]
  end

  defp expr({:not, _, [expr]}, sources, params, query) do
    case expr do
      {:is_nil, _, [arg]} ->
        ["isNotNull(", expr(arg, sources, params, query), ?)]

      {:like, _, [l, r]} ->
        ["notLike(", expr(l, sources, params, query), ", ", expr(r, sources, params, query), ?)]

      {:ilike, _, [l, r]} ->
        ["notILike(", expr(l, sources, params, query), ", ", expr(r, sources, params, query), ?)]

      # TODO notIn()

      _other ->
        ["not(", expr(expr, sources, params, query), ?)]
    end
  end

  defp expr({:filter, _, [agg, filter]}, sources, params, query) do
    [
      expr(agg, sources, params, query),
      " FILTER (WHERE ",
      expr(filter, sources, params, query),
      ?)
    ]
  end

  defp expr(%SubQuery{query: query}, sources, params, parent_query) do
    query = put_in(query.aliases[@parent_as], {parent_query, sources})
    [?(, all(query, params, subquery_as_prefix(sources)), ?)]
  end

  defp expr({:fragment, _, [kw]}, _sources, _params, query)
       when is_list(kw) or tuple_size(kw) == 3 do
    raise Ecto.QueryError,
      query: query,
      message: "ClickHouse adapter does not support keyword or interpolated fragments"
  end

  defp expr({:fragment, _, parts}, sources, params, query) do
    parts
    |> Enum.map(fn
      {:raw, part} -> part
      {:expr, expr} -> expr(expr, sources, params, query)
    end)
    |> parens_for_select()
  end

  defp expr({:literal, _, [literal]}, _sources, _params, _query) do
    quote_name(literal)
  end

  defp expr({:selected_as, _, [name]}, _sources, _params, _query) do
    quote_name(name)
  end

  defp expr({:over, _, [agg, name]}, sources, params, query) when is_atom(name) do
    [expr(agg, sources, params, query), " OVER " | quote_name(name)]
  end

  defp expr({:over, _, [agg, kw]}, sources, params, query) do
    [expr(agg, sources, params, query), " OVER " | window_exprs(kw, sources, params, query)]
  end

  defp expr({:{}, _, elems}, sources, params, query) do
    [?(, intersperse_map(elems, ?,, &expr(&1, sources, params, query)), ?)]
  end

  defp expr({:count, _, []}, _sources, _params, _query), do: "count(*)"

  defp expr({:count, _, [expr]}, sources, params, query) do
    ["count(", expr(expr, sources, params, query), ?)]
  end

  defp expr({:count, _, [expr, :distinct]}, sources, params, query) do
    ["countDistinct(", expr(expr, sources, params, query), ?)]
  end

  defp expr({:datetime_add, _, [datetime, count, interval]}, sources, params, query) do
    [
      expr(datetime, sources, params, query),
      " + ",
      interval(count, interval, sources, params, query)
    ]
  end

  defp expr({:date_add, _, [date, count, interval]}, sources, params, query) do
    [
      "CAST(",
      expr(date, sources, params, query),
      " + ",
      interval(count, interval, sources, params, query)
      | " AS Date)"
    ]
  end

  defp expr({:json_extract_path, _, [expr, path]}, sources, params, query) do
    path =
      Enum.map(path, fn
        bin when is_binary(bin) -> [?., escape_json_key(bin)]
        int when is_integer(int) -> [?[, Integer.to_string(int), ?]]
      end)

    ["JSON_QUERY(", expr(expr, sources, params, query), ", '$", path | "')"]
  end

  # TODO parens?
  defp expr({:exists, _, [subquery]}, sources, params, query) do
    ["exists" | expr(subquery, sources, params, query)]
  end

  defp expr({op, _, [l, r]}, sources, params, query) when op in [:and, :or] do
    [
      logical_expr(op, l, sources, params, query),
      operator_to_boolean(op),
      logical_expr(op, r, sources, params, query)
    ]
  end

  defp expr({fun, _, args}, sources, params, query) when is_atom(fun) and is_list(args) do
    case handle_call(fun, length(args)) do
      {:binary_op, op} ->
        [left, right] = args

        [
          maybe_paren_expr(left, sources, params, query),
          op | maybe_paren_expr(right, sources, params, query)
        ]

      {:fun, fun} ->
        [fun, ?(, intersperse_map(args, ?,, &expr(&1, sources, params, query)), ?)]
    end
  end

  defp expr(list, sources, params, query) when is_list(list) do
    [?[, intersperse_map(list, ?,, &expr(&1, sources, params, query)), ?]]
  end

  defp expr(%Decimal{} = decimal, _sources, _params, _query) do
    Decimal.to_string(decimal, :normal)
  end

  defp expr(%Tagged{value: value, type: :any}, sources, params, query) do
    expr(value, sources, params, query)
  end

  defp expr(%Tagged{value: value, type: type}, sources, params, query) do
    ["CAST(", expr(value, sources, params, query), " AS ", ecto_to_db(type, query), ?)]
  end

  defp expr(nil, _sources, _params, _query), do: "NULL"
  # TODO "true" / "false"?
  defp expr(true, _sources, _params, _query), do: "1"
  defp expr(false, _sources, _params, _query), do: "0"

  defp expr(literal, _sources, _params, _query) when is_binary(literal) do
    [?', escape_string(literal), ?']
  end

  defp expr(literal, _sources, _params, _query) when is_integer(literal) do
    inline_param(literal)
  end

  defp expr(literal, _sources, _params, _query) when is_float(literal) do
    Float.to_string(literal)
  end

  defp expr(expr, _sources, _params, query) do
    raise Ecto.QueryError,
      query: query,
      message: "unsupported expression #{inspect(expr)}"
  end

  defp logical_expr(parent_op, expr, sources, params, query) do
    case expr do
      {^parent_op, _, [l, r]} ->
        [
          logical_expr(parent_op, l, sources, params, query),
          operator_to_boolean(parent_op),
          logical_expr(parent_op, r, sources, params, query)
        ]

      {op, _, [l, r]} when op in [:and, :or] ->
        [
          ?(,
          logical_expr(op, l, sources, params, query),
          operator_to_boolean(op),
          logical_expr(op, r, sources, params, query),
          ?)
        ]

      _ ->
        maybe_paren_expr(expr, sources, params, query)
    end
  end

  defp maybe_paren_expr({op, _, [_, _]} = expr, sources, params, query) when op in @binary_ops do
    paren_expr(expr, sources, params, query)
  end

  defp maybe_paren_expr(expr, sources, params, query) do
    expr(expr, sources, params, query)
  end

  defp create_names(%{sources: sources}, as_prefix) do
    sources |> create_names(0, tuple_size(sources), as_prefix) |> List.to_tuple()
  end

  defp create_names(sources, pos, limit, as_prefix) when pos < limit do
    [create_name(sources, pos, as_prefix) | create_names(sources, pos + 1, limit, as_prefix)]
  end

  defp create_names(_sources, pos, pos, as_prefix), do: [as_prefix]

  defp subquery_as_prefix(sources) do
    [?s | :erlang.element(tuple_size(sources), sources)]
  end

  defp create_name(sources, pos, as_prefix) do
    case elem(sources, pos) do
      {:fragment, _, _} ->
        {nil, as_prefix ++ [?f | Integer.to_string(pos)], nil}

      {table, schema, prefix} ->
        name = as_prefix ++ [create_alias(table) | Integer.to_string(pos)]
        {quote_table(prefix, table), name, schema}

      %SubQuery{} ->
        {nil, as_prefix ++ [?s | Integer.to_string(pos)], nil}
    end
  end

  defp create_alias(<<first, _rest::bytes>>)
       when first in ?a..?z
       when first in ?A..?Z do
    <<first>>
  end

  defp create_alias(_), do: ?t

  @doc false
  def intersperse_map([elem], _separator, mapper), do: [mapper.(elem)]

  def intersperse_map([elem | rest], separator, mapper) do
    [mapper.(elem), separator | intersperse_map(rest, separator, mapper)]
  end

  def intersperse_map([], _separator, _mapper), do: []

  @inline_tag :__ecto_ch_inline__

  @doc false
  def mark_inline(param), do: {@inline_tag, param}

  @compile inline: [build_param: 2]
  defp build_param(ix, param) do
    case param do
      {@inline_tag, param} -> inline_param(param)
      param -> ["{$", Integer.to_string(ix), ?:, param_type(param), ?}]
    end
  end

  @doc false
  def build_params(ix, len, params) when len > 1 do
    [build_param(ix, Enum.at(params, ix)), ?, | build_params(ix + 1, len - 1, params)]
  end

  def build_params(ix, _len = 1, params), do: build_param(ix, Enum.at(params, ix))
  def build_params(_ix, _len = 0, _params), do: []

  @doc false
  def quote_name(name, quoter \\ ?")
  def quote_name(nil, _), do: []

  def quote_name(names, quoter) when is_list(names) do
    names
    |> Enum.reject(&is_nil/1)
    |> intersperse_map(?., &quote_name(&1, nil))
    |> wrap_in(quoter)
  end

  def quote_name(name, quoter) when is_atom(name) do
    name |> Atom.to_string() |> quote_name(quoter)
  end

  def quote_name(name, quoter) do
    wrap_in(name, quoter)
  end

  defp quote_qualified_name(name, sources, ix) do
    {_, source, _} = elem(sources, ix)

    case source do
      nil -> quote_name(name)
      _other -> [source, ?. | quote_name(name)]
    end
  end

  @doc false
  def quote_table(prefix, name)
  def quote_table(nil, name), do: quote_name(name)
  def quote_table(prefix, name), do: [quote_name(prefix), ?., quote_name(name)]

  defp wrap_in(value, nil), do: value
  defp wrap_in(value, wrapper), do: [wrapper, value, wrapper]

  @doc false
  # TODO faster?
  def escape_string(value) when is_binary(value) do
    value
    |> :binary.replace("'", "''", [:global])
    |> :binary.replace("\\", "\\\\", [:global])
  end

  defp escape_json_key(value) when is_binary(value) do
    value
    |> escape_string()
    |> :binary.replace("\"", "\\\"", [:global])
  end

  defp get_source(query, sources, params, ix, source) do
    {expr, name, _schema} = elem(sources, ix)
    {expr || expr(source, sources, params, query), name}
  end

  defp get_parent_sources_ix(query, as) do
    case query.aliases[@parent_as] do
      {%{aliases: %{^as => ix}}, sources} -> {ix, sources}
      {%{} = parent, _sources} -> get_parent_sources_ix(parent, as)
    end
  end

  # TODO quote?
  defp interval(count, interval, _sources, _params, _query) when is_integer(count) do
    ["INTERVAL ", Integer.to_string(count), ?\s, interval]
  end

  defp interval(count, interval, _sources, _params, _query) when is_float(count) do
    count = :erlang.float_to_binary(count, [:compact, decimals: 16])
    ["INTERVAL ", count, ?\s, interval]
  end

  # TODO typecast to ::numeric?
  defp interval(count, interval, sources, params, query) do
    [expr(count, sources, params, query), " * ", interval(1, interval, sources, params, query)]
  end

  # when ecto migrator queries for versions in schema_versions it uses type(version, :integer)
  # so we need :integer to be the same as :bigint which is used for schema_versions table definition
  # this is why :integer is Int64 and not Int32
  defp ecto_to_db(:integer, _query), do: "Int64"
  defp ecto_to_db(:binary, _query), do: "String"
  defp ecto_to_db({:parameterized, {Ch, type}}, _query), do: Ch.Types.encode(type)
  defp ecto_to_db({:array, type}, query), do: ["Array(", ecto_to_db(type, query), ?)]

  defp ecto_to_db(type, _query) when type in [:uuid, :string, :date, :boolean] do
    Ch.Types.encode(type)
  end

  defp ecto_to_db(type, query) do
    raise Ecto.QueryError,
      query: query,
      message: "unknown or ambiguous (for ClickHouse) Ecto type #{inspect(type)}"
  end

  defp inline_param(nil), do: "NULL"
  defp inline_param(true), do: "true"
  defp inline_param(false), do: "false"
  defp inline_param(s) when is_binary(s), do: [?', escape_string(s), ?']

  @max_uint128 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  @max_uint64 0xFFFFFFFFFFFFFFFF
  @max_int64 0x7FFFFFFFFFFFFFFF
  @min_int128 -0x80000000000000000000000000000000
  @min_int64 -0x8000000000000000

  defp inline_param(i) when is_integer(i) do
    # we add explicit casting to large integers to avoid scientific notation
    # see https://github.com/plausible/ecto_ch/issues/187
    if i > @max_uint64 or i < @min_int64 do
      Integer.to_string(i) <> "::" <> param_type(i)
    else
      Integer.to_string(i)
    end
  end

  # ClickHouse understands scientific notation
  defp inline_param(f) when is_float(f), do: Float.to_string(f)

  defp inline_param(%NaiveDateTime{microsecond: microsecond} = naive) do
    naive = NaiveDateTime.to_string(naive)

    case microsecond do
      {0, 0} -> [?', naive, "'::datetime"]
      {_, precision} -> [?', naive, "'::DateTime64(", Integer.to_string(precision), ?)]
    end
  end

  defp inline_param(%DateTime{microsecond: microsecond, time_zone: time_zone} = dt) do
    time_zone = escape_string(time_zone)
    dt = NaiveDateTime.to_string(DateTime.to_naive(dt))

    case microsecond do
      {0, 0} ->
        [?', dt, "'::DateTime('", time_zone, "')"]

      {_, precision} ->
        [?', dt, "'::DateTime64(", Integer.to_string(precision), ",'", time_zone, "')"]
    end
  end

  defp inline_param(%Date{year: year} = date) do
    suffix =
      if year < 1970 or year > 2148 do
        "'::date32"
      else
        "'::date"
      end

    [?', Date.to_string(date), suffix]
  end

  defp inline_param(%Decimal{} = dec), do: Decimal.to_string(dec, :normal)

  defp inline_param(a) when is_list(a) do
    [?[, Enum.map_intersperse(a, ?,, &inline_param/1), ?]]
  end

  defp inline_param(t) when is_tuple(t) do
    [?(, t |> Tuple.to_list() |> Enum.map_intersperse(?,, &inline_param/1), ?)]
  end

  defp inline_param(%s{}) do
    raise ArgumentError, "struct #{inspect(s)} is not supported in params"
  end

  defp inline_param(m) when is_map(m) do
    [
      "map(",
      Enum.map_intersperse(m, ?,, fn {k, v} ->
        [inline_param(k), ?,, inline_param(v)]
      end),
      ?)
    ]
  end

  defp param_type(s) when is_binary(s), do: "String"

  # https://clickhouse.com/docs/en/sql-reference/data-types/int-uint
  defp param_type(i) when is_integer(i) do
    cond do
      i > @max_uint128 -> "UInt256"
      i > @max_uint64 -> "UInt128"
      i > @max_int64 -> "UInt64"
      i < @min_int128 -> "Int256"
      i < @min_int64 -> "Int128"
      true -> "Int64"
    end
  end

  defp param_type(f) when is_float(f), do: "Float64"
  defp param_type(b) when is_boolean(b), do: "Bool"

  # TODO DateTime timezone?
  defp param_type(%s{microsecond: microsecond}) when s in [NaiveDateTime, DateTime] do
    case microsecond do
      {_val, precision} when precision > 0 ->
        ["DateTime64(", Integer.to_string(precision), ?)]

      _ ->
        "DateTime"
    end
  end

  # TODO Date32
  defp param_type(%Date{}), do: "Date"

  defp param_type(%Decimal{exp: exp}) do
    # TODO use sizes 128 and 256 as well if needed
    scale = if exp < 0, do: abs(exp), else: 0
    ["Decimal64(", Integer.to_string(scale), ?)]
  end

  defp param_type([]), do: "Array(Nothing)"

  # TODO check whole list
  defp param_type([v | _]), do: ["Array(", param_type(v), ?)]

  defp param_type(%s{}) do
    raise ArgumentError, "struct #{inspect(s)} is not supported in params"
  end

  defp param_type(m) when is_map(m) do
    case Map.keys(m) do
      # TODO check whole list
      [k | _] ->
        # TODO check whole list
        [v | _] = Map.values(m)
        ["Map(", param_type(k), ?,, param_type(v), ?)]

      [] ->
        "Map(Nothing,Nothing)"
    end
  end
end
