defmodule Ecto.Adapters.ClickHouse.Connection do
  @moduledoc false

  @behaviour Ecto.Adapters.SQL.Connection
  @dialyzer :no_improper_lists

  alias Ecto.SubQuery
  alias Ecto.Query.{QueryExpr, JoinExpr, BooleanExpr, WithExpr, Tagged}

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

  @impl true
  def query(conn, statement, params, opts) do
    Ch.query(conn, statement, params, opts)
  end

  @impl true
  def query_many(_conn, _statement, _params, _opts) do
    raise "not implemented"
  end

  @impl true
  def stream(_conn, _statement, _params, _opts) do
    raise "ClickHouse does not support cursors"
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
    combinations = combinations(query, params)
    order_by = order_by(query, sources, params)
    limit = limit(query, sources, params)
    offset = offset(query, sources, params)

    [
      cte,
      select,
      from,
      join,
      where,
      group_by,
      having,
      window,
      combinations,
      order_by,
      limit,
      offset
    ]
  end

  @dialyzer {:no_return, update_all: 1, update_all: 2}
  @impl true
  def update_all(query, _prefix \\ nil) do
    raise Ecto.QueryError,
      query: query,
      message: "ClickHouse does not support UPDATE statements -- use ALTER TABLE instead"
  end

  @impl true
  # https://clickhouse.com/docs/en/sql-reference/statements/delete
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
  # https://clickhouse.com/docs/en/sql-reference/statements/show#show-tables
  def table_exists_query(table) do
    {"SELECT name FROM system.tables WHERE name={$0:String} LIMIT 1", [table]}
  end

  @impl true
  def execute_ddl(command) do
    Ecto.Adapters.ClickHouse.Migration.execute_ddl(command)
  end

  @impl true
  # https://clickhouse.com/docs/en/sql-reference/statements/insert-into
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

    # TODO nulls as default?
    case rows do
      {%Ecto.Query{} = query, params} -> [insert, ?\s | all(query, params)]
      rows when is_list(rows) -> insert
    end
  end

  @impl true
  def update(_prefix, _table, _fields, _filters, _returning) do
    raise ArgumentError,
          "ClickHouse does not support UPDATE statements -- use ALTER TABLE instead"
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
        {{field, nil}, _} ->
          [quote_name(field), " IS NULL"]

        {{field, value}, idx} ->
          [quote_name(field), " = {$", Integer.to_string(idx), ?:, ch_typeof(value), ?}]
      end)

    ["DELETE FROM ", quote_table(prefix, table), " WHERE ", filters]
  end

  @impl true
  # https://clickhouse.com/docs/en/sql-reference/statements/explain
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
    and: " AND ",
    or: " OR ",
    ilike: " ILIKE ",
    like: " LIKE ",
    # TODO these two are not in binary_ops in sqlite3 adapter
    in: " IN ",
    is_nil: " WHERE "
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
      # TODO
      {:&, _, [idx]} ->
        {_, source, _} = elem(sources, idx)
        [source | ".*"]

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
      intersperse_map(queries, ?,, fn {name, cte} ->
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
    # TODO fast_map?
    Enum.map(joins, fn
      %JoinExpr{qual: qual, ix: ix, source: source, on: %QueryExpr{expr: on_exrp}, hints: hints} ->
        unless hints == [] do
          raise Ecto.QueryError,
            query: query,
            message: "ClickHouse does not support hints on JOIN"
        end

        {join, name} = get_source(query, sources, params, ix, source)

        [
          join_qual(qual),
          join,
          " AS ",
          name
          | join_on(qual, on_exrp, sources, params, query)
        ]
    end)
  end

  defp join_on(:cross, true, _sources, _params, _query), do: []

  defp join_on(array, true, _sources, _params, _query)
       when array in [:inner_lateral, :left_lateral] do
    []
  end

  defp join_on(_qual, expr, sources, params, query) do
    [" ON " | expr(expr, sources, params, query)]
  end

  # https://clickhouse.com/docs/en/sql-reference/statements/select/join/#supported-types-of-join
  defp join_qual(:inner), do: " INNER JOIN "
  defp join_qual(:inner_lateral), do: " ARRAY JOIN "
  defp join_qual(:left_lateral), do: " LEFT ARRAY JOIN "
  defp join_qual(:left), do: " LEFT OUTER JOIN "
  defp join_qual(:right), do: " RIGHT OUTER JOIN "
  defp join_qual(:full), do: " FULL OUTER JOIN "
  defp join_qual(:cross), do: " CROSS JOIN "

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
      | intersperse_map(group_bys, ?,, fn %QueryExpr{expr: expr} ->
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

  defp limit(%{limit: %QueryExpr{expr: expr}} = query, sources, params) do
    [" LIMIT ", expr(expr, sources, params, query)]
  end

  defp offset(%{offset: nil}, _sources, _params), do: []

  defp offset(%{offset: %QueryExpr{expr: expr}} = query, sources, params) do
    [" OFFSET ", expr(expr, sources, params, query)]
  end

  defp combinations(%{combinations: combinations}, params) do
    Enum.map(combinations, &combination(&1, params))
  end

  # TODO union distinct, etc.
  defp combination({:union, query}, params), do: [" UNION ", all(query, params)]
  defp combination({:union_all, query}, params), do: [" UNION ALL ", all(query, params)]
  defp combination({:except, query}, params), do: [" EXCEPT ", all(query, params)]
  defp combination({:intersect, query}, params), do: [" INTERSECT ", all(query, params)]

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
    [" " | intersperse_map(hints, ?,, &hint/1)]
  end

  defp hints([]), do: []

  defp hint(hint) when is_binary(hint), do: hint

  defp hint({k, v}) when is_atom(k) and is_integer(v) do
    [Atom.to_string(k), ?\s, Integer.to_string(v)]
  end

  defp boolean(_name, [], _sources, _params, _query), do: []

  defp boolean(name, [%{expr: expr, op: op} | exprs], sources, params, query) do
    result =
      Enum.reduce(exprs, {op, paren_expr(expr, sources, params, query)}, fn
        %BooleanExpr{expr: expr, op: op}, {op, acc} ->
          {op, [acc, operator_to_boolean(op) | paren_expr(expr, sources, params, query)]}

        %BooleanExpr{expr: expr, op: op}, {_, acc} ->
          {op, [?(, acc, ?), operator_to_boolean(op) | paren_expr(expr, sources, params, query)]}
      end)

    [name | elem(result, 1)]
  end

  defp operator_to_boolean(:and), do: " AND "
  defp operator_to_boolean(:or), do: " OR "

  # TODO
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
    ["{$", Integer.to_string(ix), ?:, param_type_at(params, ix), ?}]
  end

  defp expr({:^, [], [ix, _]}, _sources, params, _query) do
    ["{$", Integer.to_string(ix), ?:, param_type_at(params, ix), ?}]
  end

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

  # TODO?
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

  defp expr({:in, _, [_, {:^, _, [_, 0]}]}, _sources, _params, _query), do: "0"

  defp expr({:in, _, [left, right]}, sources, params, query) do
    [expr(left, sources, params, query), " IN ", expr(right, sources, params, query)]
  end

  defp expr({:is_nil, _, [arg]}, sources, params, query) do
    [expr(arg, sources, params, query) | " IS NULL"]
  end

  defp expr({:not, _, [expr]}, sources, params, query) do
    ["NOT (", expr(expr, sources, params, query), ?)]
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

  # TODO typecast to timestamp?
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

  # https://clickhouse.com/docs/en/sql-reference/functions/json-functions/#json_queryjson-path
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

  defp expr({fun, _, args}, sources, params, query) when is_atom(fun) and is_list(args) do
    {modifier, args} =
      case args do
        [rest, :distinct] -> {"DISTINCT ", [rest]}
        _ -> {[], args}
      end

    case handle_call(fun, length(args)) do
      {:binary_op, op} ->
        [left, right] = args

        [
          op_to_binary(left, sources, params, query),
          op | op_to_binary(right, sources, params, query)
        ]

      {:fun, fun} ->
        [fun, ?(, modifier, intersperse_map(args, ?,, &expr(&1, sources, params, query)), ?)]
    end
  end

  # TODO test, verify works
  # https://clickhouse.com/docs/en/sql-reference/data-types/array/#creating-an-array
  defp expr(list, sources, params, query) when is_list(list) do
    ["array(", intersperse_map(list, ?,, &expr(&1, sources, params, query)), ?)]
  end

  # TODO https://clickhouse.com/docs/en/sql-reference/data-types/decimal/#parameters
  defp expr(%Decimal{} = decimal, _sources, _params, _query) do
    Decimal.to_string(decimal, :normal)
  end

  # TODO test test test
  defp expr(%Tagged{value: value, type: type}, sources, params, query) do
    ["CAST(", expr(value, sources, params, query), " AS ", ecto_to_db(type), ?)]
  end

  defp expr(nil, _sources, _params, _query), do: "NULL"
  # TODO "true" / "false"?
  defp expr(true, _sources, _params, _query), do: "1"
  defp expr(false, _sources, _params, _query), do: "0"

  defp expr(literal, _sources, _params, _query) when is_binary(literal) do
    [?', escape_string(literal), ?']
  end

  defp expr(literal, _sources, _params, _query) when is_integer(literal) do
    Integer.to_string(literal)
  end

  defp expr(literal, _sources, _params, _query) when is_float(literal) do
    Float.to_string(literal)
  end

  defp expr(expr, _sources, _params, query) do
    raise Ecto.QueryError,
      query: query,
      message: "unsupported expression #{inspect(expr)}"
  end

  # TODO
  # defp interal(count, _interval, sources, query) do
  #   [expr(count, sources, query)]
  # end

  defp op_to_binary({op, _, [_, _]} = expr, sources, params, query) when op in @binary_ops do
    paren_expr(expr, sources, params, query)
  end

  defp op_to_binary({:is_nil, _, [_]} = expr, sources, params, query) do
    paren_expr(expr, sources, params, query)
  end

  defp op_to_binary(expr, sources, params, query) do
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

  import Ch.RowBinary, only: [decimal: 1, string: 1]

  defp ecto_to_db({:array, t}) do
    ["Array(", ecto_to_db(t), ?)]
  end

  defp ecto_to_db(:id), do: "UInt64"
  defp ecto_to_db(:uuid), do: "UUID"
  defp ecto_to_db(s) when s in [:string, :binary, :binary_id], do: "String"
  # when ecto migrator queries for versions in schema_versions it uses type(version, :integer)
  # so we need :integer to be the same as :bigint which is used for schema_versions table definition
  # this is why :integer is Int64 and not Int32
  defp ecto_to_db(i) when i in [:integer, :bigint], do: "Int64"
  defp ecto_to_db(:float), do: "Float64"

  defp ecto_to_db(:decimal) do
    raise ArgumentError,
          "cast to :decimal is not supported, please use Ch.Types.{Decimal32, Decimal64, Decimal128, Decimal256} instead"
  end

  defp ecto_to_db({:parameterized, :ch, type}) do
    ecto_to_db(type)
  end

  defp ecto_to_db(:boolean), do: "Bool"
  defp ecto_to_db(:date), do: "Date"
  defp ecto_to_db(:date32), do: "Date32"
  defp ecto_to_db(dt) when dt in [:datetime, :utc_datetime, :naive_datetime], do: "DateTime"
  defp ecto_to_db(:u8), do: "UInt8"
  defp ecto_to_db(:u16), do: "UInt16"
  defp ecto_to_db(:u32), do: "UInt32"
  defp ecto_to_db(:u64), do: "UInt64"
  defp ecto_to_db(:u128), do: "UInt128"
  defp ecto_to_db(:u256), do: "UInt256"
  defp ecto_to_db(:i8), do: "Int8"
  defp ecto_to_db(:i16), do: "Int16"
  defp ecto_to_db(:i32), do: "Int32"
  defp ecto_to_db(:i64), do: "Int64"
  defp ecto_to_db(:i128), do: "Int128"
  defp ecto_to_db(:i256), do: "Int256"
  defp ecto_to_db(:f32), do: "Float32"
  defp ecto_to_db(:f64), do: "Float64"

  defp ecto_to_db(decimal(size: size, scale: scale)) do
    ["Decimal", Integer.to_string(size), ?(, Integer.to_string(scale), ?)]
  end

  defp ecto_to_db(string(size: size)) do
    ["FixedString(", Integer.to_string(size), ?)]
  end

  defp ecto_to_db({:nullable, type}) do
    ["Nullable(", ecto_to_db(type), ?)]
  end

  defp ecto_to_db(other) when is_atom(other) do
    Atom.to_string(other)
  end

  defp param_type_at(params, ix) do
    value = Enum.at(params, ix)
    ch_typeof(value)
  end

  defp ch_typeof(s) when is_binary(s), do: "String"
  defp ch_typeof(i) when is_integer(i) and i > 0x7FFFFFFFFFFFFFFF, do: "UInt64"
  defp ch_typeof(i) when is_integer(i), do: "Int64"
  defp ch_typeof(f) when is_float(f), do: "Float64"
  defp ch_typeof(b) when is_boolean(b), do: "Bool"
  defp ch_typeof(%DateTime{}), do: "DateTime"
  defp ch_typeof(%Date{}), do: "Date"
  defp ch_typeof(%NaiveDateTime{}), do: "DateTime"

  defp ch_typeof(%Decimal{exp: exp}) do
    # TODO use sizes 128 and 256 as well if needed
    scale = if exp < 0, do: abs(exp), else: 0
    ["Decimal64(", Integer.to_string(scale), ?)]
  end

  defp ch_typeof([]), do: "Array(Nothing)"
  # TODO check whole list
  defp ch_typeof([v | _]), do: ["Array(", ch_typeof(v), ?)]
end
