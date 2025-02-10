defmodule Ecto.Adapters.ClickHouse.ExtractStatementsTest do
  use ExUnit.Case, async: true
  import Ecto.Adapters.ClickHouse.Connection, only: [extract_statements: 1]

  test "extract_statements/1" do
    assert extract_statements("") == []

    assert extract_statements("select 1") == ["select 1"]
    assert extract_statements("select 1;") == ["select 1"]

    assert extract_statements("select 1; select 2") == ["select 1", "select 2"]
    assert extract_statements("select 1; select 2;") == ["select 1", "select 2"]
    assert extract_statements("select 1;; select 2;") == ["select 1", "select 2"]
    assert extract_statements("select 1; ; select 2;") == ["select 1", "select 2"]
    assert extract_statements("select 1; ; select 2 ;") == ["select 1", "select 2"]
    assert extract_statements("select 1; ; select 2; ;") == ["select 1", "select 2"]

    assert extract_statements("select 1; select 2; select 3;") == [
             "select 1",
             "select 2",
             "select 3"
           ]

    assert extract_statements("select 'a; b'; select 2;") == ["select 'a; b'", "select 2"]
    assert extract_statements("select '`a; b`'; select 2;") == ["select '`a; b`'", "select 2"]
    assert extract_statements("select '`a`; `b`'; select 2;") == ["select '`a`; `b`'", "select 2"]

    # sanity check
    assert ~S[select 'DO NOT RUN THIS: \'; drop table events\''] ==
             "select 'DO NOT RUN THIS: \\'; drop table events\\''"

    assert extract_statements(~S[select 'DO NOT RUN THIS: \'; drop table events\'']) == [
             ~S[select 'DO NOT RUN THIS: \'; drop table events\'']
           ]

    assert extract_statements("select `funny_columns;`; select 2;") == [
             "select `funny_columns;`",
             "select 2"
           ]

    assert extract_statements("select \"funny_columns;\"; select 2;") == [
             "select \"funny_columns;\"",
             "select 2"
           ]

    assert extract_statements("""
           -- imagine a comment here and it's ; select 'YOLO'; drop table events
           select 1; -- imagine a comment here too; select 'YOLO x2'; drop table events_v2

           select 2;
           """) == [
             """
             -- imagine a comment here and it's ; select 'YOLO'; drop table events
             select 1\
             """,
             """
             -- imagine a comment here too; select 'YOLO x2'; drop table events_v2

             select 2\
             """
           ]

    assert extract_statements("""
           select 1;
           select 2 -- unterminated ;;;;;;; comment;
           """) == ["select 1", "select 2 -- unterminated ;;;;;;; comment;"]

    assert extract_statements("""
           select /* comment; another /* comment within; comment */ */ 1; select 2;
           """) == ["select /* comment; another /* comment within; comment */ */ 1", "select 2"]
  end
end
