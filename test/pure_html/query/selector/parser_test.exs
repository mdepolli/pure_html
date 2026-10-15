defmodule PureHTML.Query.Selector.ParserTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.AttributeSelector
  alias PureHTML.Query.Selector.Parser

  # Helpers for the parser's {:ok, chains} shape, and for a compound that
  # holds only a type selector
  defp chain(selector), do: {:ok, [[{nil, selector}]]}
  defp chains(selectors), do: {:ok, Enum.map(selectors, fn sel -> [{nil, sel}] end)}
  defp type(name), do: Selector.put_type(%Selector{}, name)

  describe "parse/1" do
    test "tag selector" do
      assert Parser.parse("div") == chain(type("div"))
      assert Parser.parse("p") == chain(type("p"))
    end

    test "universal selector" do
      assert Parser.parse("*") == chain(type(:universal))
    end

    test "class selector" do
      assert Parser.parse(".foo") == chain(%Selector{classes: ["foo"]})
      assert Parser.parse(".foo.bar") == chain(%Selector{classes: ["foo", "bar"]})
    end

    test "id selector" do
      assert Parser.parse("#bar") == chain(%Selector{ids: ["bar"]})
    end

    test "compound selector" do
      assert Parser.parse("div.foo") ==
               chain(Selector.put_type(%Selector{classes: ["foo"]}, "div"))

      assert Parser.parse("div#bar") == chain(Selector.put_type(%Selector{ids: ["bar"]}, "div"))

      assert Parser.parse("div.foo#bar") ==
               chain(Selector.put_type(%Selector{ids: ["bar"], classes: ["foo"]}, "div"))
    end

    test "attribute selector - existence" do
      assert Parser.parse("[href]") ==
               chain(%Selector{
                 attributes: [AttributeSelector.new("href", :exists, nil)]
               })
    end

    test "attribute selector - exact match" do
      assert Parser.parse("[type=text]") ==
               chain(%Selector{
                 attributes: [
                   AttributeSelector.new("type", :equal, "text")
                 ]
               })
    end

    test "attribute selector - prefix match" do
      assert Parser.parse("[href^=https]") ==
               chain(%Selector{
                 attributes: [
                   AttributeSelector.new("href", :prefix, "https")
                 ]
               })
    end

    test "attribute selector - suffix match" do
      assert Parser.parse("[href$=\".pdf\"]") ==
               chain(%Selector{
                 attributes: [
                   AttributeSelector.new("href", :suffix, ".pdf")
                 ]
               })
    end

    test "attribute selector - substring match" do
      assert Parser.parse("[href*=example]") ==
               chain(%Selector{
                 attributes: [
                   AttributeSelector.new("href", :substring, "example")
                 ]
               })
    end

    # The parser hands names to the builders as written; they keep the ASCII
    # lowercase for HTML elements.
    test "a type selector keeps its name as written" do
      assert Parser.parse("DIV") == chain(type("DIV"))
    end

    test "an attribute selector keeps its name and value as written" do
      assert Parser.parse("[TYPE=TEXT]") ==
               chain(%Selector{attributes: [AttributeSelector.new("TYPE", :equal, "TEXT")]})
    end

    test "selector list" do
      assert Parser.parse(".a, .b") ==
               chains([%Selector{classes: ["a"]}, %Selector{classes: ["b"]}])

      assert Parser.parse("div, p, span") ==
               chains([type("div"), type("p"), type("span")])
    end

    test "whitespace around a comma is not a descendant combinator" do
      assert Parser.parse("p ,q") == chains([type("p"), type("q")])
      assert Parser.parse("p , q") == chains([type("p"), type("q")])
    end

    test "complex compound selector" do
      assert Parser.parse("div.foo#bar[data-id]") ==
               chain(
                 Selector.put_type(
                   %Selector{
                     ids: ["bar"],
                     classes: ["foo"],
                     attributes: [AttributeSelector.new("data-id", :exists, nil)]
                   },
                   "div"
                 )
               )
    end

    test "multiple attribute selectors" do
      assert Parser.parse("[type=text][required]") ==
               chain(%Selector{
                 attributes: [
                   AttributeSelector.new("type", :equal, "text"),
                   AttributeSelector.new("required", :exists, nil)
                 ]
               })
    end

    # Combinator tests

    test "child combinator" do
      assert Parser.parse("div > p") ==
               {:ok,
                [
                  [
                    {nil, type("div")},
                    {:child, type("p")}
                  ]
                ]}
    end

    test "descendant combinator" do
      assert Parser.parse("div p") ==
               {:ok,
                [
                  [
                    {nil, type("div")},
                    {:descendant, type("p")}
                  ]
                ]}
    end

    test "adjacent sibling combinator" do
      assert Parser.parse("h1 + p") ==
               {:ok,
                [
                  [
                    {nil, type("h1")},
                    {:adjacent_sibling, type("p")}
                  ]
                ]}
    end

    test "general sibling combinator" do
      assert Parser.parse("h1 ~ p") ==
               {:ok,
                [
                  [
                    {nil, type("h1")},
                    {:general_sibling, type("p")}
                  ]
                ]}
    end

    test "chained combinators" do
      assert Parser.parse("article > section > p") ==
               {:ok,
                [
                  [
                    {nil, type("article")},
                    {:child, type("section")},
                    {:child, type("p")}
                  ]
                ]}
    end

    test "mixed combinators" do
      assert Parser.parse("div p > span") ==
               {:ok,
                [
                  [
                    {nil, type("div")},
                    {:descendant, type("p")},
                    {:child, type("span")}
                  ]
                ]}
    end

    test "a trailing combinator is invalid" do
      assert {:error, {:invalid_selector, "expected a compound selector"}} = Parser.parse("div >")
    end

    test "an empty selector or an empty list member is invalid" do
      assert {:error, {:invalid_selector, _}} = Parser.parse("")
      assert {:error, {:invalid_selector, _}} = Parser.parse("p,,p")
      assert {:error, {:invalid_selector, _}} = Parser.parse("p,")
    end

    test "a malformed attribute selector is invalid" do
      assert {:error, {:invalid_selector, _}} = Parser.parse("[")
      assert {:error, {:invalid_selector, _}} = Parser.parse("[href=")
      assert {:error, {:invalid_selector, _}} = Parser.parse("[href=]")
    end

    test "combinator with compound selectors" do
      assert Parser.parse("div.container > p.intro") ==
               {:ok,
                [
                  [
                    {nil, Selector.put_type(%Selector{classes: ["container"]}, "div")},
                    {:child, Selector.put_type(%Selector{classes: ["intro"]}, "p")}
                  ]
                ]}
    end

    test "whitespace around combinators is normalized" do
      # All of these should produce the same result
      assert Parser.parse("div>p") == Parser.parse("div > p")
      assert Parser.parse("div>p") == Parser.parse("div  >  p")
    end
  end
end
