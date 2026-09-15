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
    test "table at an HTML integration point is inserted there, not fostered past it" do
      # Arrange
      html = "<table><tr><td><svg><foreignObject><table>x"

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
                              {"td", [],
                               [
                                 {{:svg, "svg"}, [],
                                  [{{:svg, "foreignObject"}, [], ["x", {"table", [], []}]}]}
                               ]}
                            ]}
                         ]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "HTML breakout stops at a MathML text integration point" do
      # Arrange
      html = "<math><mi><svg><b>x"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {{:math, "math"}, [],
                      [{{:math, "mi"}, [], [{{:svg, "svg"}, [], []}, {"b", [], ["x"]}]}]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "html start tag in a template is ignored by the in-body rules" do
      # Arrange
      html = "<template><html lang=en></template>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], [{"template", [], [{:content, []}]}]}, {"body", [], []}]}
             ] =
               nodes

      assert error_count == 2
    end

    test "tr after a div in a template is ignored by the in-body rules" do
      # Arrange
      html = "<template><div></div><tr><td>x</template>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], [{"template", [], [{:content, [{"div", [], []}, "x"]}]}]},
                  {"body", [], []}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "body start tag in a template moves the template to in body" do
      # Arrange
      html = "<template><body><tr>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], [{"template", [], [{:content, []}]}]}, {"body", [], []}]}
             ] =
               nodes

      assert error_count == 4
    end

    test "noscript in a template with scripting on moves the template to in body" do
      # Arrange
      html = "<template><noscript></noscript><tr>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], [{"template", [], [{:content, [{"noscript", [], []}]}]}]},
                  {"body", [], []}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "html start tag in before head merges attributes and stays before head" do
      # Arrange
      html = "<html><html lang=en><head>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [{"lang", "en"}], [{"head", [], []}, {"body", [], []}]}] = nodes
      assert error_count == 2
    end

    test "html start tag in after head merges attributes without implying a body" do
      # Arrange
      html = "<head></head><html lang=en><body>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [{"lang", "en"}], [{"head", [], []}, {"body", [], []}]}] = nodes
      assert error_count == 2
    end

    test "comment after an html start tag in after body is a child of html" do
      # Arrange
      html = "<body></body><html><!--c-->"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], []}, {:comment, "c"}]}] = nodes
      assert error_count == 2
    end

    test "comment after an html start tag in after after body is a document child" do
      # Arrange
      html = "<body></body></html><html><!--c-->"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], []}]}, {:comment, "c"}] = nodes
      assert error_count == 2
    end

    test "HTML 4.01 Strict is no-quirks, so a table closes the p" do
      # Arrange
      public_id = "-//W3C//DTD HTML 4.01//EN"
      system_id = "http://www.w3.org/TR/html4/strict.dtd"
      html = "<!DOCTYPE HTML PUBLIC \"#{public_id}\" \"#{system_id}\"><p><table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", ^public_id, ^system_id},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], []}, {"table", [], []}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "XHTML 1.0 Strict is no-quirks, so a table closes the p" do
      # Arrange
      public_id = "-//W3C//DTD XHTML 1.0 Strict//EN"
      system_id = "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"
      html = "<!DOCTYPE html PUBLIC \"#{public_id}\" \"#{system_id}\"><p><table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", ^public_id, ^system_id},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], []}, {"table", [], []}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "HTML 4.01 Transitional without a system id is quirks, so the table nests in the p" do
      # Arrange
      public_id = "-//W3C//DTD HTML 4.01 Transitional//EN"
      html = "<!DOCTYPE HTML PUBLIC \"#{public_id}\"><p><table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", ^public_id, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], [{"table", [], []}]}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "HTML 4.01 Transitional with a system id is limited-quirks, so a table closes the p" do
      # Arrange
      public_id = "-//W3C//DTD HTML 4.01 Transitional//EN"
      system_id = "http://www.w3.org/TR/html4/loose.dtd"
      html = "<!DOCTYPE HTML PUBLIC \"#{public_id}\" \"#{system_id}\"><p><table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", ^public_id, ^system_id},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], []}, {"table", [], []}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "quirks public identifiers compare ASCII case-insensitively" do
      # Arrange
      public_id = "-//w3c//dtd html 4.01 transitional//en"
      html = "<!DOCTYPE html PUBLIC \"#{public_id}\"><p><table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", ^public_id, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], [{"table", [], []}]}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "drops NUL in body with a tokenizer and a tree builder error" do
      # Arrange
      html = "<p>a\0b</p>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["ab"]}]}]}] = nodes
      assert error_count == 3
    end

    test "replaces NUL in foreign content with U+FFFD" do
      # Arrange
      html = "<svg>a\0b</svg>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{{:svg, "svg"}, [], ["a\uFFFDb"]}]}]}] =
               nodes

      assert error_count == 3
    end

    test "ignores NUL in frameset without inserting a text node" do
      # Arrange
      html = "<frameset>\0"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"frameset", [], []}]}] = nodes
      assert error_count == 4
    end

    test "treats NBSP before the first tag as a character, not whitespace" do
      # Arrange
      html = "\u00A0<p>x"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["\u00A0", {"p", [], ["x"]}]}]}] =
               nodes

      assert error_count == 1
    end

    test "fosters NBSP out of a table as a non-whitespace character" do
      # Arrange
      html = "<table>\u00A0<tr><td>x</table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   ["\u00A0", {"table", [], [{"tbody", [], [{"tr", [], [{"td", [], ["x"]}]}]}]}]}
                ]}
             ] = nodes

      assert error_count == 2
    end

    test "treats NBSP in noscript with scripting off as in-body content" do
      # Arrange
      html = "<noscript>\u00A0<p>x"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, scripting: false)

      # Assert
      assert [
               {"html", [],
                [{"head", [], [{"noscript", [], []}]}, {"body", [], ["\u00A0", {"p", [], ["x"]}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "NBSP in body sets frameset-ok to not ok" do
      # Arrange
      html = "\u00A0<frameset></frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["\u00A0"]}]}] = nodes
      assert error_count == 3
    end

    test "ignores U+0000 in body and keeps frameset-ok" do
      # Arrange
      html = "<html>\0<frameset></frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"frameset", [], []}]}] = nodes
      assert error_count == 4
    end

    test "drops U+0000 from body text with one error per character" do
      # Arrange
      html = "<html>a\0a<frameset></frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["aa"]}]}] = nodes
      assert error_count == 5
    end

    test "drops U+0000 from pending table text before foster parenting" do
      # Arrange
      html = "<body><table>\0filler\0text\0"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["fillertext", {"table", [], []}]}]}] =
               nodes

      assert error_count == 18
    end

    test "replaces U+0000 in foreign content without touching frameset-ok" do
      # Arrange
      html = "<svg>\0 </svg><frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"frameset", [], []}]}] = nodes
      assert error_count == 5
    end

    test "replaces U+0000 in foreign content with U+FFFD" do
      # Arrange
      html = "<svg>\0a</svg><frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{{:svg, "svg"}, [], ["\uFFFDa"]}]}]}] =
               nodes

      assert error_count == 4
    end

    test "keeps the case of the character after < in script data escaped" do
      # Arrange
      html = "<script type=\"data\"><!-- foo-<S"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], [{"script", [{"type", "data"}], ["<!-- foo-<S"]}]},
                  {"body", [], []}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "inserts leading whitespace in a colgroup once and reprocesses the rest" do
      # Arrange
      html = "<table><colgroup> foo</colgroup></table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], ["foo", {"table", [], [{"colgroup", [], [" "]}]}]}
                ]}
             ] = nodes

      assert error_count == 5
    end

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

    test "processes characters at a MathML text integration point with the current insertion mode" do
      # Arrange
      html = "<!DOCTYPE html><body><table><math><mi>foo</mi></math></table>"

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
                     {{:math, "math"}, [], [{{:math, "mi"}, [], ["foo"]}]},
                     {"table", [], []}
                   ]}
                ]}
             ] = nodes

      # <math> in table, then one in-table character error per character of "foo",
      # because mi is a MathML text integration point and the current mode is in table.
      assert error_count == 4
    end

    test "reprocesses an HTML breakout tag in foreign content with the current insertion mode" do
      # Arrange
      html = "<!DOCTYPE html><body><table><select><svg><g>foo</g><g>bar</g><p>baz</table><p>quux"

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
                     {"select", [],
                      [
                        {{:svg, "svg"}, [],
                         [{{:svg, "g"}, [], ["foo"]}, {{:svg, "g"}, [], ["bar"]}]},
                        {"p", [], ["baz"]}
                      ]},
                     {"table", [], []},
                     {"p", [], ["quux"]}
                   ]}
                ]}
             ] = nodes

      # select and svg in table; <p> once as a foreign-content breakout and once when
      # reprocessed in table; one per character of "baz".
      assert error_count == 7
    end

    test "ignores a foreign end tag that reaches in body at a special element" do
      # Arrange
      html = "<math><annotation-xml></svg>x"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{{:math, "math"}, [], [{{:math, "annotation-xml"}, [], ["x"]}]}]}
                ]}
             ] = nodes

      # No doctype; the foreign end-tag walk finds no svg (parse error) and hands the
      # token to in body, where any-other-end-tag stops at the special annotation-xml
      # (parse error); math is still open at EOF.
      assert error_count == 4
    end

    test "counts an unacknowledged self-closing flag on a non-void start tag" do
      # Arrange
      html = "<ul><li><div id='foo'/>A</li><li>B<div>C</div></li></ul>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"ul", [],
                      [
                        {"li", [], [{"div", [{"id", "foo"}], ["A"]}]},
                        {"li", [], ["B", {"div", [], ["C"]}]}
                      ]}
                   ]}
                ]}
             ] = nodes

      # No doctype; <div/> is a non-void start tag whose self-closing flag is never
      # acknowledged; </li> arrives with div as the current node.
      assert error_count == 3
    end

    test "treats a cell end tag in body as any other end tag" do
      # Arrange
      html = "<!DOCTYPE html><div></td>x"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"div", [], ["x"]}]}]}
             ] = nodes

      # </td> walks to the special div (parse error, ignored); div is open at EOF.
      assert error_count == 2
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

    test "does not count a doctype closed before any name as a missing whitespace" do
      # Arrange
      html = "<!DOCTYPE>Hello"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{:doctype, _, _, _}, {"html", [], [{"head", [], []}, {"body", [], ["Hello"]}]}] =
               nodes

      assert error_count == 2
    end

    test "does not count an ampersand followed by an unknown name without a semicolon" do
      # Arrange
      html = "&x-test"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["&x-test"]}]}] = nodes
      assert error_count == 1
    end

    test "does not count an unknown name without a semicolon inside an attribute value" do
      # Arrange
      html = ~s(<div bar="ZZ&prod_id=23"></div>)

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], []}, {"body", [], [{"div", [{"bar", "ZZ&prod_id=23"}], []}]}]}
             ] =
               nodes

      assert error_count == 1
    end

    test "does not count whitespace in a table section when the current node is a template" do
      # Arrange
      html = "<!DOCTYPE HTML><template> <tr> <td>cell</td> </tr> </template>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", _, _},
               {"html", [],
                [
                  {"head", [],
                   [
                     {"template", [],
                      [content: [" ", {"tr", [], [" ", {"td", [], ["cell"]}, " "]}, " "]]}
                   ]},
                  {"body", [], []}
                ]}
             ] = nodes

      assert error_count == 0
    end

    test "does not count a cell end tag that closes an open paragraph by implied end tags" do
      # Arrange
      html =
        "<!DOCTYPE html><body><table><tbody><tr><td><svg><g>foo</g><g>bar</g></svg><p>baz</td></tr></tbody></table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", _, _},
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
                                 {{:svg, "svg"}, [],
                                  [{{:svg, "g"}, [], ["foo"]}, {{:svg, "g"}, [], ["bar"]}]},
                                 {"p", [], ["baz"]}
                               ]}
                            ]}
                         ]}
                      ]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 0
    end

    test "returns to the row after foster parenting characters from a table row" do
      # Arrange
      html =
        "<!DOCTYPE html><body><table><tbody><tr><math><mi>foo</mi><mi>bar</mi></math></tr></tbody></table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", _, _},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {{:math, "math"}, [],
                      [{{:math, "mi"}, [], ["foo"]}, {{:math, "mi"}, [], ["bar"]}]},
                     {"table", [], [{"tbody", [], [{"tr", [], []}]}]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 7
    end

    test "returns to the table after a title fostered out of it" do
      # Arrange
      html = "<!doctype html><table><title>X</title></table>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", _, _},
               {"html", [],
                [{"head", [], []}, {"body", [], [{"title", [], ["X"]}, {"table", [], []}]}]}
             ] = nodes

      assert error_count == 1
    end

    test "does not count a dt start tag that closes only the open dd" do
      # Arrange
      html = "<dd><dd><dt><dt><dd><li><li>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"dd", [], []},
                     {"dd", [], []},
                     {"dt", [], []},
                     {"dt", [], []},
                     {"dd", [], [{"li", [], []}, {"li", [], []}]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "does not count an rt start tag when the current node becomes an rtc" do
      # Arrange
      html = "<html><ruby>a<rtc>b<rt>c<rt>d</ruby></html>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [{"ruby", [], ["a", {"rtc", [], ["b", {"rt", [], ["c"]}, {"rt", [], ["d"]}]}]}]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "does not count a formatting end tag whose element the adoption agency has already removed" do
      # Arrange
      html = "<b><b><b><b>x</b></b></b></b>y"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"b", [], [{"b", [], [{"b", [], [{"b", [], ["x"]}]}]}]}, "y"]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "does not switch the tokenizer for a plaintext start tag ignored in frameset" do
      # Arrange
      html = "<!doctype html><frameset><plaintext></plaintext>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{:doctype, "html", _, _}, {"html", [], [{"head", [], []}, {"frameset", [], []}]}] =
               nodes

      assert error_count == 3
    end

    test "does not count closing a p whose implied end tags reach the p" do
      # Arrange
      html = "<p><option>x<div>y"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"p", [], [{"option", [], ["x"]}]}, {"div", [], ["y"]}]}
                ]}
             ] = nodes

      # no doctype, and the div still open at EOF
      assert error_count == 2
    end

    test "keeps frameset-ok after an rb element" do
      # Arrange
      html = "<!DOCTYPE html><rb></rb><frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{:doctype, "html", _, _}, {"html", [], [{"head", [], []}, {"frameset", [], []}]}] =
               nodes

      # the frameset start tag in body, and EOF inside the frameset
      assert error_count == 2
    end

    test "parses a CDATA section inside an SVG title as text" do
      # Arrange
      html = "<!DOCTYPE html><svg><title><![CDATA[x]]></title></svg>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {:doctype, "html", _, _},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{{:svg, "svg"}, [], [{{:svg, "title"}, [], ["x"]}]}]}
                ]}
             ] = nodes

      assert error_count == 0
    end

    test "reconstructs the active formatting elements before inserting an svg element" do
      # Arrange
      html = "<p><b><p><svg></svg>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [{"p", [], [{"b", [], []}]}, {"p", [], [{"b", [], [{{:svg, "svg"}, [], []}]}]}]}
                ]}
             ] = nodes

      # no doctype, the b still open when the second p closes the first, the
      # reconstructed b open at EOF
      assert error_count == 3
    end

    test "decodes a numeric character reference in title RCDATA" do
      # Arrange
      html = "<title>&#65;</title>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], [{"title", [], ["A"]}]}, {"body", [], []}]}] = nodes
      assert error_count == 1
    end

    test "failed numeric reference in textarea RCDATA stays as text" do
      # Arrange
      html = "<textarea>&#;</textarea>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"textarea", [], ["&#;"]}]}]}] = nodes
      assert error_count == 2
    end

    test "replaces invalid UTF-8 in a tag name with U+FFFD" do
      # Arrange
      html = "<div" <> <<0x80>> <> ">"

      # Act
      {nodes, _error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"div\uFFFD", [], []}]}]}] = nodes
    end

    test "replaces invalid UTF-8 in body text with U+FFFD" do
      # Arrange
      html = "a" <> <<0xFF>> <> "b"

      # Act
      {nodes, _error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], ["a\uFFFDb"]}]}] = nodes
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

  describe "to_html/2" do
    test "serializes xlink:href on an SVG element" do
      # Arrange
      html = "<svg><a xlink:href=foo></a></svg>"

      # Act
      result =
        html
        |> PureHTML.parse()
        |> PureHTML.to_html()

      # Assert
      assert result =~ "xlink:href=foo"
    end

    test "serializes an xmlns attribute on an SVG element by its local name" do
      # Arrange
      html = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"

      # Act
      nodes = PureHTML.parse(html)
      result = PureHTML.to_html(nodes)

      # Assert
      assert [{"html", [], [_head, {"body", [], [{{:svg, "svg"}, attrs, []}]}]}] = nodes
      assert [{{:xmlns, "xmlns"}, "http://www.w3.org/2000/svg"}] = attrs
      assert result =~ "<svg xmlns="
      refute result =~ "xmlns:"
    end

    test "serializes a SYSTEM about:legacy-compat doctype by name only" do
      # Arrange
      html = "<!DOCTYPE html SYSTEM \"about:legacy-compat\">"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{:doctype, "html", nil, "about:legacy-compat"} | _] = nodes
      assert error_count == 0
      assert String.starts_with?(PureHTML.to_html(nodes), "<!DOCTYPE html>")
    end

    test "serializes a doctype with a missing name" do
      # Arrange
      html = "<!DOCTYPE>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{:doctype, nil, nil, nil} | _] = nodes
      assert error_count == 2
      assert String.starts_with?(PureHTML.to_html(nodes), "<!DOCTYPE >")
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
