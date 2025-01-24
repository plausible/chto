defmodule Ecto.Integration.BinaryTypeTest do
  use Ecto.Integration.Case, async: true
  import Ecto.Query
  alias Ecto.Integration.TestRepo

  test "it works" do
    TestRepo.query!("CREATE TABLE binary_test(bin String) ENGINE = Memory")
    on_exit(fn -> TestRepo.query!("DROP TABLE binary_test") end)

    bin = "\x61\xF0\x80\x80\x80b"
    TestRepo.query!(["INSERT INTO binary_test(bin) FORMAT RowBinary\n", byte_size(bin) | bin])

    assert TestRepo.one(
             from t in "binary_test",
               select: %{
                 default: t.bin,
                 type_binary: type(t.bin, :binary),
                 length: fragment("length(?)", t.bin)
               }
           ) == %{
             default: _utf8_escaped = "a�b",
             type_binary: bin,
             length: _original_length = length(6)
           }
  end
end
