defmodule EctoCh.Test do
  use ExUnit.Case, async: true

  import Ecto.Query
  alias Ecto.Adapters.ClickHouse.Connection, as: SQL
  alias EctoClickHouse.Integration.Product

  doctest Ecto.Adapters.ClickHouse

  describe "all" do
    test "select one column" do
      query = select("events", [e], e.name)
      # TODO drop AS?
      assert all(query) == {~s[SELECT e0."name" FROM "events" AS e0], []}
    end

    test "select two columns" do
      query = select("events", [e], map(e, [:name, :user_id]))
      assert all(query) == {~s[SELECT e0."name",e0."user_id" FROM "events" AS e0], []}
    end

    test "limit" do
      query = "events" |> select([e], e.name) |> limit(1)
      assert all(query) == {~s[SELECT e0."name" FROM "events" AS e0 LIMIT 1], []}
    end

    test "where with typed param" do
      name = "John"
      min_user_id = 10

      query =
        "events"
        |> where(name: ^name)
        |> where([e], e.user_id > ^min_user_id)
        |> select([e], e.user_id)

      assert all(query) ==
               {~s[SELECT e0."user_id" FROM "events" AS e0 WHERE (e0."name" = {$0:String}) AND (e0."user_id" > {$1:Int64})],
                ["John", 10]}
    end

    test "where with fragment" do
      name = "John"

      query =
        "events"
        |> where([e], fragment("name = ?", ^name))
        |> select([e], e.user_id)

      assert all(query) ==
               {~s[SELECT e0."user_id" FROM "events" AS e0 WHERE name = {$0:String}], ["John"]}
    end

    test "where in" do
      domains = ["dummy.site", "dummy2.site"]
      tags = ["1", "2", "3"]
      date_range = %{first: ~D[2020-10-10], last: ~D[2021-01-01]}

      query =
        from e in "events",
          where: e.domain in ^domains,
          where: e.tags == ^tags,
          where: fragment("toDate(?)", e.inserted_at) >= ^date_range.first,
          where: fragment("toDate(?)", e.inserted_at) <= ^date_range.last,
          select: {
            fragment("countIf(? = 'pageview')", e.type),
            fragment("countIf(? != 'pageview')", e.type)
          }

      assert all(query) ==
               {
                 """
                 SELECT \
                 countIf(e0."type" = 'pageview'),\
                 countIf(e0."type" != 'pageview') \
                 FROM "events" AS e0 \
                 WHERE (\
                 e0."domain" IN ({$0:String},{$1:String})) AND \
                 (e0."tags" = {$2:Array(String)}) AND \
                 (toDate(e0."inserted_at") >= {$3:Date}) AND \
                 (toDate(e0."inserted_at") <= {$4:Date}\
                 )\
                 """,
                 [
                   "dummy.site",
                   "dummy2.site",
                   ["1", "2", "3"],
                   ~D[2020-10-10],
                   ~D[2021-01-01]
                 ]
               }
    end

    test "where array =" do
      domains = ["dummy.site", "dummy2.site"]
      query = "events" |> where(domains: ^domains) |> select([e], e.user_id)

      assert all(query) ==
               {~s[SELECT e0."user_id" FROM "events" AS e0 WHERE (e0."domains" = {$0:Array(String)})],
                [["dummy.site", "dummy2.site"]]}
    end

    test "where schema.array =" do
      tags = ["a", "b"]
      query = Product |> where(tags: ^tags) |> select([p], p.name)

      assert all(query) ==
               {~s[SELECT p0."name" FROM "products" AS p0 WHERE (p0."tags" = {$0:Array(String)})],
                [["a", "b"]]}
    end
  end

  defp all(query) do
    to_sql(query, fn query, params -> SQL.all(query, params) end)
  end

  defp to_sql(query, f) do
    {query, params, _key} = Ecto.Query.Planner.plan(query, :all, Ecto.Adapters.ClickHouse)
    {query, _} = Ecto.Query.Planner.normalize(query, :all, Ecto.Adapters.ClickHouse, _counter = 0)
    {dump_params, _} = Enum.unzip(params)
    {IO.iodata_to_binary(f.(query, dump_params)), dump_params}
  end

  def i(query) do
    IO.inspect(Map.from_struct(query), limit: :infinity)
  end

  test "to_sql" do
    user_id = 1
    query = "example" |> where([e], e.user_id == ^user_id) |> select([e], e.name)
    assert {sql, params} = Ecto.Integration.TestRepo.to_sql(:all, query)
    assert sql == ~s[SELECT e0."name" FROM "example" AS e0 WHERE (e0."user_id" = {$0:Int64})]
    assert params == [1]
  end
end
