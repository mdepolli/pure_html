defmodule PureHTML.Query.Selector.ParserTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.AttributeSelector
  alias PureHTML.Query.Selector.Parser

  describe "parse/1" do
    test "tag selector" do
      assert Parser.parse("div") == [%Selector{type: "div"}]
      assert Parser.parse("p") == [%Selector{type: "p"}]
    end

    test "universal selector" do
      assert Parser.parse("*") == [%Selector{type: "*"}]
    end

    test "class selector" do
      assert Parser.parse(".foo") == [%Selector{classes: ["foo"]}]
      assert Parser.parse(".foo.bar") == [%Selector{classes: ["foo", "bar"]}]
    end

    test "id selector" do
      assert Parser.parse("#bar") == [%Selector{id: "bar"}]
    end

    test "compound selector" do
      assert Parser.parse("div.foo") == [%Selector{type: "div", classes: ["foo"]}]
      assert Parser.parse("div#bar") == [%Selector{type: "div", id: "bar"}]

      assert Parser.parse("div.foo#bar") == [
               %Selector{type: "div", id: "bar", classes: ["foo"]}
             ]
    end

    test "attribute selector - existence" do
      assert Parser.parse("[href]") == [
               %Selector{
                 attributes: [%AttributeSelector{name: "href", match_type: :exists}]
               }
             ]
    end

    test "attribute selector - exact match" do
      assert Parser.parse("[type=text]") == [
               %Selector{
                 attributes: [
                   %AttributeSelector{name: "type", value: "text", match_type: :equal}
                 ]
               }
             ]
    end

    test "attribute selector - prefix match" do
      assert Parser.parse("[href^=https]") == [
               %Selector{
                 attributes: [
                   %AttributeSelector{name: "href", value: "https", match_type: :prefix}
                 ]
               }
             ]
    end

    test "attribute selector - suffix match" do
      assert Parser.parse("[href$=.pdf]") == [
               %Selector{
                 attributes: [
                   %AttributeSelector{name: "href", value: ".pdf", match_type: :suffix}
                 ]
               }
             ]
    end

    test "attribute selector - substring match" do
      assert Parser.parse("[href*=example]") == [
               %Selector{
                 attributes: [
                   %AttributeSelector{name: "href", value: "example", match_type: :substring}
                 ]
               }
             ]
    end

    test "selector list" do
      assert Parser.parse(".a, .b") == [
               %Selector{classes: ["a"]},
               %Selector{classes: ["b"]}
             ]

      assert Parser.parse("div, p, span") == [
               %Selector{type: "div"},
               %Selector{type: "p"},
               %Selector{type: "span"}
             ]
    end

    test "complex compound selector" do
      assert Parser.parse("div.foo#bar[data-id]") == [
               %Selector{
                 type: "div",
                 id: "bar",
                 classes: ["foo"],
                 attributes: [%AttributeSelector{name: "data-id", match_type: :exists}]
               }
             ]
    end

    test "multiple attribute selectors" do
      assert Parser.parse("[type=text][required]") == [
               %Selector{
                 attributes: [
                   %AttributeSelector{name: "type", value: "text", match_type: :equal},
                   %AttributeSelector{name: "required", match_type: :exists}
                 ]
               }
             ]
    end
  end
end
