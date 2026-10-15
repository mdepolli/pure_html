defmodule PureHTML.Query.SelectorTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.AttributeSelector

  describe "put_type/2" do
    test "keeps a name as written and its ASCII lowercase" do
      assert %Selector{type: "D\u0130V", html_type: "d\u0130v"} =
               Selector.put_type(%Selector{}, "D\u0130V")
    end

    test "sets the universal selector" do
      assert %Selector{type: :universal, html_type: :universal} =
               Selector.put_type(%Selector{}, :universal)
    end
  end

  describe "match?/2" do
    test "matches tag selector" do
      selector = Selector.put_type(%Selector{}, "div")

      assert Selector.match?({"div", [], []}, selector)
      refute Selector.match?({"p", [], []}, selector)
    end

    test "matches universal selector" do
      selector = Selector.put_type(%Selector{}, :universal)

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
      selector = %Selector{ids: ["main"]}

      assert Selector.match?({"div", [{"id", "main"}], []}, selector)
      refute Selector.match?({"div", [{"id", "other"}], []}, selector)
      refute Selector.match?({"div", [], []}, selector)
    end

    test "matches compound selector" do
      selector = Selector.put_type(%Selector{ids: ["main"], classes: ["foo"]}, "div")

      assert Selector.match?({"div", [{"class", "foo"}, {"id", "main"}], []}, selector)
      refute Selector.match?({"p", [{"class", "foo"}, {"id", "main"}], []}, selector)
      refute Selector.match?({"div", [{"id", "main"}], []}, selector)
      refute Selector.match?({"div", [{"class", "foo"}], []}, selector)
    end

    test "matches attribute existence selector" do
      selector = %Selector{attributes: [AttributeSelector.new("href", :exists, nil)]}

      assert Selector.match?({"a", [{"href", "https://example.com"}], []}, selector)
      assert Selector.match?({"a", [{"href", ""}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches attribute exact value selector" do
      selector = %Selector{
        attributes: [AttributeSelector.new("type", :equal, "text")]
      }

      assert Selector.match?({"input", [{"type", "text"}], []}, selector)
      refute Selector.match?({"input", [{"type", "password"}], []}, selector)
      refute Selector.match?({"input", [], []}, selector)
    end

    test "matches attribute prefix selector" do
      selector = %Selector{
        attributes: [AttributeSelector.new("href", :prefix, "https")]
      }

      assert Selector.match?({"a", [{"href", "https://example.com"}], []}, selector)
      assert Selector.match?({"a", [{"href", "https"}], []}, selector)
      refute Selector.match?({"a", [{"href", "http://example.com"}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches attribute suffix selector" do
      selector = %Selector{
        attributes: [AttributeSelector.new("href", :suffix, ".pdf")]
      }

      assert Selector.match?({"a", [{"href", "document.pdf"}], []}, selector)
      refute Selector.match?({"a", [{"href", "document.txt"}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches attribute substring selector" do
      selector = %Selector{
        attributes: [AttributeSelector.new("href", :substring, "example")]
      }

      assert Selector.match?({"a", [{"href", "https://example.com"}], []}, selector)
      assert Selector.match?({"a", [{"href", "example"}], []}, selector)
      refute Selector.match?({"a", [{"href", "https://test.com"}], []}, selector)
      refute Selector.match?({"a", [], []}, selector)
    end

    test "matches multiple attribute selectors" do
      selector = %Selector{
        attributes: [
          AttributeSelector.new("type", :equal, "text"),
          AttributeSelector.new("required", :exists, nil)
        ]
      }

      assert Selector.match?({"input", [{"required", ""}, {"type", "text"}], []}, selector)
      refute Selector.match?({"input", [{"type", "text"}], []}, selector)
      refute Selector.match?({"input", [{"required", ""}], []}, selector)
    end

    test "does not match non-elements" do
      selector = Selector.put_type(%Selector{}, "div")

      refute Selector.match?("text node", selector)
      refute Selector.match?({:comment, "comment"}, selector)
      refute Selector.match?({:doctype, "html", nil, nil}, selector)
    end

    test "matches foreign elements (SVG/MathML)" do
      selector = Selector.put_type(%Selector{}, "circle")

      assert Selector.match?({{:svg, "circle"}, [{"r", "10"}], []}, selector)
      refute Selector.match?({{:svg, "rect"}, [], []}, selector)
    end

    # HTML, case-sensitivity of selectors: a type selector is ASCII lowercased
    # before it is compared to the name of an HTML element, and compared as
    # written to the name of any other element.
    test "an uppercase type selector matches an HTML element and a foreign one as written" do
      selector = Selector.put_type(%Selector{}, "DIV")

      assert Selector.match?({"div", [], []}, selector)
      assert Selector.match?({{:svg, "DIV"}, [], []}, selector)
      refute Selector.match?({{:svg, "div"}, [], []}, selector)
    end

    test "a listed attribute's value matches ASCII case-insensitively on an HTML element only" do
      selector = %Selector{attributes: [AttributeSelector.new("TYPE", :equal, "TEXT")]}

      assert Selector.match?({"input", [{"type", "Text"}], []}, selector)
      assert Selector.match?({{:svg, "svg"}, [{"TYPE", "TEXT"}], []}, selector)
      refute Selector.match?({{:svg, "svg"}, [{"TYPE", "text"}], []}, selector)
    end
  end
end
