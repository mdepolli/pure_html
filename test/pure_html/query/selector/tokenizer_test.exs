defmodule PureHTML.Query.Selector.TokenizerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector.Tokenizer

  describe "tokenize/1" do
    test "tag selector" do
      assert Tokenizer.tokenize("div") == [{:ident, "div"}]
      assert Tokenizer.tokenize("p") == [{:ident, "p"}]
      assert Tokenizer.tokenize("my-element") == [{:ident, "my-element"}]
    end

    test "universal selector" do
      assert Tokenizer.tokenize("*") == [:star]
    end

    test "class selector" do
      assert Tokenizer.tokenize(".foo") == [{:class, "foo"}]
      assert Tokenizer.tokenize(".my-class") == [{:class, "my-class"}]
    end

    test "id selector" do
      assert Tokenizer.tokenize("#bar") == [{:id, "bar"}]
      assert Tokenizer.tokenize("#my-id") == [{:id, "my-id"}]
    end

    test "compound selector" do
      assert Tokenizer.tokenize("div.foo") == [{:ident, "div"}, {:class, "foo"}]
      assert Tokenizer.tokenize("div#bar") == [{:ident, "div"}, {:id, "bar"}]
      assert Tokenizer.tokenize("div.foo#bar") == [{:ident, "div"}, {:class, "foo"}, {:id, "bar"}]
      assert Tokenizer.tokenize(".foo.bar") == [{:class, "foo"}, {:class, "bar"}]
    end

    test "attribute selector - existence" do
      assert Tokenizer.tokenize("[href]") == [:open_bracket, {:ident, "href"}, :close_bracket]
    end

    test "attribute selector - exact match" do
      assert Tokenizer.tokenize("[type=text]") == [
               :open_bracket,
               {:ident, "type"},
               :equal,
               {:ident, "text"},
               :close_bracket
             ]
    end

    test "attribute selector - exact match with quoted value" do
      assert Tokenizer.tokenize("[type=\"text\"]") == [
               :open_bracket,
               {:ident, "type"},
               :equal,
               {:string, "text"},
               :close_bracket
             ]

      assert Tokenizer.tokenize("[type='text']") == [
               :open_bracket,
               {:ident, "type"},
               :equal,
               {:string, "text"},
               :close_bracket
             ]
    end

    test "attribute selector - prefix match" do
      assert Tokenizer.tokenize("[href^=https]") == [
               :open_bracket,
               {:ident, "href"},
               :prefix_match,
               {:ident, "https"},
               :close_bracket
             ]
    end

    test "attribute selector - suffix match" do
      assert Tokenizer.tokenize("[href$=.pdf]") == [
               :open_bracket,
               {:ident, "href"},
               :suffix_match,
               {:ident, ".pdf"},
               :close_bracket
             ]
    end

    test "attribute selector - substring match" do
      assert Tokenizer.tokenize("[href*=example]") == [
               :open_bracket,
               {:ident, "href"},
               :substring_match,
               {:ident, "example"},
               :close_bracket
             ]
    end

    test "selector list" do
      assert Tokenizer.tokenize(".a, .b") == [{:class, "a"}, :comma, {:class, "b"}]

      assert Tokenizer.tokenize("div, p, span") == [
               {:ident, "div"},
               :comma,
               {:ident, "p"},
               :comma,
               {:ident, "span"}
             ]
    end

    test "complex compound selector" do
      assert Tokenizer.tokenize("div.foo#bar[data-id]") == [
               {:ident, "div"},
               {:class, "foo"},
               {:id, "bar"},
               :open_bracket,
               {:ident, "data-id"},
               :close_bracket
             ]
    end

    test "whitespace is skipped" do
      assert Tokenizer.tokenize("  div  ") == [{:ident, "div"}]
      assert Tokenizer.tokenize(".a , .b") == [{:class, "a"}, :comma, {:class, "b"}]
    end

    test "raises on empty class selector" do
      assert_raise ArgumentError, ~r/Expected identifier after/, fn ->
        Tokenizer.tokenize(".")
      end
    end

    test "raises on empty id selector" do
      assert_raise ArgumentError, ~r/Expected identifier after/, fn ->
        Tokenizer.tokenize("#")
      end
    end

    test "raises on unterminated string" do
      assert_raise ArgumentError, ~r/Unterminated string/, fn ->
        Tokenizer.tokenize("[href=\"test]")
      end
    end
  end
end
