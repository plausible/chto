defmodule Ecto.Adapters.ClickHouse.Migration do
  @moduledoc false
  alias Ecto.Migration.{Table, Reference, Index, Constraint}
  @conn Ecto.Adapters.ClickHouse.Connection

  @dialyzer :no_improper_lists

  defguardp is_create(command) when command in [:create, :create_if_not_exists]
  defguardp is_drop(command) when command in [:drop, :drop_if_exists]

  @spec execute_ddl(Ecto.Adapter.Migration.command()) :: iodata
  def execute_ddl({command, %Table{} = table, columns}) when is_create(command) do
    [
      [
        create(command, table),
        ?\s,
        table(table),
        " (",
        columns(columns),
        pk(table, columns),
        ") ",
        engine(table),
        comment(table)
      ]
    ]
  end

  def execute_ddl({command, %Table{} = table, _mode}) when is_drop(command) do
    [
      [drop(command, table), ?\s, table(table)]
    ]
  end

  def execute_ddl({:alter, %Table{} = table, changes}) do
    Enum.map(changes, fn change ->
      ["ALTER TABLE ", table(table), ?\s | column_change(change)]
    end)
  end

  def execute_ddl({command, %Index{} = index}) when is_create(command) do
    if index.unique do
      raise ArgumentError, "ClickHouse does not support UNIQUE INDEX"
    end

    if index.concurrently do
      raise ArgumentError, "ClickHouse does not support CREATE INDEX CONCURRENTLY"
    end

    [
      [
        "ALTER TABLE ",
        table(index),
        ?\s,
        add(command, index),
        ?\s,
        @conn.quote_name(index.name),
        " (",
        index_expr(index),
        ?) | index_options(index)
      ]
    ]
  end

  def execute_ddl({command, %Index{} = index, _mode}) when is_drop(command) do
    if index.unique do
      raise ArgumentError, "ClickHouse does not support UNIQUE INDEX"
    end

    if index.concurrently do
      raise ArgumentError, "ClickHouse does not support DROP INDEX CONCURRENTLY"
    end

    [
      ["ALTER TABLE ", table(index), ?\s, drop(command, index), ?\s, @conn.quote_name(index.name)]
    ]
  end

  def execute_ddl({command, %Constraint{} = constraint}) when is_create(command) do
    if constraint.comment do
      raise "ClickHouse does not support comments on constraints"
    end

    if constraint.validate do
      raise "ClickHouse does not support CHECK constraints with validation on creation"
    end

    if constraint.exclude do
      raise "ClickHouse does not support exclusion constraints"
    end

    unless constraint.check do
      raise "ClickHouse supports only CHECK constraints"
    end

    [
      [
        "ALTER TABLE ",
        table(constraint),
        ?\s,
        add(command, constraint),
        ?\s,
        @conn.quote_name(constraint.name),
        " CHECK (",
        constraint.check,
        ?)
      ]
    ]
  end

  def execute_ddl({command, %Constraint{} = constraint, _mode}) when is_drop(command) do
    [
      [
        "ALTER TABLE ",
        table(constraint),
        ?\s,
        drop(command, constraint),
        ?\s,
        @conn.quote_name(constraint.name)
      ]
    ]
  end

  def execute_ddl({:rename, %Table{} = current_table, %Table{} = new_table}) do
    cluster = cluster(current_table)
    new_cluster = cluster(new_table)

    unless cluster == new_cluster do
      raise ArgumentError, """
      RENAME TABLE requires CLUSTER to be the same for both tables: current=#{inspect(cluster)}, new=#{inspect(new_cluster)}
      """
    end

    [
      [
        "RENAME TABLE ",
        @conn.quote_table(current_table.prefix, current_table.name),
        " TO " | table(new_table)
      ]
    ]
  end

  def execute_ddl({:rename, %Table{} = table, column_name, new_column_name}) do
    [
      [
        "ALTER TABLE ",
        table(table),
        " RENAME COLUMN ",
        @conn.quote_name(column_name),
        " TO ",
        @conn.quote_name(new_column_name)
      ]
    ]
  end

  def execute_ddl(string) when is_binary(string) do
    [string]
  end

  def execute_ddl(list) when is_list(list) do
    raise ArgumentError, "ClickHouse adapter does not support lists in execute_ddl"
  end

  defp create(:create, %Table{}), do: "CREATE TABLE"
  defp create(:create_if_not_exists, %Table{}), do: "CREATE TABLE IF NOT EXISTS"
  defp drop(:drop, %Table{}), do: "DROP TABLE"
  defp drop(:drop_if_exists, %Table{}), do: "DROP TABLE IF EXISTS"
  defp drop(:drop, %Index{}), do: "DROP INDEX"
  defp drop(:drop_if_exists, %Index{}), do: "DROP INDEX IF EXISTS"
  defp drop(:drop, %Constraint{}), do: "DROP CONSTRAINT"
  defp drop(:drop_if_exists, %Constraint{}), do: "DROP CONSTRAINT IF EXISTS"
  defp add(:create, %Index{}), do: "ADD INDEX"
  defp add(:create_if_not_exists, %Index{}), do: "ADD INDEX IF NOT EXISTS"
  defp add(:create, %Constraint{}), do: "ADD CONSTRAINT"
  defp add(:create_if_not_exists, %Constraint{}), do: "ADD CONSTRAINT IF NOT EXISTS"

  def table(%Table{} = table) do
    if cluster = cluster(merge_table_options_with_defaults(table.options)) do
      [@conn.quote_table(table.prefix, table.name), " ON CLUSTER ", @conn.quote_name(cluster)]
    else
      @conn.quote_table(table.prefix, table.name)
    end
  end

  def table(%Index{} = index) do
    if cluster = cluster(merge_table_options_with_defaults(index.options)) do
      [@conn.quote_table(index.prefix, index.table), " ON CLUSTER ", @conn.quote_name(cluster)]
    else
      @conn.quote_table(index.prefix, index.table)
    end
  end

  # TODO ON CLUSTER (can't right now since constraint doesn't have :options)
  def table(%Constraint{} = constraint) do
    @conn.quote_table(constraint.prefix, constraint.table)
  end

  @cluster_options [:cluster, :on_cluster]
  defp cluster(%{options: options}), do: cluster(options)

  defp cluster(options) when is_list(options) do
    clusters =
      Enum.filter(options, fn option ->
        case option do
          {k, _} when k in @cluster_options -> true
          _ -> false
        end
      end)

    case clusters do
      [] ->
        nil

      [{_, v}] ->
        v

      [_ | _] ->
        raise ArgumentError, "multiple cluster options were provided: " <> inspect(clusters)
    end
  end

  defp cluster(_other), do: nil

  defp columns(columns) do
    @conn.intersperse_map(columns, ?,, &column_definition/1)
  end

  defp pk(%Table{} = table, columns) do
    if find_engine(table) in ["TinyLog", "Memory"], do: [], else: pk_definition(columns)
  end

  defp find_engine(%Table{} = table) do
    table.engine || Application.get_env(:ecto_ch, :default_table_engine) || "TinyLog"
  end

  defp default_table_options do
    List.wrap(Application.get_env(:ecto_ch, :default_table_options))
  end

  defp merge_table_options_with_defaults(options) do
    Keyword.merge(default_table_options(), List.wrap(options))
  end

  defp engine(%Table{} = table) do
    ["ENGINE=", find_engine(table) | engine_options(table.options)]
  end

  defp engine_options(options) when is_binary(options), do: [?\s | options]

  defp engine_options(options) when is_list(options) or is_nil(options) do
    merge_table_options_with_defaults(options)
    |> Keyword.drop(@cluster_options)
    |> Enum.map(&option_expr/1)
  end

  defp index_options(%Index{} = index), do: index_options(index.options)
  defp index_options(options) when is_binary(options), do: [?\s | options]

  defp index_options(options) when is_list(options) do
    options |> Keyword.drop(@cluster_options) |> Enum.map(&option_expr/1)
  end

  defp index_options(nil), do: []

  defp option_expr({k, v}) do
    k = to_string(k) |> String.split("_") |> Enum.map(&String.upcase/1) |> Enum.intersperse(?\s)
    [?\s, k, ?\s, to_string(v)]
  end

  defp comment(%Table{} = table) do
    if comment = table.comment do
      [" COMMENT '", @conn.escape_string(comment), ?']
    else
      []
    end
  end

  defp pk_definition(columns) do
    pk_columns =
      Enum.filter(columns, fn {_, _, _, opts} ->
        case Keyword.get(opts, :primary_key, false) do
          true = t -> t
          false = f -> f
        end
      end)

    case pk_columns do
      [] = empty ->
        empty

      pk_columns ->
        pk_expr =
          pk_columns
          |> Enum.map(fn {_, name, type, _} ->
            if type in [:serial, :bigserial] do
              raise ArgumentError,
                    "type #{inspect(type)} is not supported as ClickHouse does not support AUTOINCREMENT"
            end

            @conn.quote_name(name)
          end)
          |> Enum.intersperse(?,)

        [",PRIMARY KEY (", pk_expr, ?)]
    end
  end

  defp column_definition({:add, _name, %Reference{}, _opts}) do
    raise ArgumentError, "ClickHouse does not support FOREIGN KEY"
  end

  defp column_definition({:add, name, type, opts}) do
    [@conn.quote_name(name), ?\s, column_type(type) | column_options(type, opts)]
  end

  # TODO collate support?
  defp column_options(type, opts) do
    default = Keyword.fetch(opts, :default)
    null = Keyword.get(opts, :null)
    [default_expr(default, type), null_expr(null)]
  end

  defp column_change({:add, _name, %Reference{}, _opts}) do
    raise ArgumentError, "ClickHouse does not support FOREIGN KEY"
  end

  defp column_change({:add, name, type, opts}) do
    [
      "ADD COLUMN ",
      @conn.quote_name(name),
      ?\s,
      column_type(type)
      | column_options(type, opts)
    ]
  end

  defp column_change({:modify, _name, %Reference{}, _opts}) do
    raise ArgumentError, "ClickHouse does not support FOREIGN KEY"
  end

  defp column_change({:modify, name, type, opts}) do
    [
      "MODIFY COLUMN ",
      @conn.quote_name(name),
      ?\s,
      column_type(type),
      modify_default(name, type, opts)
      | modify_null(name, opts)
    ]
  end

  defp column_change({:remove, name}) do
    ["DROP COLUMN " | @conn.quote_name(name)]
  end

  # TODO
  defp column_change({:remove, name, _type, _opts}) do
    column_change({:remove, name})
  end

  defp modify_null(_name, opts) do
    case Keyword.get(opts, :null) do
      nil -> []
      val -> null_expr(val)
    end
  end

  defp modify_default(name, type, opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, _val} = ok ->
        [" ADD ", default_expr(ok, type), " FOR ", @conn.quote_name(name)]

      :error ->
        []
    end
  end

  defp null_expr(true), do: " NULL"
  defp null_expr(false), do: " NOT NULL"
  defp null_expr(_), do: []

  @dialyzer {:no_improper_lists, default_expr: 2}
  defp default_expr({:ok, nil}, _type) do
    " DEFAULT NULL"
  end

  defp default_expr({:ok, literal}, _type) when is_binary(literal) do
    [" DEFAULT '", @conn.escape_string(literal), ?']
  end

  defp default_expr({:ok, literal}, _type) when is_number(literal) do
    [" DEFAULT " | to_string(literal)]
  end

  defp default_expr({:ok, {:fragment, expr}}, _type) do
    [" DEFAULT " | expr]
  end

  defp default_expr({:ok, true}, _type) do
    " DEFAULT 1"
  end

  defp default_expr({:ok, false}, _type) do
    " DEFAULT 0"
  end

  defp default_expr({:ok, list}, _type) when is_list(list) do
    raise ArgumentError,
          "ClickHouse adapter does not support lists in :default, " <>
            "use fragments instead"
  end

  defp default_expr({:ok, map}, _type) when is_map(map) do
    raise ArgumentError,
          "ClickHouse adapter does not support maps in :default, " <>
            "use fragments instead"
  end

  defp default_expr(:error, _), do: []

  defp index_expr(%Index{} = index), do: @conn.intersperse_map(index.columns, ?,, &index_expr/1)
  defp index_expr(literal) when is_binary(literal), do: literal
  defp index_expr(literal), do: @conn.quote_name(literal)

  defp column_type(type) when type in [:serial, :bigserial] do
    raise ArgumentError,
          "type #{inspect(type)} is not supported as ClickHouse does not support AUTOINCREMENT"
  end

  defp column_type(:id) do
    raise ArgumentError, "type :id is ambiguous, use a literal (e.g. :Int64 or :UInt64) instead"
  end

  defp column_type(:numeric) do
    raise ArgumentError, "type :numeric is not supported"
  end

  defp column_type(:time) do
    raise ArgumentError, "type :time is not supported"
  end

  defp column_type(:map) do
    raise ArgumentError,
          ~s[type :map is ambiguous, use a literal (e.g. :JSON or :"Map(String, UInt8)") instead]
  end

  defp column_type(:decimal) do
    raise ArgumentError,
          ~s[type :decimal is ambiguous, use a literal (e.g. :"Decimal(p, s)") instead]
  end

  defp column_type(:uuid), do: "UUID"
  defp column_type(:boolean), do: "Bool"
  defp column_type(:integer), do: "Int32"
  defp column_type(:bigint), do: "Int64"

  defp column_type(type) when type in [:string, :binary, :binary_id] do
    "String"
  end

  defp column_type(:float), do: "Float64"

  defp column_type({:array, type}) do
    ["Array(", column_type(type), ?)]
  end

  # TODO DateTime('UTC')
  defp column_type(:utc_datetime), do: "DateTime"
  defp column_type(:utc_datetime_usec), do: "DateTime64(6)"
  defp column_type(:naive_datetime), do: "DateTime"
  defp column_type(:naive_datetime_usec), do: "DateTime64(6)"
  defp column_type(type), do: Atom.to_string(type)
end
