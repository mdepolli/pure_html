defmodule PureHTMLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  describe "parse/2" do
    property "never crashes on arbitrary strings" do
      check all(html <- string(:printable, max_length: 1000)) do
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
      end
    end

    property "is deterministic" do
      check all(html <- string(:printable, max_length: 500)) do
        assert PureHTML.parse(html) == PureHTML.parse(html)
      end
    end

    # The parser currently crashes on invalid UTF-8. HTML5 assumes valid encoding.
    property "handles unicode strings" do
      check all(text <- string(:printable, max_length: 500)) do
        html = "<div>#{text}</div>"
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
      end
    end

    property "returns a list of valid nodes" do
      check all(html <- html_fragment()) do
        nodes = PureHTML.parse(html)
        assert is_list(nodes)
        assert Enum.all?(nodes, &valid_node?/1)
      end
    end
  end

  describe "parse_with_errors/2" do
    test "counts a missing doctype as a parse error" do
      # Arrange
      html = "<p>hello</p>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["hello"]}]}]}] = nodes
      assert error_count == 1
    end

    test "does not count a table end tag that closes a caption in table scope" do
      # Arrange
      html = "<table><caption></table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], []}, {"body", [], [{"table", [], [{"caption", [], []}]}]}]}
             ] = nodes

      assert error_count == 1
    end

    test "does not count a cell start tag that closes a caption in table scope" do
      # Arrange
      html = "<table><caption><td>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"table", [],
                      [{"caption", [], []}, {"tbody", [], [{"tr", [], [{"td", [], []}]}]}]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "generates implied end tags before checking the caption current node on table end" do
      # Arrange
      html = "<!DOCTYPE html><body><table><caption><svg><g>foo</g><g>bar</g><p>baz</table><p>quux"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"table", [],
                      [
                        {"caption", [],
                         [
                           {{:svg, "svg"}, [],
                            [{{:svg, "g"}, [], ["foo"]}, {{:svg, "g"}, [], ["bar"]}]},
                           {"p", [], ["baz"]}
                         ]}
                      ]},
                     {"p", [], ["quux"]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "clears active formatting to the marker when a caption closes" do
      # Arrange
      html = "<p><b></p><table><caption></table>y"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"p", [], [{"b", [], []}]},
                     {"table", [], [{"caption", [], []}]},
                     {"b", [], ["y"]}
                   ]}
                ]}
             ] = nodes

      # Missing doctype, </p> with b as current node, and b still open at EOF.
      assert error_count == 3
    end

    test "ignores a form end tag whose form element is not in scope" do
      # Arrange
      html = "<!doctype html><form><table></form><form></table></form>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"form", [], [{"table", [], [{"form", [], []}]}]}]}
                ]}
             ] = nodes

      assert error_count == 5
    end

    test "counts a frameset start tag in a table as a table voodoo error and an in-body error" do
      # Arrange
      html = "<!doctype html><table><frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"table", [], []}]}]}
             ] = nodes

      assert error_count == 3
    end

    test "counts eof inside xmp as a text mode error and an unclosed button error" do
      # Arrange
      html = "<!doctype html><p><button><xmp>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"p", [], [{"button", [], [{"xmp", [], []}]}]}]}
                ]}
             ] = nodes

      assert error_count == 2
    end

    test "counts a p end tag in a table as a voodoo error and an in-body error" do
      # Arrange
      html = "<p><table></p>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"p", [], [{"p", [], []}, {"table", [], []}]}]}
                ]}
             ] = nodes

      assert error_count == 4
    end

    test "ignores a frameset end tag in body as an unexpected end tag" do
      # Arrange
      html = "<html>aaa<frameset></frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["aaa"]}]}] = nodes
      assert error_count == 3
    end

    test "counts an end tag in a nested table as a table voodoo error before the adoption agency" do
      # Arrange
      html = "<!doctype html><table><td><table><i>a<div>b<b>c</i>d"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"table", [],
                      [
                        {"tbody", [],
                         [
                           {"tr", [],
                            [
                              {"td", [],
                               [
                                 {"i", [], ["a"]},
                                 {"div", [],
                                  [{"i", [], ["b", {"b", [], ["c"]}]}, {"b", [], ["d"]}]},
                                 {"table", [], []}
                               ]}
                            ]}
                         ]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 12
    end

    test "processes a select start tag in a row with the in-table rules" do
      # Arrange
      html = "<!doctype html><table><tr><select><td>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"select", [], []},
                     {"table", [], [{"tbody", [], [{"tr", [], [{"td", [], []}]}]}]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 2
    end

    test "foster-parents a select in a table and parses its option with the in-body rules" do
      # Arrange
      html = "<table><select><option>3</select></table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"select", [], [{"option", [], ["3"]}]}, {"table", [], []}]}
                ]}
             ] = nodes

      # No doctype; select, option, "3", and </select> are each a table parse error.
      assert error_count == 5
    end

    test "counts a select end tag whose current node is a button as a parse error" do
      # Arrange
      html = "<select><button>button</select>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"select", [], [{"button", [], ["button"]}]}]}
                ]}
             ] = nodes

      assert error_count == 2
    end

    test "parses button and selectedcontent inside select with the in-body rules" do
      # Arrange
      html = "<select><button><selectedcontent></button><option>X"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"select", [],
                      [
                        {"button", [], [{"selectedcontent", [], ["X"]}]},
                        {"option", [], ["X"]}
                      ]}
                   ]}
                ]}
             ] = nodes

      # No doctype; </button> with selectedcontent as the current node; select open at EOF.
      # html5lib webkit02:44 lists no errors at all, not even the doctype one; the text wins.
      assert error_count == 3
    end

    test "ignores a select end tag in a select fragment with no select in scope" do
      # Arrange
      html = "</select><option>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "select")

      # Assert
      assert [{"option", [], []}] = nodes
      assert error_count == 1
    end

    test "ignores an input start tag in a select fragment" do
      # Arrange
      html = "<input><option>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "select")

      # Assert
      assert [{"option", [], []}] = nodes
      assert error_count == 1
    end

    test "parses a textarea in a select fragment as text" do
      # Arrange
      html = "<textarea><option>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "select")

      # Assert
      assert [{"textarea", [], ["<option>"]}] = nodes
      assert error_count == 1
    end

    test "returns zero errors for a complete HTML5 document" do
      # Arrange
      html = "<!DOCTYPE html><html><head></head><body><p>hello</p></body></html>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["hello"]}]}]}
             ] = nodes

      assert error_count == 0
    end

    test "counts errors in fragment parsing" do
      # Arrange
      html = "</div>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "div")

      # Assert
      assert nodes == []
      assert error_count == 1
    end

    test "counts an HTML start tag in SVG foreign content as a parse error" do
      # Arrange
      html = "<p>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "svg svg")

      # Assert
      assert nodes == [{"p", [], []}]
      assert error_count == 1
    end

    test "counts an unknown named character reference as a parse error" do
      # Arrange
      html = "&AMp;"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["&AMp;"]}]}] = nodes
      assert error_count == 2
    end

    test "counts a stray SVG end tag in an SVG fragment as a parse error" do
      # Arrange
      html = "</svg>X"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "svg svg")

      # Assert
      assert nodes == ["X"]
      assert error_count == 1
    end

    test "counts a C1 control numeric character reference as a parse error" do
      # Arrange
      html = "FOO&#x0081;ZOO"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["FOO\u{81}ZOO"]}]}] = nodes
      assert error_count == 2
    end

    test "counts a trailing solidus on a non-void HTML start tag as a parse error" do
      # Arrange
      html = "<ms/>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "math ms")

      # Assert
      assert nodes == [{"ms", [], []}]
      assert error_count == 2
    end

    test "counts an HTML body start tag in SVG as a foreign-content parse error" do
      # Arrange
      html = "<body><foo>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "svg svg")

      # Assert
      assert nodes == [{{:svg, "foo"}, [], []}]
      assert error_count == 3
    end

    test "does not count a foreign-content error for body inside an SVG integration point" do
      # Arrange
      html = "<body>X"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "svg desc")

      # Assert
      assert nodes == ["X"]
      assert error_count == 1
    end

    test "counts a tr start tag inside MathML in a td fragment as a parse error" do
      # Arrange
      html = "<math><tr><td><mo><tr>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "td")

      # Assert
      assert [
               {{:math, "math"}, [],
                [{{:math, "tr"}, [], [{{:math, "td"}, [], [{{:math, "mo"}, [], []}]}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "counts an ignored tbody start tag inside MathML as a parse error" do
      # Arrange
      html = "<math><thead><mo><tbody>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "thead")

      # Assert
      assert [
               {{:math, "math"}, [], [{{:math, "thead"}, [], [{{:math, "mo"}, [], []}]}]}
             ] = nodes

      assert error_count == 3
    end

    test "counts foster-parented characters and a mismatched cell end tag" do
      # Arrange
      html = "<body><table><tr><td><svg><td><foreignObject><span></td>Foo"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     "Foo",
                     {"table", [],
                      [
                        {"tbody", [],
                         [
                           {"tr", [],
                            [
                              {"td", [],
                               [
                                 {{:svg, "svg"}, [],
                                  [
                                    {{:svg, "td"}, [],
                                     [{{:svg, "foreignObject"}, [], [{"span", [], []}]}]}
                                  ]}
                               ]}
                            ]}
                         ]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 6
    end

    test "counts a cell start tag inside an SVG integration point as a parse error" do
      # Arrange
      html = "<table><tr><td><svg><desc><td></desc><circle>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"table", [],
                      [
                        {"tbody", [],
                         [
                           {"tr", [],
                            [
                              {"td", [], [{{:svg, "svg"}, [], [{{:svg, "desc"}, [], []}]}]},
                              {"td", [], [{"circle", [], []}]}
                            ]}
                         ]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 4
    end

    test "counts EOF in script HTML comment-like text as a parse error" do
      # Arrange
      html = ~s[FOO<script type="text/plain">'<!-- <sCrIpt>'</script>BAR]

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     "FOO",
                     {"script", [{"type", "text/plain"}], ["'<!-- <sCrIpt>'</script>BAR"]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "closes select when the current node is option" do
      # Arrange
      html = "<select><option>x</select>hello"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"select", [], [{"option", [], ["x"]}]}, "hello"]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "counts an end tag with attributes as one parse error" do
      # Arrange
      html = "<!DOCTYPE html><html><head></head><body><p></p class=\"a\" id=\"b\"></body></html>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], []}]}]}
             ] = nodes

      assert error_count == 1
    end

    test "counts a mismatched template end tag as a parse error" do
      # Arrange
      html = "<div><template><div><span></template><b>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"div", [],
                      [
                        {"template", [], [{:content, [{"div", [], [{"span", [], []}]}]}]},
                        {"b", [], []}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "counts EOF with an open select containing a template as a parse error" do
      # Arrange
      html = "<select><template>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"select", [], [{"template", [], [content: []]}]}]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "counts EOF in template after in-body content as a parse error" do
      # Arrange
      html = "<select><option></option><template><option>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"select", [],
                      [
                        {"option", [], []},
                        {"template", [], [content: [{"option", [], []}]]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "counts EOF in a template inside colgroup as a parse error" do
      # Arrange
      html = "<table><colgroup><template><col>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"table", [],
                      [
                        {"colgroup", [], [{"template", [], [content: [{"col", [], []}]]}]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "counts foster-parented start and end tags in a template row as parse errors" do
      # Arrange
      html = "<body><template><tr><div></div></tr></template>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"template", [], [content: [{"tr", [], []}, {"div", [], []}]]}]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "counts an html start tag inside a template colgroup as a parse error" do
      # Arrange
      html = "<html a=b><template><col></col><html b=c><col></col></template>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [{"a", "b"}],
                [
                  {"head", [], [{"template", [], [content: [{"col", [], []}, {"col", [], []}]]}]},
                  {"body", [], []}
                ]}
             ] = nodes

      assert error_count == 4
    end

    test "counts a colgroup start tag inside a template as a parse error" do
      # Arrange
      html = "<body><template><col><colgroup></template></body>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"template", [], [content: [{"col", [], []}]]}]}
                ]}
             ] = nodes

      assert error_count == 2
    end

    test "counts a frame start tag outside frameset as a parse error" do
      # Arrange
      html = "<html a=b><template><frame></frame><html b=c><frame></frame></template>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [{"a", "b"}],
                [
                  {"head", [], [{"template", [], [content: []]}]},
                  {"body", [], []}
                ]}
             ] = nodes

      assert error_count == 6
    end

    test "counts a tr start tag after non-table template content as a parse error" do
      # Arrange
      html = "<body><template></div><div>Foo</div><template></template><tr></tr>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"template", [],
                      [content: [{"div", [], ["Foo"]}, {"template", [], [content: []]}]]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 5
    end

    test "counts foster-parented characters in a template colgroup per character" do
      # Arrange
      html = "<body><template><col>Hello"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"template", [], [content: [{"col", [], []}]]}]}
                ]}
             ] = nodes

      assert error_count == 7
    end

    test "counts a nested a start tag inside a template table as a parse error" do
      # Arrange
      html = "<template><a><table><a>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [],
                   [
                     {"template", [], [content: [{"a", [], [{"a", [], []}, {"table", [], []}]}]]}
                   ]},
                  {"body", [], []}
                ]}
             ] = nodes

      assert error_count == 5
    end

    test "counts a col start tag after a table as a parse error" do
      # Arrange
      html = "<table><col><tbody><col><tr><col><td><col></table><col>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"table", [],
                      [
                        {"colgroup", [], [{"col", [], []}]},
                        {"tbody", [], []},
                        {"colgroup", [], [{"col", [], []}]},
                        {"tbody", [], [{"tr", [], []}]},
                        {"colgroup", [], [{"col", [], []}]},
                        {"tbody", [], [{"tr", [], [{"td", [], []}]}]},
                        {"colgroup", [], [{"col", [], []}]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "counts a colgroup start tag after a table as a parse error" do
      # Arrange
      html = "<table><colgroup><tbody><colgroup><tr><colgroup><td><colgroup></table><colgroup>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"table", [],
                      [
                        {"colgroup", [], []},
                        {"tbody", [], []},
                        {"colgroup", [], []},
                        {"tbody", [], [{"tr", [], []}]},
                        {"colgroup", [], []},
                        {"tbody", [], [{"tr", [], [{"td", [], []}]}]},
                        {"colgroup", [], []}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "counts SVG and HTML breakout in a colgroup as parse errors" do
      # Arrange
      html =
        "<!DOCTYPE html><body><table><colgroup><svg><g>foo</g><g>bar</g><p>baz</table><p>quux"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {{:svg, "svg"}, [],
                      [{{:svg, "g"}, [], ["foo"]}, {{:svg, "g"}, [], ["bar"]}]},
                     {"p", [], ["baz"]},
                     {"table", [], [{"colgroup", [], []}]},
                     {"p", [], ["quux"]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 6
    end

    test "counts rp inside ruby when the current node is not ruby as a parse error" do
      # Arrange
      html = "<!doctype html><ruby><div><span><rp>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"ruby", [], [{"div", [], [{"span", [], [{"rp", [], []}]}]}]}]}
                ]}
             ] = nodes

      assert error_count == 2
    end

    test "counts leftover characters after a frameset document as parse errors" do
      # Arrange
      html = "<!doctype html><html><frameset></frameset></html>abc"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"frameset", [], []}]}
             ] = nodes

      assert error_count == 3
    end

    test "counts non-whitespace in frameset per character" do
      # Arrange
      html = "<!DOCTYPE html><frameset>test"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"frameset", [], []}]}
             ] = nodes

      assert error_count == 5
    end

    test "counts mixed leftover characters after frameset per non-whitespace" do
      # Arrange
      html = "<!DOCTYPE html><frameset></frameset> te st"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"frameset", [], []}, "  "]}
             ] = nodes

      assert error_count == 4
    end

    test "counts a frameset end tag on the fragment html root as a parse error" do
      # Arrange
      html = "</frameset><frame>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "frameset")

      # Assert
      assert [{"frame", [], []}] = nodes
      assert error_count == 1
    end

    test "counts an html end tag in an html fragment as a parse error" do
      # Arrange
      html = "<body></body></html>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "html")

      # Assert
      assert [{"head", [], []}, {"body", [], []}] = nodes
      assert error_count == 1
    end

    test "counts a caption end tag when the current node is not caption as a parse error" do
      # Arrange
      html = "<table><caption><div></caption>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"table", [], [{"caption", [], [{"div", [], []}]}]}]}
                ]}
             ] = nodes

      assert error_count == 3
    end
  end

  describe "query/2" do
    test "delegates to Query.find/2" do
      # Arrange
      html = PureHTML.parse("<div><p class='intro'>Hello</p></div>")

      # Act
      result = PureHTML.query(html, ".intro")

      # Assert
      assert result == [{"p", [{"class", "intro"}], ["Hello"]}]
    end
  end

  describe "query_one/2" do
    test "delegates to Query.find_one/2" do
      # Arrange
      html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")

      # Act
      result = PureHTML.query_one(html, "li")

      # Assert
      assert result == {"li", [], ["A"]}
    end

    test "returns nil when no match" do
      # Arrange
      html = PureHTML.parse("<div><p>Hello</p></div>")

      # Act
      result = PureHTML.query_one(html, ".missing")

      # Assert
      assert result == nil
    end
  end

  describe "children/2" do
    test "delegates to Query.children/2" do
      # Arrange
      node = {"div", [], [{"p", [], ["Hello"]}]}

      # Act
      result = PureHTML.children(node)

      # Assert
      assert result == [{"p", [], ["Hello"]}]
    end
  end

  describe "text/2" do
    test "delegates to Query.text/2" do
      # Arrange
      html = PureHTML.parse("<p>Hello <strong>World</strong></p>")

      # Act
      result = PureHTML.text(html)

      # Assert
      assert result == "Hello World"
    end

    test "delegates with options" do
      # Arrange
      html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")

      # Act
      result = PureHTML.text(html, separator: ", ")

      # Assert
      assert result == "A, B"
    end
  end

  describe "attr/2" do
    test "delegates to Query.attr/2" do
      # Arrange
      node = {"a", [{"href", "/home"}], ["Home"]}

      # Act
      result = PureHTML.attr(node, "href")

      # Assert
      assert result == "/home"
    end
  end

  describe "attribute/2" do
    test "delegates to Query.attribute/2" do
      # Arrange
      nodes = [{"a", [{"href", "/one"}], []}, {"a", [{"href", "/two"}], []}]

      # Act
      result = PureHTML.attribute(nodes, "href")

      # Assert
      assert result == ["/one", "/two"]
    end
  end

  describe "attribute/3" do
    test "delegates to Query.attribute/3" do
      # Arrange
      html = PureHTML.parse("<div><a href='/link'>Link</a></div>")

      # Act
      result = PureHTML.attribute(html, "a", "href")

      # Assert
      assert result == ["/link"]
    end
  end

  defp valid_node?({tag, attrs, children}) when is_binary(tag) and is_list(attrs) do
    is_list(children) and Enum.all?(children, &valid_node?/1)
  end

  defp valid_node?(text) when is_binary(text), do: true
  defp valid_node?({:comment, _}), do: true
  defp valid_node?({:doctype, _, _, _}), do: true
  defp valid_node?(_), do: false

  defp html_fragment do
    gen all(parts <- list_of(html_part(), max_length: 10)) do
      Enum.join(parts)
    end
  end

  defp html_part do
    one_of([
      string(:alphanumeric, max_length: 20),
      gen_tag(),
      constant(" "),
      constant("\n")
    ])
  end

  defp gen_tag do
    tags = ~w(div span p a b i em strong ul li table tr td th br hr img input)

    gen all(
          tag <- member_of(tags),
          has_close <- boolean()
        ) do
      if has_close do
        "<#{tag}></#{tag}>"
      else
        "<#{tag}>"
      end
    end
  end
end
