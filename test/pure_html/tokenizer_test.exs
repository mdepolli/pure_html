defmodule PureHTML.TokenizerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Tokenizer

  describe "basic tokenization" do
    test "simple tag" do
      tokens = Tokenizer.tokenize("<p>Hello</p>") |> Enum.to_list()

      assert {:start_tag, "p", [], false} in tokens
      assert {:end_tag, "p"} in tokens
    end

    test "doctype" do
      assert [{:doctype, "html", nil, nil, false}] =
               Tokenizer.tokenize("<!DOCTYPE html>") |> Enum.to_list()
    end

    test "attributes" do
      [{:start_tag, "div", attrs, false}] =
        Tokenizer.tokenize("<div class=\"foo\" id=bar>") |> Enum.to_list()

      # Attributes are returned as a list of tuples (order may vary due to prepending)
      assert {"class", "foo"} in attrs
      assert {"id", "bar"} in attrs
    end

    test "self-closing tag" do
      assert [{:start_tag, "br", [], true}] =
               Tokenizer.tokenize("<br/>") |> Enum.to_list()
    end

    test "comment" do
      assert [{:comment, " hello "}] =
               Tokenizer.tokenize("<!-- hello -->") |> Enum.to_list()
    end
  end

  describe "character handling" do
    test "emits coalesced character tokens" do
      tokens = Tokenizer.tokenize("abc") |> Enum.to_list()

      assert [{:character, "abc"}] = tokens
    end

    test "counts a control character in the input stream once" do
      assert %{error_count: 1} = Tokenizer.new("a\x01b")
    end

    test "counts a noncharacter in the input stream once" do
      assert %{error_count: 1} = Tokenizer.new(<<0xFDD0::utf8>>)
    end

    test "does not count ASCII whitespace or NUL as input stream errors" do
      assert %{error_count: 0} = Tokenizer.new("\t\n\f \0")
    end

    @tag timeout: 5_000
    test "named character references stay linear before a long ASCII run" do
      # Arrange
      html = String.duplicate("&amp;", 20_000) <> String.duplicate("a", 400_000)

      # Act
      tokens = Enum.to_list(Tokenizer.tokenize(html))

      # Assert
      assert [{:character, text}] = tokens
      assert byte_size(text) == 420_000
    end
  end

  describe "tokenize_with_errors/2" do
    test "returns the tokens and the parse error count" do
      assert {[{:start_tag, "p", [], false}, {:character, "x"}], 0} =
               Tokenizer.tokenize_with_errors("<p>x")
    end

    test "unquoted equals in an attribute value is a parse error" do
      assert {[{:start_tag, "z", [{"z", "z=z"}], false}], 1} =
               Tokenizer.tokenize_with_errors("<z z=z=z>")
    end

    test "CR numeric character reference is a control-character-reference" do
      assert {[{:character, "\r"}], 1} = Tokenizer.tokenize_with_errors("&#13;")
    end

    test "NUL in a bogus doctype is an unexpected-null-character" do
      assert {[{:doctype, "a", nil, nil, true}], 2} =
               Tokenizer.tokenize_with_errors("<!DOCTYPE a \0")
    end

    test "duplicate attributes on an end tag count as well as end-tag-with-attributes" do
      assert {[{:end_tag, "x"}], 2} = Tokenizer.tokenize_with_errors("</x x x>")
    end

    test "attribute names on an end tag are lowercased before the duplicate check" do
      assert {[{:end_tag, "x"}], 2} = Tokenizer.tokenize_with_errors("</x x X>")
    end

    test "a discarded duplicate attribute still consumes its value" do
      assert {[{:start_tag, "a", [{"b", "1"}], false}], 1} =
               Tokenizer.tokenize_with_errors("<a b=1 b=2>")
    end
  end

  describe "tag names" do
    test "lowercases tag names" do
      assert [{:start_tag, "div", [], false}] =
               Tokenizer.tokenize("<DIV>") |> Enum.to_list()
    end
  end

  describe "attributes" do
    test "double-quoted attribute value" do
      assert [{:start_tag, "a", [{"href", "http://example.com"}], false}] =
               Tokenizer.tokenize("<a href=\"http://example.com\">") |> Enum.to_list()
    end

    test "single-quoted attribute value" do
      assert [{:start_tag, "a", [{"href", "http://example.com"}], false}] =
               Tokenizer.tokenize("<a href='http://example.com'>") |> Enum.to_list()
    end

    test "unquoted attribute value" do
      assert [{:start_tag, "input", [{"type", "text"}], false}] =
               Tokenizer.tokenize("<input type=text>") |> Enum.to_list()
    end

    test "attribute without value" do
      assert [{:start_tag, "input", [{"disabled", ""}], false}] =
               Tokenizer.tokenize("<input disabled>") |> Enum.to_list()
    end

    test "multiple attributes" do
      [{:start_tag, "input", attrs, false}] =
        Tokenizer.tokenize("<input type=text name=foo disabled>") |> Enum.to_list()

      # Verify all expected attributes are present
      assert {"type", "text"} in attrs
      assert {"name", "foo"} in attrs
      assert {"disabled", ""} in attrs
    end
  end
end
