defmodule PureHTML.Query.SelectorTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.AttributeSelector

  describe "match?/2" do
    test "matches tag selector" do
      selector = %Selector{type: "div"}

      assert Selector.match?({"div", [], []}, selector)
      refute Selector.match?({"p", [], []}, selector)
    end

    test "matches universal selector" do
      selector = %Selector{type: "*"}

      assert Selector.match?({"div", [], []}, selector)
      assert Selector.match?({"p", [], []}, selector)
      assert Selector.match?({"span", [], []}, selector)
    end

    test "matches nil type (any element)" do
      selector = %Selector{type: nil, classes: ["foo"]}

      assert Selector.match?({"div", [{"class", "foo"}], []}, selector)
      assert Selector.match?({"p", [{"class", "foo"}], []}, selector)
    end

    test "matches class selector" do
      selector = %Selector{classes: ["foo"]}

      assert Selector.match?({"div", [{"class", "foo"}], []}, selector)
      assert Selector.match?({"div", [{"class", "foo bar"}], []}, selector)
      refute Selector.match?({"div", [{"class", "bar"}], []}, selector)
      refute Selector.match?({"div", [], []}, selector)
    end

    test "matches multiple class selectors" do
      selector = %Selector{classes: ["foo", "bar"]}

      assert Selector.match?({"div", [{"class", "foo bar"}], []}, selector)
      assert Selector.match?({"div", [{"class", "bar foo baz"}], []}, selector)
      refute Selector.match?({"div", [{"class", "foo"}], []}, selector)
      refute Selector.match?({"div", [{"class", "bar"}], []}, selector)
    end

    test "matches id selector" do
      selector = %Selector{id: "main"}

      assert Selector.match?({"div", [{"id", "main"}], []}, selector)
      refute Selector.match?({"div", [{"id", "other"}], []}, selector)
      refute Selector.match?({"div", [], []}, selector)
    end

    test "matches compound selector" do
      selector = %Selector{type: "div", id: "main", classes: ["foo"]}

      assert Selector.match?({"div", [{"class", "foo"}, {"id", "main"}], []}, selector)
      refute Selector.match?({"p", [{"class", "foo"}, {"id", "main"}], []}, selector)
      refute Selector.match?({"div", [{"id", "main"}], []}, selector)
      refute Selector.match?({"div", [{"class", "foo"}], []}, selector)
    end

    test "matches attribute existence selector" do
      selector = %Selector{attributes: [%AttributeSelector{name: "href", match_type: :exists}]}

      assert Selector.match?({"a", [{"href", "https://example.com"}], []}, selector)
      assert Selector.match?({"a", [{"href", ""}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches attribute exact value selector" do
      selector = %Selector{
        attributes: [%AttributeSelector{name: "type", value: "text", match_type: :equal}]
      }

      assert Selector.match?({"input", [{"type", "text"}], []}, selector)
      refute Selector.match?({"input", [{"type", "password"}], []}, selector)
      refute Selector.match?({"input", [], []}, selector)
    end

    test "matches attribute prefix selector" do
      selector = %Selector{
        attributes: [%AttributeSelector{name: "href", value: "https", match_type: :prefix}]
      }

      assert Selector.match?({"a", [{"href", "https://example.com"}], []}, selector)
      assert Selector.match?({"a", [{"href", "https"}], []}, selector)
      refute Selector.match?({"a", [{"href", "http://example.com"}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches attribute suffix selector" do
      selector = %Selector{
        attributes: [%AttributeSelector{name: "href", value: ".pdf", match_type: :suffix}]
      }

      assert Selector.match?({"a", [{"href", "document.pdf"}], []}, selector)
      refute Selector.match?({"a", [{"href", "document.txt"}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches attribute substring selector" do
      selector = %Selector{
        attributes: [%AttributeSelector{name: "href", value: "example", match_type: :substring}]
      }

      assert Selector.match?({"a", [{"href", "https://example.com"}], []}, selector)
      assert Selector.match?({"a", [{"href", "example"}], []}, selector)
      refute Selector.match?({"a", [{"href", "https://test.com"}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches multiple attribute selectors" do
      selector = %Selector{
        attributes: [
          %AttributeSelector{name: "type", value: "text", match_type: :equal},
          %AttributeSelector{name: "required", match_type: :exists}
        ]
      }

      assert Selector.match?({"input", [{"required", ""}, {"type", "text"}], []}, selector)
      refute Selector.match?({"input", [{"type", "text"}], []}, selector)
      refute Selector.match?({"input", [{"required", ""}], []}, selector)
    end

    test "does not match non-elements" do
      selector = %Selector{type: "div"}

      refute Selector.match?("text node", selector)
      refute Selector.match?({:comment, "comment"}, selector)
      refute Selector.match?({:doctype, "html", nil, nil}, selector)
    end

    test "matches foreign elements (SVG/MathML)" do
      selector = %Selector{type: "circle"}

      assert Selector.match?({{:svg, "circle"}, [{"r", "10"}], []}, selector)
      refute Selector.match?({{:svg, "rect"}, [], []}, selector)
    end
  end
end
