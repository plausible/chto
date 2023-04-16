defmodule Ecto.Integration.UnionTest do
  use Ecto.Integration.Case
  import Ecto.Query

  alias Ecto.Integration.TestRepo
  alias Ecto.Integration.Post

  test "union & ordering" do
    TestRepo.insert!(%Post{title: "hello", counter: 1, public: true})
    TestRepo.insert!(%Post{title: "morning", counter: 2, public: true})

    TestRepo.insert!(%Post{title: "bye", counter: 3, public: false})

    other =
      from(
        p in Post,
        where: p.public,
        order_by: p.counter,
        limit: 1,
        select: p.title
      )

    query =
      from(
        p in Post,
        union_all: ^other,
        where: not p.public,
        order_by: p.counter,
        select: p.title,
        limit: 1
      )

    {sql, _} = TestRepo.to_sql(:all, query)
    IO.puts(sql)

    data = TestRepo.all(query)
    assert data == ["hello", "bye"]
  end
end
