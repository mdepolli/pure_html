defmodule PureHTML.QueryTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query

  describe "find/2" do
    test "finds elements by tag" do
      html = PureHTML.parse("<div><p>Hello</p><p>World</p></div>")

      assert Query.find(html, "p") == [
               {"p", [], ["Hello"]},
               {"p", [], ["World"]}
             ]
    end

    test "finds elements by class" do
      html = PureHTML.parse("<div><p class='intro'>Hello</p><p>World</p></div>")

      assert Query.find(html, ".intro") == [{"p", [{"class", "intro"}], ["Hello"]}]
    end

    test "finds elements by id" do
      html = PureHTML.parse("<div><p id='greeting'>Hello</p></div>")

      assert Query.find(html, "#greeting") == [{"p", [{"id", "greeting"}], ["Hello"]}]
    end

    test "finds elements by compound selector" do
      html =
        PureHTML.parse(
          "<div><p class='intro' id='greeting'>Hello</p><p class='intro'>World</p></div>"
        )

      assert Query.find(html, "p.intro#greeting") == [
               {"p", [{"class", "intro"}, {"id", "greeting"}], ["Hello"]}
             ]
    end

    test "finds elements by attribute existence" do
      html = PureHTML.parse("<div><a href='/link'>Link</a><span>Text</span></div>")

      assert Query.find(html, "[href]") == [{"a", [{"href", "/link"}], ["Link"]}]
    end

    test "finds elements by attribute value" do
      html = PureHTML.parse("<input type='text'><input type='password'>")

      assert Query.find(html, "[type=text]") == [{"input", [{"type", "text"}], []}]
    end

    test "finds elements by attribute prefix" do
      html =
        PureHTML.parse(
          "<a href='https://example.com'>Secure</a><a href='http://test.com'>Insecure</a>"
        )

      assert Query.find(html, "[href^=https]") == [
               {"a", [{"href", "https://example.com"}], ["Secure"]}
             ]
    end

    test "finds elements by attribute suffix" do
      html = PureHTML.parse("<a href='doc.pdf'>PDF</a><a href='doc.txt'>Text</a>")

      assert Query.find(html, "[href$=.pdf]") == [{"a", [{"href", "doc.pdf"}], ["PDF"]}]
    end

    test "finds elements by attribute substring" do
      html =
        PureHTML.parse(
          "<a href='https://example.com'>Example</a><a href='https://test.com'>Test</a>"
        )

      assert Query.find(html, "[href*=example]") == [
               {"a", [{"href", "https://example.com"}], ["Example"]}
             ]
    end

    test "finds elements with selector list" do
      html = PureHTML.parse("<div><p>Para</p><span>Span</span><a>Link</a></div>")

      assert Query.find(html, "p, span") == [
               {"p", [], ["Para"]},
               {"span", [], ["Span"]}
             ]
    end

    test "finds nested elements" do
      html = PureHTML.parse("<div><div><p class='deep'>Deep</p></div></div>")

      assert Query.find(html, ".deep") == [{"p", [{"class", "deep"}], ["Deep"]}]
    end

    test "returns empty list when no matches" do
      html = PureHTML.parse("<div><p>Hello</p></div>")

      assert Query.find(html, ".nonexistent") == []
    end

    test "works with single node input" do
      node = {"div", [], [{"p", [{"class", "inner"}], ["Hello"]}]}

      assert Query.find(node, ".inner") == [{"p", [{"class", "inner"}], ["Hello"]}]
    end

    test "finds universal selector" do
      html = [{"div", [], [{"p", [], ["Hello"]}]}]

      # Should find div and p
      assert Query.find(html, "*") == [
               {"div", [], [{"p", [], ["Hello"]}]},
               {"p", [], ["Hello"]}
             ]
    end
  end

  describe "children/2" do
    test "returns children of element" do
      node = {"div", [], [{"p", [], ["Hello"]}, {"span", [], ["World"]}]}

      assert Query.children(node) == [
               {"p", [], ["Hello"]},
               {"span", [], ["World"]}
             ]
    end

    test "includes text nodes by default" do
      node = {"div", [], [{"p", [], ["Hello"]}, "Some text", {"span", [], ["World"]}]}

      assert Query.children(node) == [
               {"p", [], ["Hello"]},
               "Some text",
               {"span", [], ["World"]}
             ]
    end

    test "excludes text nodes with include_text: false" do
      node = {"div", [], [{"p", [], ["Hello"]}, "Some text", {"span", [], ["World"]}]}

      assert Query.children(node, include_text: false) == [
               {"p", [], ["Hello"]},
               {"span", [], ["World"]}
             ]
    end

    test "returns nil for non-elements" do
      assert Query.children("text") == nil
      assert Query.children({:comment, "comment"}) == nil
    end

    test "returns empty list for element with no children" do
      assert Query.children({"br", [], []}) == []
    end

    test "works with foreign elements" do
      node = {{:svg, "svg"}, [], [{{:svg, "circle"}, [{"r", "10"}], []}]}

      assert Query.children(node) == [{{:svg, "circle"}, [{"r", "10"}], []}]
    end
  end

  describe "PureHTML.query/2 delegation" do
    test "delegates to Query.find/2" do
      html = PureHTML.parse("<div><p class='intro'>Hello</p></div>")

      assert PureHTML.query(html, ".intro") == [{"p", [{"class", "intro"}], ["Hello"]}]
    end
  end

  describe "PureHTML.children/2 delegation" do
    test "delegates to Query.children/2" do
      node = {"div", [], [{"p", [], ["Hello"]}]}

      assert PureHTML.children(node) == [{"p", [], ["Hello"]}]
    end
  end
end
