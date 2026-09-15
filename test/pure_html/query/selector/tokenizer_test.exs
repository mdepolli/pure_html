defmodule PureHTML.Query.Selector.TokenizerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector.Tokenizer

  describe "tokenize/1" do
    test "tag selector" do
      assert Tokenizer.tokenize("div") == {:ok, [{:ident, "div"}]}
      assert Tokenizer.tokenize("p") == {:ok, [{:ident, "p"}]}
      assert Tokenizer.tokenize("my-element") == {:ok, [{:ident, "my-element"}]}
    end

    test "universal selector" do
      assert Tokenizer.tokenize("*") == {:ok, [:star]}
    end

    test "class selector" do
      assert Tokenizer.tokenize(".foo") == {:ok, [{:class, "foo"}]}
      assert Tokenizer.tokenize(".my-class") == {:ok, [{:class, "my-class"}]}
    end

    test "id selector" do
      assert Tokenizer.tokenize("#bar") == {:ok, [{:id, "bar"}]}
      assert Tokenizer.tokenize("#my-id") == {:ok, [{:id, "my-id"}]}
    end

    test "compound selector" do
      assert Tokenizer.tokenize("div.foo") == {:ok, [{:ident, "div"}, {:class, "foo"}]}
      assert Tokenizer.tokenize("div#bar") == {:ok, [{:ident, "div"}, {:id, "bar"}]}

      assert Tokenizer.tokenize("div.foo#bar") ==
               {:ok, [{:ident, "div"}, {:class, "foo"}, {:id, "bar"}]}

      assert Tokenizer.tokenize(".foo.bar") == {:ok, [{:class, "foo"}, {:class, "bar"}]}
    end

    test "attribute selector - existence" do
      assert Tokenizer.tokenize("[href]") ==
               {:ok, [:open_bracket, {:ident, "href"}, :close_bracket]}
    end

    test "attribute selector - exact match" do
      assert Tokenizer.tokenize("[type=text]") ==
               {:ok,
                [
                  :open_bracket,
                  {:ident, "type"},
                  :equal,
                  {:ident, "text"},
                  :close_bracket
                ]}
    end

    test "attribute selector - exact match with quoted value" do
      assert Tokenizer.tokenize("[type=\"text\"]") ==
               {:ok,
                [
                  :open_bracket,
                  {:ident, "type"},
                  :equal,
                  {:string, "text"},
                  :close_bracket
                ]}

      assert Tokenizer.tokenize("[type='text']") ==
               {:ok,
                [
                  :open_bracket,
                  {:ident, "type"},
                  :equal,
                  {:string, "text"},
                  :close_bracket
                ]}
    end

    test "attribute selector - prefix match" do
      assert Tokenizer.tokenize("[href^=https]") ==
               {:ok,
                [
                  :open_bracket,
                  {:ident, "href"},
                  :prefix_match,
                  {:ident, "https"},
                  :close_bracket
                ]}
    end

    test "attribute selector - suffix match" do
      assert Tokenizer.tokenize("[href$=.pdf]") ==
               {:ok,
                [
                  :open_bracket,
                  {:ident, "href"},
                  :suffix_match,
                  {:ident, ".pdf"},
                  :close_bracket
                ]}
    end

    test "attribute selector - substring match" do
      assert Tokenizer.tokenize("[href*=example]") ==
               {:ok,
                [
                  :open_bracket,
                  {:ident, "href"},
                  :substring_match,
                  {:ident, "example"},
                  :close_bracket
                ]}
    end

    test "selector list" do
      # Whitespace after comma is preserved (parser handles normalization)
      assert Tokenizer.tokenize(".a, .b") ==
               {:ok, [{:class, "a"}, :comma, :whitespace, {:class, "b"}]}

      assert Tokenizer.tokenize("div, p, span") ==
               {:ok,
                [
                  {:ident, "div"},
                  :comma,
                  :whitespace,
                  {:ident, "p"},
                  :comma,
                  :whitespace,
                  {:ident, "span"}
                ]}

      # No whitespace when selectors are adjacent
      assert Tokenizer.tokenize(".a,.b") == {:ok, [{:class, "a"}, :comma, {:class, "b"}]}
    end

    test "complex compound selector" do
      assert Tokenizer.tokenize("div.foo#bar[data-id]") ==
               {:ok,
                [
                  {:ident, "div"},
                  {:class, "foo"},
                  {:id, "bar"},
                  :open_bracket,
                  {:ident, "data-id"},
                  :close_bracket
                ]}
    end

    test "leading and trailing whitespace is stripped" do
      assert Tokenizer.tokenize("  div  ") == {:ok, [{:ident, "div"}]}
    end

    test "internal whitespace is preserved as tokens" do
      # Whitespace around commas is preserved (parser handles normalization)
      assert Tokenizer.tokenize(".a , .b") ==
               {:ok,
                [
                  {:class, "a"},
                  :whitespace,
                  :comma,
                  :whitespace,
                  {:class, "b"}
                ]}

      # Whitespace between selectors becomes :whitespace (descendant combinator)
      assert Tokenizer.tokenize("div p") == {:ok, [{:ident, "div"}, :whitespace, {:ident, "p"}]}
    end

    test "combinator tokens" do
      assert Tokenizer.tokenize("div > p") ==
               {:ok,
                [
                  {:ident, "div"},
                  :whitespace,
                  :child,
                  :whitespace,
                  {:ident, "p"}
                ]}

      assert Tokenizer.tokenize("h1 + p") ==
               {:ok,
                [
                  {:ident, "h1"},
                  :whitespace,
                  :adjacent_sibling,
                  :whitespace,
                  {:ident, "p"}
                ]}

      assert Tokenizer.tokenize("h1 ~ p") ==
               {:ok,
                [
                  {:ident, "h1"},
                  :whitespace,
                  :general_sibling,
                  :whitespace,
                  {:ident, "p"}
                ]}

      # Without surrounding whitespace
      assert Tokenizer.tokenize("div>p") == {:ok, [{:ident, "div"}, :child, {:ident, "p"}]}
    end

    test "returns an error for an empty class selector" do
      assert {:error, {:invalid_selector, "expected an identifier after '.'"}} =
               Tokenizer.tokenize(".")
    end

    test "returns an error for an empty id selector" do
      assert {:error, {:invalid_selector, "expected an identifier after '#'"}} =
               Tokenizer.tokenize("#")
    end

    test "returns an error for an unterminated string" do
      assert {:error, {:invalid_selector, "unterminated string"}} =
               Tokenizer.tokenize("[href=\"test]")
    end

    test "reads non-ASCII identifiers" do
      assert Tokenizer.tokenize(".café") == {:ok, [{:class, "café"}]}
      assert Tokenizer.tokenize("日本") == {:ok, [{:ident, "日本"}]}
    end
  end
end
