defmodule PureHTML.Query.Selector.ParserTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.AttributeSelector
  alias PureHTML.Query.Selector.Parser

  # Helper to wrap a selector in the chain format
  defp chain(selector), do: [[{nil, selector}]]
  defp chains(selectors), do: Enum.map(selectors, fn sel -> [{nil, sel}] end)

  describe "parse/1" do
    test "tag selector" do
      assert Parser.parse("div") == chain(%Selector{type: "div"})
      assert Parser.parse("p") == chain(%Selector{type: "p"})
    end

    test "universal selector" do
      assert Parser.parse("*") == chain(%Selector{type: "*"})
    end

    test "class selector" do
      assert Parser.parse(".foo") == chain(%Selector{classes: ["foo"]})
      assert Parser.parse(".foo.bar") == chain(%Selector{classes: ["foo", "bar"]})
    end

    test "id selector" do
      assert Parser.parse("#bar") == chain(%Selector{id: "bar"})
    end

    test "compound selector" do
      assert Parser.parse("div.foo") == chain(%Selector{type: "div", classes: ["foo"]})
      assert Parser.parse("div#bar") == chain(%Selector{type: "div", id: "bar"})

      assert Parser.parse("div.foo#bar") ==
               chain(%Selector{type: "div", id: "bar", classes: ["foo"]})
    end

    test "attribute selector - existence" do
      assert Parser.parse("[href]") ==
               chain(%Selector{
                 attributes: [%AttributeSelector{name: "href", match_type: :exists}]
               })
    end

    test "attribute selector - exact match" do
      assert Parser.parse("[type=text]") ==
               chain(%Selector{
                 attributes: [
                   %AttributeSelector{name: "type", value: "text", match_type: :equal}
                 ]
               })
    end

    test "attribute selector - prefix match" do
      assert Parser.parse("[href^=https]") ==
               chain(%Selector{
                 attributes: [
                   %AttributeSelector{name: "href", value: "https", match_type: :prefix}
                 ]
               })
    end

    test "attribute selector - suffix match" do
      assert Parser.parse("[href$=.pdf]") ==
               chain(%Selector{
                 attributes: [
                   %AttributeSelector{name: "href", value: ".pdf", match_type: :suffix}
                 ]
               })
    end

    test "attribute selector - substring match" do
      assert Parser.parse("[href*=example]") ==
               chain(%Selector{
                 attributes: [
                   %AttributeSelector{name: "href", value: "example", match_type: :substring}
                 ]
               })
    end

    test "selector list" do
      assert Parser.parse(".a, .b") ==
               chains([%Selector{classes: ["a"]}, %Selector{classes: ["b"]}])

      assert Parser.parse("div, p, span") ==
               chains([%Selector{type: "div"}, %Selector{type: "p"}, %Selector{type: "span"}])
    end

    test "complex compound selector" do
      assert Parser.parse("div.foo#bar[data-id]") ==
               chain(%Selector{
                 type: "div",
                 id: "bar",
                 classes: ["foo"],
                 attributes: [%AttributeSelector{name: "data-id", match_type: :exists}]
               })
    end

    test "multiple attribute selectors" do
      assert Parser.parse("[type=text][required]") ==
               chain(%Selector{
                 attributes: [
                   %AttributeSelector{name: "type", value: "text", match_type: :equal},
                   %AttributeSelector{name: "required", match_type: :exists}
                 ]
               })
    end

    # Combinator tests

    test "child combinator" do
      assert Parser.parse("div > p") == [
               [
                 {nil, %Selector{type: "div"}},
                 {:child, %Selector{type: "p"}}
               ]
             ]
    end

    test "descendant combinator" do
      assert Parser.parse("div p") == [
               [
                 {nil, %Selector{type: "div"}},
                 {:descendant, %Selector{type: "p"}}
               ]
             ]
    end

    test "adjacent sibling combinator" do
      assert Parser.parse("h1 + p") == [
               [
                 {nil, %Selector{type: "h1"}},
                 {:adjacent_sibling, %Selector{type: "p"}}
               ]
             ]
    end

    test "general sibling combinator" do
      assert Parser.parse("h1 ~ p") == [
               [
                 {nil, %Selector{type: "h1"}},
                 {:general_sibling, %Selector{type: "p"}}
               ]
             ]
    end

    test "chained combinators" do
      assert Parser.parse("article > section > p") == [
               [
                 {nil, %Selector{type: "article"}},
                 {:child, %Selector{type: "section"}},
                 {:child, %Selector{type: "p"}}
               ]
             ]
    end

    test "mixed combinators" do
      assert Parser.parse("div p > span") == [
               [
                 {nil, %Selector{type: "div"}},
                 {:descendant, %Selector{type: "p"}},
                 {:child, %Selector{type: "span"}}
               ]
             ]
    end

    test "combinator with compound selectors" do
      assert Parser.parse("div.container > p.intro") == [
               [
                 {nil, %Selector{type: "div", classes: ["container"]}},
                 {:child, %Selector{type: "p", classes: ["intro"]}}
               ]
             ]
    end

    test "whitespace around combinators is normalized" do
      # All of these should produce the same result
      assert Parser.parse("div>p") == Parser.parse("div > p")
      assert Parser.parse("div>p") == Parser.parse("div  >  p")
    end
  end
end
