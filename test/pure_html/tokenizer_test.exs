defmodule PureHtml.TokenizerTest do
  use ExUnit.Case, async: true

  alias PureHtml.Tokenizer

  describe "basic tokenization" do
    test "simple tag" do
      tokens = Tokenizer.tokenize("<p>Hello</p>") |> Enum.to_list()

      assert {:start_tag, "p", %{}, false} in tokens
      assert {:end_tag, "p"} in tokens
    end

    test "doctype" do
      assert [{:doctype, "html", nil, nil, false}] =
               Tokenizer.tokenize("<!DOCTYPE html>") |> Enum.to_list()
    end

    test "attributes" do
      assert [{:start_tag, "div", %{"class" => "foo", "id" => "bar"}, false}] =
               Tokenizer.tokenize("<div class=\"foo\" id=bar>") |> Enum.to_list()
    end

    test "self-closing tag" do
      assert [{:start_tag, "br", %{}, true}] =
               Tokenizer.tokenize("<br/>") |> Enum.to_list()
    end

    test "comment" do
      assert [{:comment, " hello "}] =
               Tokenizer.tokenize("<!-- hello -->") |> Enum.to_list()
    end
  end

  describe "character handling" do
    test "emits character tokens" do
      tokens = Tokenizer.tokenize("abc") |> Enum.to_list()

      assert [{:character, "a"}, {:character, "b"}, {:character, "c"}] = tokens
    end
  end

  describe "tag names" do
    test "lowercases tag names" do
      assert [{:start_tag, "div", %{}, false}] =
               Tokenizer.tokenize("<DIV>") |> Enum.to_list()
    end
  end

  describe "attributes" do
    test "double-quoted attribute value" do
      assert [{:start_tag, "a", %{"href" => "http://example.com"}, false}] =
               Tokenizer.tokenize("<a href=\"http://example.com\">") |> Enum.to_list()
    end

    test "single-quoted attribute value" do
      assert [{:start_tag, "a", %{"href" => "http://example.com"}, false}] =
               Tokenizer.tokenize("<a href='http://example.com'>") |> Enum.to_list()
    end

    test "unquoted attribute value" do
      assert [{:start_tag, "input", %{"type" => "text"}, false}] =
               Tokenizer.tokenize("<input type=text>") |> Enum.to_list()
    end

    test "attribute without value" do
      assert [{:start_tag, "input", %{"disabled" => ""}, false}] =
               Tokenizer.tokenize("<input disabled>") |> Enum.to_list()
    end

    test "multiple attributes" do
      assert [
               {:start_tag, "input", %{"type" => "text", "name" => "foo", "disabled" => ""},
                false}
             ] =
               Tokenizer.tokenize("<input type=text name=foo disabled>") |> Enum.to_list()
    end
  end

  describe "real-world HTML" do
    @tag :benchmark
    test "tokenizes Wikipedia homepage" do
      html = File.stream!("test/fixtures/wikipedia_homepage.html") |> Enum.join()
      file_size = byte_size(html)

      {time_us, tokens} =
        :timer.tc(fn ->
          html |> Tokenizer.tokenize() |> Enum.to_list()
        end)

      time_ms = time_us / 1000
      tokens_count = length(tokens)
      throughput_mb_s = file_size / 1024 / 1024 / (time_us / 1_000_000)

      IO.puts("\n  Wikipedia homepage benchmark:")
      IO.puts("    File size: #{Float.round(file_size / 1024, 1)} KB")
      IO.puts("    Tokens: #{tokens_count}")
      IO.puts("    Time: #{Float.round(time_ms, 2)} ms")
      IO.puts("    Throughput: #{Float.round(throughput_mb_s, 2)} MB/s")

      assert tokens_count > 0
      assert Enum.any?(tokens, &match?({:doctype, _, _, _, _}, &1))
      assert Enum.any?(tokens, &match?({:start_tag, "html", _, _}, &1))
    end
  end
end
