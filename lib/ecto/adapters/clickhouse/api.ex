defmodule Ecto.Adapters.ClickHouse.API do
  @moduledoc """
  Helpers for building Ecto queries for ClickHouse.
  """

  import Ecto.Query

  @doc """
  Builds an [`input(structure)`](https://clickhouse.com/docs/en/sql-reference/table-functions/input) that can be used in `Ecto.Query.from`

      from i in input(a: "Int16", b: :string)
      from i in input(Schema)

  """
  def input(schema) when is_list(schema) do
    structure =
      schema
      |> Enum.map(fn {name, type} ->
        type =
          case type do
            _ when is_binary(type) -> type
            _ -> Ch.Types.encode(type)
          end

        IO.iodata_to_binary([to_string(name), ?\s, type])
      end)
      |> Enum.join(", ")

    %Ecto.Query{from: %Ecto.Query.FromExpr{source: {:fragment, _ctx = [], fragment}} = from} =
      query = from(fragment("input(?)", literal(^structure)))

    # TODO or maybe build query struct manually with a custom :fragment (like a custom op)
    #      which would be handled in connection.ex
    %{query | from: %{from | source: {:fragment, [input: schema], fragment}}}
  end

  def input(schema) when is_atom(schema) do
    query =
      schema.__schema__(:fields)
      |> Enum.map(fn field ->
        type = schema.__schema__(:type, field)
        type || raise "missing type for field " <> inspect(field)
        {field, Ecto.Adapters.ClickHouse.Schema.remap_type(type, schema, field)}
      end)
      |> input()

    # TODO
    # %{query | sources: {nil, schema}}
    query
  end

  @doc """
  Builds a common table expression with an (constant) expression instead of a subquery.

  `with_query` must be a fragment to be evaluated as an expression.

  ## Options

  - as: must be a compile-time literal string that is used in the main query to select
  the static value.

  https://clickhouse.com/docs/en/sql-reference/statements/select/with#syntax
  """
  defmacro with_cte_expression(query, with_query, opts) do
    name = opts[:as]

    if !name do
      Ecto.Query.Builder.error!("`as` option must be specified")
    end

    # :HACK: We override the operation to :update_all to pass context to the connection.
    # :update_all is not used within ClickHouse adapter otherwise.
    Ecto.Query.Builder.CTE.build(
      query,
      name,
      with_query,
      opts[:materialized],
      :update_all,
      __CALLER__
    )
  end
end
