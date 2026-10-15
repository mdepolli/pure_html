defmodule PureHTMLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest PureHTML

  describe "parse/2" do
    test "a :context namespace other than svg or math raises ArgumentError" do
      assert_raise ArgumentError, ~r/context/, fn -> PureHTML.parse("x", context: "foo bar") end
      assert_raise ArgumentError, ~r/context/, fn -> PureHTML.parse("x", context: "html div") end
    end

    test "an empty :context name raises ArgumentError" do
      assert_raise ArgumentError, ~r/context/, fn -> PureHTML.parse("x", context: "") end
      assert_raise ArgumentError, ~r/context/, fn -> PureHTML.parse("x", context: "svg ") end
    end

    test "a :context of more than a namespace and a local name raises ArgumentError" do
      assert_raise ArgumentError, ~r/context/, fn -> PureHTML.parse("x", context: "svg a b") end
    end

    test "a foreign context keeps the case of its local name" do
      assert PureHTML.parse("<x>", context: "svg foreignObject") == [{"x", [], []}]
    end

    test "a bare svg :context is an HTML element, as the html5lib format reads it" do
      assert PureHTML.parse("<x>", context: "svg") == [{"x", [], []}]
    end

    # DOM's valid element local name: an ASCII alpha, then anything but ASCII
    # whitespace, NUL, "/", or ">"; or ":", "_", or a non-ASCII code point,
    # then ASCII alphanumerics, "-", ".", ":", "_", or non-ASCII code points.
    test "a :context name that is not a valid element local name raises ArgumentError" do
      # Arrange
      contexts = [
        "1td",
        "-x",
        "a/b",
        "a>b",
        "a\0b",
        "a\tb",
        ":a!",
        "éb!",
        "svg 1x",
        "math a>b",
        "a" <> <<255>>
      ]

      # Act + Assert
      for context <- contexts do
        assert_raise ArgumentError, ~r/context/, fn -> PureHTML.parse("x", context: context) end
      end
    end

    test "raises ArgumentError for an unknown option" do
      assert_raise ArgumentError, ~r/contxt/, fn -> PureHTML.parse("x", contxt: "td") end
    end
  end

  describe "parse_with_errors/2" do
    test "a doctype after pre is not the ignored line feed" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors("<!DOCTYPE html><pre><!DOCTYPE html>\nX</pre>")

      # Assert: pre ignores only a next token that is a LF; the doctype is the
      # next token, so the LF that follows it is text. One error: the doctype
      # in body. (Without </pre>, EOF with pre open would add a second.)
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"pre", [], ["\nX"]}]}]}
             ] = nodes

      assert error_count == 1
    end

    test "selectedcontent takes the last selected option when multiple is absent" do
      # Arrange
      html = "<select><button><selectedcontent></button><option selected>X<option selected>Y"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"button", [], [{"selectedcontent", [], ["Y"]}]},
                {"option", [{"selected", ""}], ["X"]},
                {"option", [{"selected", ""}], ["Y"]}
              ]} = select

      assert error_count == 3
    end

    test "selectedcontent takes an option inside an optgroup" do
      # Arrange
      html = "<select><button><selectedcontent></button><optgroup><option>X"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"button", [], [{"selectedcontent", [], ["X"]}]},
                {"optgroup", [], [{"option", [], ["X"]}]}
              ]} = select

      assert error_count == 3
    end

    test "selectedcontent stays empty when the select has multiple" do
      # Arrange
      html = "<select multiple><button><selectedcontent></button><option>X"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [select]}]}] = nodes

      assert {"select", [{"multiple", ""}],
              [{"button", [], [{"selectedcontent", [], []}]}, {"option", [], ["X"]}]} = select

      assert error_count == 3
    end

    test "selectedcontent skips a disabled option when picking the first" do
      # Arrange
      html = "<select><button><selectedcontent></button><option disabled>X<option>Y"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"button", [], [{"selectedcontent", [], ["Y"]}]},
                {"option", [{"disabled", ""}], ["X"]},
                {"option", [], ["Y"]}
              ]} = select

      assert error_count == 3
    end

    test "selectedcontent stays empty when the display size is not 1" do
      # Arrange
      html = "<select size=2><button><selectedcontent></button><option>X"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [select]}]}] = nodes

      assert {"select", [{"size", "2"}],
              [{"button", [], [{"selectedcontent", [], []}]}, {"option", [], ["X"]}]} = select

      assert error_count == 3
    end

    test "selectedcontent is found deeper than the select's child" do
      # Arrange
      html = "<select><div><button><selectedcontent></button></div><option>X"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"div", [], [{"button", [], [{"selectedcontent", [], ["X"]}]}]},
                {"option", [], ["X"]}
              ]} = select

      assert error_count == 3
    end

    test "selectedcontent inserted after the selected option is filled on insertion" do
      # Arrange
      html = "<select><option>X</option><button><selectedcontent>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [{"option", [], ["X"]}, {"button", [], [{"selectedcontent", [], ["X"]}]}]} = select

      assert error_count == 2
    end

    test "param does not reconstruct the active formatting elements" do
      # Arrange
      html = "<p><b></p><param>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], []}, {"body", [], [{"p", [], [{"b", [], []}]}, {"param", [], []}]}]}
             ] =
               nodes

      assert error_count == 2
    end

    test "br reconstructs the active formatting elements" do
      # Arrange
      html = "<p><b></p><br>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"p", [], [{"b", [], []}]}, {"b", [], [{"br", [], []}]}]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "br end tag sets frameset-ok to not ok" do
      # Arrange
      html = "</br><frameset>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"br", [], []}]}]}] = nodes
      assert error_count == 3
    end

    test "pre keeps a LF that is not the token right after its start tag" do
      # Arrange
      html = "<pre></b>\nx</pre>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"pre", [], ["\nx"]}]}]}] = nodes
      assert error_count == 2
    end

    test "attributes stay in source order" do
      # Arrange / Act
      {nodes, _} = PureHTML.parse_with_errors("<p title=t class=c id=i>")

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], [{"p", attrs, []}]}]}] = nodes
      assert attrs == [{"title", "t"}, {"class", "c"}, {"id", "i"}]
      assert PureHTML.to_html(nodes) =~ ~s(<p title="t" class="c" id="i"></p>)
    end

    test "a second html start tag appends missing attributes" do
      # Arrange / Act
      {nodes, _} = PureHTML.parse_with_errors("<html a=1><html b=2 a=3>")

      # Assert
      assert [{"html", attrs, [{"head", [], []}, {"body", [], []}]}] = nodes
      assert attrs == [{"a", "1"}, {"b", "2"}]
    end

    test "a second body start tag appends missing attributes" do
      # Arrange / Act
      {nodes, _} = PureHTML.parse_with_errors("<body a=1><body b=2 a=3>")

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", attrs, []}]}] = nodes
      assert attrs == [{"a", "1"}, {"b", "2"}]
    end

    test "CDATA in an HTML fragment context is a bogus comment" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<![CDATA[x]]>", context: "div")

      # Assert
      assert [{:comment, "[CDATA[x]]"}] = nodes
      assert error_count == 1
    end

    test "CDATA in an SVG fragment context is text" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<![CDATA[x]]>", context: "svg svg")

      # Assert
      assert ["x"] = nodes
      assert error_count == 0
    end

    test "head fragment context resets to in body because last is true" do
      # Arrange
      html = "<title>x</title>y"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "head")

      # Assert
      assert [{"title", [], ["x"]}, "y"] = nodes
      assert error_count == 0
    end

    test "td fragment context resets to in body because last is true" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("x", context: "td")

      # Assert
      assert ["x"] = nodes
      assert error_count == 0
    end

    test "noscript fragment context with scripting on resets to in body" do
      # Arrange
      html = "<b>x"

      # Act
      {nodes, error_count} =
        PureHTML.parse_with_errors(html, context: "noscript", scripting: true)

      # Assert
      assert ["<b>x"] = nodes
      assert error_count == 0
    end

    test "frameset end tag in a frameset fragment stays in frameset" do
      # Arrange
      html = "<frameset></frameset><frame>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "frameset")

      # Assert
      assert [{"frameset", [], []}, {"frame", [], []}] = nodes
      assert error_count == 0
    end

    test "whitespace after body reconstructs the active formatting elements" do
      # Arrange
      html = "<body><p><b></p></body> "

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], []}, {"body", [], [{"p", [], [{"b", [], []}]}, {"b", [], [" "]}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "whitespace after after body reconstructs the active formatting elements" do
      # Arrange
      html = "<body><p><b></p></body></html> "

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], []}, {"body", [], [{"p", [], [{"b", [], []}]}, {"b", [], [" "]}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "whitespace after after frameset reconstructs the active formatting elements" do
      # Arrange
      html = "<b><frameset></frameset></html> "

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [{"html", [], [{"head", [], []}, {"frameset", [], []}, {"b", [], [" "]}]}] = nodes
      assert error_count == 2
    end

    test "non-hidden input in a table goes through the in-body rules and is fostered" do
      # Arrange
      html = "<table><input type=text>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"input", [{"type", "text"}], []}, {"table", [], []}]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "hidden input in a table is inserted in the table" do
      # Arrange
      html = "<table><input type=hidden>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"table", [], [{"input", [{"type", "hidden"}], []}]}]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "br end tag in a table acts as a br start tag under the in-body rules" do
      # Arrange
      html = "<table><b></br>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [{"head", [], []}, {"body", [], [{"b", [], [{"br", [], []}]}, {"table", [], []}]}]}
             ] = nodes

      assert error_count == 5
    end

    test "form in a table inside template contents is inserted despite an open form" do
      # Arrange
      html = "<form><template><table><form>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [
                     {"form", [],
                      [{"template", [], [{:content, [{"table", [], [{"form", [], []}]}]}]}]}
                   ]}
                ]}
             ] = nodes

      assert error_count == 4
    end

    test "button start tag closes an open button in default scope with implied end tags" do
      # Arrange
      html = "<button><b><button>x"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [{"button", [], [{"b", [], []}]}, {"b", [], [{"button", [], ["x"]}]}]}
                ]}
             ] = nodes

      assert error_count == 3
    end

    test "button start tag does not close a button beyond a default scope boundary" do
      # Arrange
      html = "<button><object><button>x"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"button", [], [{"object", [], [{"button", [], ["x"]}]}]}]}
                ]}
             ] = nodes

      assert error_count == 2
    end

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
      assert error_count == 3
    end

    test "a li end tag inside select does not close the li outside" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<li><select></li>x")

      # Assert: select is a list-item scope boundary, so </li> is a parse
      # error and is ignored; x lands in the select.
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"li", [], [{"select", [], ["x"]}]}]}
                ]}
             ] = nodes

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
      assert [
               {:doctype, nil, nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], ["Hello"]}]}
             ] =
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

    test "a PI after a character is a child of body" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("x<?php y?>")

      # Assert
      assert [
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], ["x", {:pi, "php", "y"}]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "a PI in a fragment is a child of the context element" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<?php y?>", context: "div")

      # Assert
      assert [{:pi, "php", "y"}] = nodes
      assert error_count == 0
    end

    test "php processing instruction becomes a PI node, child of the Document" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<?php echo 1; ?>")

      # Assert
      assert [
               {:pi, "php", "echo 1; "},
               {"html", [], [{"head", [], []}, {"body", [], []}]}
             ] = nodes

      # eof-in-processing-instruction does not fire; the PI closed. Initial EOF
      # is anything else: one missing-doctype error.
      assert error_count == 1
    end

    test "xml processing instruction stays a comment" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<?xml version=\"1.0\"?>")

      # Assert
      assert [
               {:comment, "?xml version=\"1.0\"?"},
               {"html", [], [{"head", [], []}, {"body", [], []}]}
             ] = nodes

      # disallowed-processing-instruction-target, then initial EOF / missing-doctype.
      assert error_count == 2
    end

    test "<? at EOF is not a comment" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<?")

      # Assert
      assert [{"html", [], [{"head", [], []}, {"body", [], []}]}] = nodes
      # eof-in-processing-instruction plus initial EOF / missing-doctype.
      assert error_count == 2
    end

    test "whitespace then text after </html> goes to body" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors("<!DOCTYPE html><html><body></body></html> a")

      # Assert: after after body sends the space to in body; "a" is anything
      # else, a parse error that switches to in body and reprocesses.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [" a"]}]}
             ] = nodes

      assert error_count == 1
    end

    test "dialog is not a furthest block for the adoption agency" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<!DOCTYPE html><a><dialog>x</a>y")

      # Assert: dialog is not special, so </a> has no furthest block and pops
      # through a. One error: a is not the current node.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"a", [], [{"dialog", [], ["x"]}]}, "y"]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "an li start tag walks past an open dialog to close the li" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<!DOCTYPE html><li><dialog><li>z")

      # Assert: dialog is not special, so the walk reaches the li and closes it.
      # One error: the current node is dialog, not li.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"li", [], [{"dialog", [], []}]}, {"li", [], ["z"]}]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "Noah's Ark matches attributes in any order" do
      # Arrange
      html = "<!DOCTYPE html><p><b x=1 y=2><b y=2 x=1><b x=1 y=2><b y=2 x=1><p>t"
      xy = [{"x", "1"}, {"y", "2"}]
      yx = [{"y", "2"}, {"x", "1"}]

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert: the fourth b pushes out the first, so the second p reconstructs
      # three. Errors: the second p closes a p whose current node is b; b is
      # open at EOF.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [_first_p, second_p]}]}
             ] = nodes

      assert {"p", [], [{"b", ^yx, [{"b", ^xy, [{"b", ^yx, ["t"]}]}]}]} = second_p
      assert error_count == 2
    end

    test "a form in a template fragment does not set the form element pointer" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<form><form>", context: "template")

      # Assert: a template context means the parser is parsing template
      # contents, so neither form sets the pointer and the second is inserted.
      assert [{"form", [], [{"form", [], []}]}] = nodes
      assert error_count == 0
    end

    test "a form end tag in a template fragment pops through the form" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors("<form><div></form>x", context: "template")

      # Assert: parsing template contents, </form> pops elements until a form
      # has been popped, so "x" lands after it. One error: the current node is
      # div.
      assert [{"form", [], [{"div", [], []}]}, "x"] = nodes
      assert error_count == 1
    end

    test "a form end tag with a null form element pointer is ignored" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors("<!DOCTYPE html><form><table></form></table></form>x")

      # Assert: the first </form> clears the pointer but the table keeps the
      # form out of scope, so the form stays open. The second </form> finds a
      # null pointer: a parse error, and the token is ignored. Errors: </form>
      # in table, the form not in scope, the null pointer, the form open at EOF.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"form", [], [{"table", [], []}, "x"]}]}
                ]}
             ] = nodes

      assert error_count == 4
    end

    test "a force-quirks doctype named html counts only the tokenizer's error" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<!DOCTYPE html PUBLIC><p>")

      # Assert: missing-doctype-public-identifier from the tokenizer. Initial
      # mode's condition is the name, the public id, and the system id only.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], [{"p", [], []}]}]}
             ] = nodes

      assert error_count == 1
    end

    test "in table text counts a parse error per code point, not per grapheme" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<!DOCTYPE html><table>e\u0301</table>")

      # Assert: e and U+0301 are two character tokens, each fostered with a
      # parse error.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"body", [], ["e\u0301", {"table", [], []}]}]}
             ] = nodes

      assert error_count == 2
    end

    test "in table counts a parse error per code point outside a table context" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<!DOCTYPE html><table><div>e\u0301")

      # Assert: the fostered div is the current node, so each character is the
      # anything else entry. Errors: div, e, U+0301, the open elements at EOF.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"div", [], ["e\u0301"]}, {"table", [], []}]}
                ]}
             ] = nodes

      assert error_count == 4
    end

    test "in column group counts a parse error per code point" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("e\u0301", context: "colgroup")

      # Assert: the current node is not a colgroup, so each character token is
      # a parse error and is ignored.
      assert [] = nodes
      assert error_count == 2
    end

    test "in frameset counts a parse error per code point" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors("<!DOCTYPE html><frameset>e\u0301</frameset>")

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"frameset", [], []}]}
             ] = nodes

      assert error_count == 2
    end

    test "after frameset counts a parse error per code point" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors("<!DOCTYPE html><frameset></frameset>e\u0301")

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"frameset", [], []}]}
             ] = nodes

      assert error_count == 2
    end

    test "after after frameset counts a parse error per code point" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors("<!DOCTYPE html><frameset></frameset></html>e\u0301")

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], []}, {"frameset", [], []}]}
             ] = nodes

      assert error_count == 2
    end

    test "an SVG tr fragment context resets the insertion mode to in body" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<div><td>y", context: "svg tr")

      # Assert: the reset steps name HTML elements, so an SVG tr is none of
      # them and the last step is in body. Errors: div breaks out of foreign
      # content, in body ignores td, div is open at EOF.
      assert [{"div", [], ["y"]}] = nodes
      assert error_count == 3
    end

    test "an SVG template fragment context pushes no template insertion mode" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<div></div>", context: "svg template")

      # Assert: only an HTML template context seeds in template, so the reset
      # ends in body. One error: div breaks out of foreign content once. In
      # template would have reprocessed it through the dispatcher, breaking out
      # a second time.
      assert [{"div", [], []}] = nodes
      assert error_count == 1
    end

    test "an svg xmlns attribute that is not the SVG namespace is a parse error" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors(~s(<!DOCTYPE html><svg xmlns="http://example.com/"></svg>))

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [],
                   [{{:svg, "svg"}, [{{:xmlns, "xmlns"}, "http://example.com/"}], []}]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "a math xmlns:xlink attribute that is not the XLink namespace is a parse error" do
      # Arrange / Act
      {nodes, error_count} =
        PureHTML.parse_with_errors(~s(<!DOCTYPE html><math xmlns:xlink="x"></math>))

      # Assert
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{{:math, "math"}, [{{:xmlns, "xlink"}, "x"}], []}]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "an unacknowledged self-closing title in head is a parse error" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<!DOCTYPE html><title/>x</title>")

      # Assert: in head's RCDATA entry does not acknowledge the flag.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [], [{"head", [], [{"title", [], ["x"]}]}, {"body", [], []}]}
             ] = nodes

      assert error_count == 1
    end

    test "an unacknowledged self-closing tr in a table is a parse error" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<!DOCTYPE html><table><tr/></table>")

      # Assert: in table body inserts the tr without acknowledging the flag.
      assert [
               {:doctype, "html", nil, nil},
               {"html", [],
                [
                  {"head", [], []},
                  {"body", [], [{"table", [], [{"tbody", [], [{"tr", [], []}]}]}]}
                ]}
             ] = nodes

      assert error_count == 1
    end

    test "the void element and foreign element entries acknowledge the self-closing flag" do
      # Arrange: one input per entry that acknowledges the flag, with the
      # errors the entries themselves report.
      cases = [
        {"<!DOCTYPE html><meta/><link/><base/><basefont/><bgsound/>", 0},
        {"<!DOCTYPE html><br/><img/><input/><hr/><wbr/><area/><embed/><keygen/>", 0},
        {"<!DOCTYPE html><param/><source/><track/><image/>", 1},
        {"<!DOCTYPE html><table><input type=hidden /></table>", 1},
        {"<!DOCTYPE html><table><colgroup><col/></colgroup></table>", 0},
        {"<!DOCTYPE html><frameset><frame/></frameset>", 0},
        {"<!DOCTYPE html><svg/><math/><svg><path/></svg>", 0}
      ]

      # Act + Assert: <image> is a parse error of its own; a hidden input in
      # a table is too.
      for {html, expected} <- cases do
        {_nodes, error_count} = PureHTML.parse_with_errors(html)
        assert {html, error_count} == {html, expected}
      end
    end

    test "every enabled selectedcontent in a select takes the selected option" do
      # Arrange
      html = """
      <!DOCTYPE html><select><button><selectedcontent></selectedcontent>\
      <selectedcontent></selectedcontent></button><option>A</option></select>\
      """

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert
      assert [_doctype, {"html", [], [_head, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"button", [], [{"selectedcontent", [], ["A"]}, {"selectedcontent", [], ["A"]}]},
                {"option", [], ["A"]}
              ]} = select

      assert error_count == 0
    end

    test "a disabled selectedcontent does not stop a later one from updating" do
      # Arrange
      html = """
      <!DOCTYPE html><select><option>A<selectedcontent></selectedcontent></option>\
      <button><selectedcontent></selectedcontent></button></select>\
      """

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert: the first is inside an option, so disabled. The second clones
      # the option's children, the disabled selectedcontent among them.
      assert [_doctype, {"html", [], [_head, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"option", [], ["A", {"selectedcontent", [], []}]},
                {"button", [], [{"selectedcontent", [], ["A", {"selectedcontent", [], []}]}]}
              ]} = select

      assert error_count == 0
    end

    test "an option above the select disables its selectedcontent" do
      # Arrange
      html = """
      <!DOCTYPE html><option><select><button><selectedcontent></selectedcontent>\
      </button><option>A</option></select>\
      """

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert: disabledness walks every ancestor, not only those below the
      # nearest select.
      assert [_doctype, {"html", [], [_head, {"body", [], [{"option", [], [select]}]}]}] = nodes

      assert {"select", [],
              [
                {"button", [], [{"selectedcontent", [], []}]},
                {"option", [], ["A"]}
              ]} = select

      assert error_count == 0
    end

    test "a fragment parse mirrors the selected option into selectedcontent" do
      # Arrange
      html =
        "<select><button><selectedcontent></selectedcontent></button><option>A</option></select>"

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html, context: "body")

      # Assert
      assert [
               {"select", [],
                [
                  {"button", [], [{"selectedcontent", [], ["A"]}]},
                  {"option", [], ["A"]}
                ]}
             ] = nodes

      assert error_count == 0
    end

    test "a select size with a leading non-ASCII space has display size 1" do
      # Arrange
      html = """
      <!DOCTYPE html><select size="\u00A05"><button><selectedcontent></selectedcontent>\
      </button><option>A</option></select>\
      """

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert: the rules for parsing non-negative integers skip only ASCII
      # whitespace, so parsing fails, the display size is 1, and the first
      # option is selected.
      assert [_doctype, {"html", [], [_head, {"body", [], [select]}]}] = nodes

      assert {"select", [{"size", "\u00A05"}],
              [
                {"button", [], [{"selectedcontent", [], ["A"]}]},
                {"option", [], ["A"]}
              ]} = select

      assert error_count == 0
    end

    test "a selectedcontent in template contents is not a descendant of the select" do
      # Arrange
      html = """
      <!DOCTYPE html><select><button><template><selectedcontent></selectedcontent>\
      </template></button><option>A</option></select>\
      """

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert: the template's children are its contents, a separate
      # fragment, so the selectedcontent has no select ancestor.
      assert [_doctype, {"html", [], [_head, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"button", [], [{"template", [], [{:content, [{"selectedcontent", [], []}]}]}]},
                {"option", [], ["A"]}
              ]} = select

      assert error_count == 0
    end

    test "an option in template contents is not in the select's list of options" do
      # Arrange
      html = """
      <!DOCTYPE html><select><button><selectedcontent></selectedcontent></button>\
      <template><option>T</option></template><option>A</option></select>\
      """

      # Act
      {nodes, error_count} = PureHTML.parse_with_errors(html)

      # Assert: with display size 1 and nothing selected, the first option in
      # the list is A; T sits in a separate fragment.
      assert [_doctype, {"html", [], [_head, {"body", [], [select]}]}] = nodes

      assert {"select", [],
              [
                {"button", [], [{"selectedcontent", [], ["A"]}]},
                {"template", [], [{:content, [{"option", [], ["T"]}]}]},
                {"option", [], ["A"]}
              ]} = select

      assert error_count == 0
    end

    test "an SVG select fragment context does not ignore a select start tag" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<div><select>", context: "svg select")

      # Assert: "the parser's fragment context element is a select element"
      # means an HTML select. Errors: div breaks out of foreign content; div
      # and select are open at EOF.
      assert [{"div", [], [{"select", [], []}]}] = nodes
      assert error_count == 2
    end

    test "an SVG select fragment context does not ignore an input start tag" do
      # Arrange / Act
      {nodes, error_count} = PureHTML.parse_with_errors("<div><input>", context: "svg select")

      # Assert: errors: div breaks out of foreign content; div is open at EOF.
      assert [{"div", [], [{"input", [], []}]}] = nodes
      assert error_count == 2
    end

    test "raises ArgumentError for a non-boolean :scripting" do
      assert_raise ArgumentError, ~r/scripting/, fn ->
        PureHTML.parse_with_errors("x", scripting: :yes)
      end
    end
  end

  describe "parse_with_errors/2 on arbitrary input" do
    property "never crashes and always serializes on arbitrary bytes" do
      check all(html <- binary(max_length: 1000)) do
        {nodes, error_count} = PureHTML.parse_with_errors(html)
        assert_parsed(nodes, error_count)
      end
    end

    property "is deterministic" do
      check all(html <- binary(max_length: 500)) do
        {nodes, error_count} = PureHTML.parse_with_errors(html)
        assert_parsed(nodes, error_count)
        assert {nodes, error_count} == PureHTML.parse_with_errors(html)
      end
    end

    property "handles unicode strings" do
      check all(text <- string(:utf8, max_length: 500)) do
        html = "<div>#{text}</div>"
        {nodes, error_count} = PureHTML.parse_with_errors(html)
        assert_parsed(nodes, error_count)
      end
    end

    property "returns a list of valid nodes" do
      check all(html <- html_fragment()) do
        {nodes, error_count} = PureHTML.parse_with_errors(html)
        assert_parsed(nodes, error_count)
      end
    end

    @markup_templates [
      "~<p>",
      "<p ~>",
      "<p a=~>",
      "<p a=\"~\">",
      "<!--~-->",
      "<!DOCTYPE ~>",
      "&#~;",
      "<svg>~</svg>",
      "<table>~</table>",
      "<textarea>~",
      "<script>~",
      "<?~>",
      "<~>",
      "</~>",
      "<p ~=1>",
      "<!~",
      "<title>~",
      "<?a ~?>"
    ]

    property "never crashes on arbitrary code points in markup positions" do
      check all(
              cp <- one_of([integer(0..0xD7FF), integer(0xE000..0x10FFFF)]),
              template <- member_of(@markup_templates)
            ) do
        html = String.replace(template, "~", <<cp::utf8>>)
        {nodes, error_count} = PureHTML.parse_with_errors(html)
        assert_parsed(nodes, error_count)
      end
    end
  end

  describe "parse_with_errors/2 fragment context setup" do
    test "an HTML context name is ASCII lowercased, as createElement does" do
      # Arrange
      html = "a</textarea>b"

      # Act
      result = PureHTML.parse_with_errors(html, context: "TEXTAREA")

      # Assert
      assert result == {["a</textarea>b"], 0}
    end

    test "a custom element name is a valid HTML context" do
      assert PureHTML.parse_with_errors("<p>x", context: "my-el") == {[{"p", [], ["x"]}], 0}
    end

    test "a name that starts with an underscore or a non-ASCII code point is a valid context" do
      assert PureHTML.parse_with_errors("<p>x", context: "_x") == {[{"p", [], ["x"]}], 0}
      assert PureHTML.parse_with_errors("<p>x", context: "éx") == {[{"p", [], ["x"]}], 0}
    end

    # "Set the state of the HTML parser's tokenization stage as follows,
    # switching on the context element": no start tag has been emitted, so the
    # context's own end tag is not an appropriate end tag and stays text.
    for tag <- ~w(title textarea style xmp iframe noembed noframes script noscript plaintext) do
      test "a #{tag} context starts the tokenizer in its text state" do
        tag = unquote(tag)

        assert PureHTML.parse_with_errors("a</#{tag}>b", context: tag) ==
                 {["a</#{tag}>b"], 0}
      end
    end

    test "a noscript context with scripting off starts the tokenizer in the data state" do
      assert PureHTML.parse_with_errors("<b>a</noscript>b", context: "noscript", scripting: false) ==
               {[{"b", [], ["ab"]}], 2}
    end

    # "Set the parser's form element pointer to the nearest node to the context
    # element that is a form element": a nested form is ignored, and </form>
    # clears the pointer with a parse error, since the context is not in scope.
    test "a form context sets the form element pointer" do
      assert PureHTML.parse_with_errors("<form></form><form>", context: "form") ==
               {[{"form", [], []}], 3}
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

    test "returns [] for an invalid selector" do
      html = PureHTML.parse("<p>x</p>")

      assert PureHTML.query(html, "div >") == []
    end
  end

  describe "query!/2" do
    test "raises ArgumentError on an invalid selector" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, fn -> PureHTML.query!(html, "div >") end
    end

    test "raises ArgumentError on a selector that is not valid UTF-8" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, fn -> PureHTML.query!(html, <<0xFF>>) end
    end

    # The errors quote what they name the way Elixir's inspect/1 does.
    test "the error quotes the delimiter an identifier was expected after" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, ~s(invalid selector: expected an identifier after "."), fn ->
        PureHTML.query!(html, ".")
      end
    end

    test "the error names an unexpected quoted value as a string" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, ~s(invalid selector: unexpected string "a"), fn ->
        PureHTML.query!(html, ~s(p"a"))
      end
    end
  end

  # The selector tests below call query!/2, which tells a valid selector that
  # matches nothing from an invalid one; query/2 returns [] for both.

  # HTML "Case-sensitivity of selectors": a type selector and the name part
  # of an attribute selector are ASCII lowercased before they are compared to
  # an HTML element and its attributes, and keep their case for other elements.
  describe "query!/2 case sensitivity" do
    test "an uppercase type selector matches an HTML element" do
      html = PureHTML.parse("<div>x</div>")

      assert PureHTML.query!(html, "DIV") == [{"div", [], ["x"]}]
    end

    # ASCII lowercase changes only A to Z, as the tokenizer did to the tag.
    test "a type selector is ASCII lowercased" do
      html = PureHTML.parse("<D\u0130V>x</D\u0130V>")

      assert PureHTML.query!(html, "D\u0130V") == [{"d\u0130v", [], ["x"]}]
    end

    test "an uppercase attribute name matches an attribute of an HTML element" do
      html = PureHTML.parse("<a href=x>y</a>")

      assert PureHTML.query!(html, "[HREF]") == [{"a", [{"href", "x"}], ["y"]}]
    end

    test "a type selector keeps its case for a foreign element" do
      html = PureHTML.parse("<svg><foreignObject></foreignObject></svg>")

      assert [{{:svg, "foreignObject"}, [], []}] = PureHTML.query!(html, "foreignObject")
      assert PureHTML.query!(html, "foreignobject") == []
    end

    test "an attribute name keeps its case for a foreign element" do
      html = PureHTML.parse("<svg viewBox='0 0 1 1'></svg>")

      assert [{{:svg, "svg"}, _, []}] = PureHTML.query!(html, "[viewBox]")
      assert PureHTML.query!(html, "[viewbox]") == []
    end

    # "Attribute selectors on an HTML element in an HTML document must treat
    # the values of attributes with the following names as ASCII
    # case-insensitive", type and lang among them.
    test "the value of a listed attribute matches ASCII case-insensitively" do
      html = PureHTML.parse("<input type=TEXT>")

      assert PureHTML.query!(html, "[type=text]") == [{"input", [{"type", "TEXT"}], []}]
      assert PureHTML.query!(html, "[TYPE=text]") == [{"input", [{"type", "TEXT"}], []}]
    end

    test "an uppercase selector value matches a listed attribute" do
      html = PureHTML.parse("<input type=text>")

      assert PureHTML.query!(html, "[type=TEXT]") == [{"input", [{"type", "text"}], []}]
    end

    # The rule covers every attribute selector, not only =.
    test "the value of a listed attribute matches ASCII case-insensitively after ^=" do
      html = PureHTML.parse("<input type=TEXT>")

      assert PureHTML.query!(html, "[type^=te]") == [{"input", [{"type", "TEXT"}], []}]
    end

    test "the value of a listed attribute folds only ASCII letters" do
      html = PureHTML.parse("<p lang=GRÜN>x</p>")

      assert PureHTML.query!(html, "[lang=grün]") == []
    end

    test "the value of a listed attribute stays case-sensitive on a foreign element" do
      html = PureHTML.parse("<svg type=TEXT></svg>")

      assert PureHTML.query!(html, "[type=text]") == []
    end

    # One selector meets both kinds of element in one walk.
    test "a listed attribute folds its case on the HTML element of a mixed document only" do
      html = PureHTML.parse("<p lang=EN>x</p><svg lang=EN></svg>")

      assert PureHTML.query!(html, "[lang=en]") == [{"p", [{"lang", "EN"}], ["x"]}]
    end

    test "the value of an unlisted attribute stays case-sensitive" do
      html = PureHTML.parse("<p title=A>x</p>")

      assert PureHTML.query!(html, "[title=a]") == []
    end

    # "this does not apply for attribute selectors with "id" or "class" as
    # the name part"
    for name <- ~w(id class) do
      test "the value of the #{name} attribute stays case-sensitive" do
        name = unquote(name)
        html = PureHTML.parse("<p #{name}=A>x</p>")

        assert PureHTML.query!(html, "[#{name}=a]") == []
      end
    end
  end

  describe "query!/2 attribute selectors" do
    # Selectors 4, substring matching attribute selectors: "If "val" is the
    # empty string then the selector does not represent anything."
    for operator <- ~w(^= $= *=) do
      test "an empty value after #{operator} matches nothing" do
        operator = unquote(operator)
        html = PureHTML.parse("<a href=x>y</a>")

        assert PureHTML.query!(html, ~s([href#{operator}""])) == []
      end
    end

    # [att=val] has no such rule.
    test "an empty value after = matches an empty attribute" do
      html = PureHTML.parse(~s(<a href="">y</a>))

      assert PureHTML.query!(html, ~s([href=""])) == [{"a", [{"href", ""}], ["y"]}]
    end

    # "Attribute values must be <ident-token>s or <string-token>s", and each
    # of these unquoted values tokenizes as something else.
    # The error says to quote the value.
    for selector <- ~w([href$=.pdf] [data-n=1] [href^=http://] [href=a/b] [href=a|b]) do
      test "raises ArgumentError on the unquoted value in #{selector}" do
        selector = unquote(selector)
        html = PureHTML.parse("<p>x</p>")

        assert_raise ArgumentError, ~r/quote/, fn -> PureHTML.query!(html, selector) end
      end
    end

    # CSS Syntax 3: consume a string token returns the string at EOF, and
    # consume a simple block returns the block at EOF.
    test "a quoted value open at the end of the selector ends there" do
      html = PureHTML.parse("<p title=a>x</p>")

      assert PureHTML.query!(html, ~s([title="a)) == [{"p", [{"title", "a"}], ["x"]}]
    end

    for selector <- ~w([title [title=a) do
      test "the attribute selector #{selector} open at the end of the selector is closed there" do
        selector = unquote(selector)
        html = PureHTML.parse("<p title=a>x</p>")

        assert PureHTML.query!(html, selector) == [{"p", [{"title", "a"}], ["x"]}]
      end
    end

    # Consume a string token: a backslash before EOF does nothing.
    test "a backslash at the end of an open quoted value is dropped" do
      html = PureHTML.parse("<p title=a>x</p>")

      assert PureHTML.query!(html, ~s([title="a\\)) == [{"p", [{"title", "a"}], ["x"]}]
    end

    test "raises ArgumentError on an attribute selector that ends after its operator" do
      html = PureHTML.parse("<p title=a>x</p>")

      assert_raise ArgumentError, fn -> PureHTML.query!(html, "[title=") end
    end

    # A <wq-name> has no colon; a namespace prefix is written with "|". The
    # error says to escape the colon.
    test "raises ArgumentError on a colon in an attribute name" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, ~r/escape it/, fn -> PureHTML.query!(html, "[x-on:click]") end
    end

    # An HTML element keeps a colon in an attribute name as part of the name.
    test "an escaped colon matches an HTML attribute whose name holds a colon" do
      html = PureHTML.parse("<div x-on:click=go>x</div>")

      assert PureHTML.query!(html, ~S([x-on\:click])) == [{"div", [{"x-on:click", "go"}], ["x"]}]
    end

    # "Attribute selectors without a namespace component apply only to
    # attributes that have no namespace."
    test "an attribute name without a namespace skips a namespaced attribute" do
      html = PureHTML.parse("<svg><a xlink:href=x></a></svg>")

      assert PureHTML.query!(html, "[href]") == []
    end
  end

  describe "query!/2 ID and class selectors" do
    # An ID selector "represents an element instance that has an identifier
    # that matches the identifier in the ID selector", and an element has one.
    test "two different ID selectors match nothing" do
      html = PureHTML.parse("<p id=b>x</p>")

      assert PureHTML.query!(html, "#a#b") == []
      assert PureHTML.query!(html, "#b#a") == []
    end

    test "the same ID selector twice matches its element" do
      html = PureHTML.parse("<p id=b>x</p>")

      assert PureHTML.query!(html, "#b#b") == [{"p", [{"id", "b"}], ["x"]}]
    end

    # IDs and classes keep their case in a no-quirks document. The tree does
    # not record the mode, so they are always compared exactly; the doctype
    # keeps these inputs no-quirks either way.
    test "an ID selector is case-sensitive" do
      html = PureHTML.parse("<!DOCTYPE html><p id=a>x</p>")

      assert PureHTML.query!(html, "#A") == []
    end

    test "a class selector is case-sensitive" do
      html = PureHTML.parse("<!DOCTYPE html><p class=a>x</p>")

      assert PureHTML.query!(html, ".A") == []
    end

    # Selectors 4 compares IDs and classes ASCII case-insensitively in a
    # quirks-mode document, and a document with no doctype is one. The tree
    # does not record the mode, so they are compared exactly here too; ADR 1
    # records the departure.
    test "ID and class selectors stay case-sensitive in a quirks-mode document" do
      html = PureHTML.parse("<p id=a class=a>x</p>")

      assert PureHTML.query!(html, "#A") == []
      assert PureHTML.query!(html, ".A") == []
    end

    # "In <id-selector>, the <hash-token>'s value must be an identifier", and
    # a <class-selector> is '.' <ident-token>, as a type selector is an
    # <ident-token>. An identifier never starts with a digit, nor with a
    # hyphen and a digit. The error says to escape the digit.
    for selector <- ~w(#1foo .1foo #-1foo .-1foo 1foo) do
      test "the error for #{selector} says to escape the digit" do
        selector = unquote(selector)
        html = PureHTML.parse("<p>x</p>")

        assert_raise ArgumentError, ~r/escape the digit/, fn ->
          PureHTML.query!(html, selector)
        end
      end
    end

    test "a class selector may start with one or two hyphens" do
      html = PureHTML.parse(~s(<p class="--a -a">x</p>))

      assert PureHTML.query!(html, ".--a.-a") == [{"p", [{"class", "--a -a"}], ["x"]}]
    end

    # A class selector is [class~=identifier], and the class attribute is a
    # set of space-separated tokens, split on ASCII whitespace.
    for {name, char} <- [{"U+0085", "\u0085"}, {"U+3000", "\u3000"}] do
      test "a class value is not split on #{name}" do
        char = unquote(char)
        html = PureHTML.parse("<p class=\"a#{char}b\">x</p>")

        assert PureHTML.query!(html, ".a") == []
      end
    end

    for {name, char} <- [{"a tab", "\t"}, {"a line feed", "\n"}, {"a form feed", "\f"}] do
      test "a class value is split on #{name}" do
        char = unquote(char)
        html = PureHTML.parse("<p class=\"a#{char}b\">x</p>")

        assert PureHTML.query!(html, ".b") == [{"p", [{"class", "a#{char}b"}], ["x"]}]
      end
    end
  end

  describe "query!/2 escapes" do
    # CSS Syntax 3, consume an escaped code point: one to six hex digits are a
    # code point, and one whitespace after them is consumed.
    test "a hex escape in a string is the code point it names" do
      html = PureHTML.parse("<p title=A>x</p><p title=41>y</p>")

      assert PureHTML.query!(html, ~S([title="\41"])) == [{"p", [{"title", "A"}], ["x"]}]
    end

    test "a hex escape consumes one whitespace after its digits" do
      html = PureHTML.parse("<p title=AB>x</p>")

      assert PureHTML.query!(html, ~S([title="\41 B"])) == [{"p", [{"title", "AB"}], ["x"]}]
    end

    test "a hex escape consumes only one whitespace" do
      html = PureHTML.parse(~s(<p title="A B">x</p>))

      assert PureHTML.query!(html, ~S([title="\41  B"])) == [{"p", [{"title", "A B"}], ["x"]}]
    end

    test "a hex escape takes at most six digits" do
      html = PureHTML.parse("<p title=A42>x</p>")

      assert PureHTML.query!(html, ~S([title="\00004142"])) == [{"p", [{"title", "A42"}], ["x"]}]
    end

    # "If this number is zero, or is for a surrogate, or is greater than the
    # maximum allowed code point, return U+FFFD REPLACEMENT CHARACTER."
    for escape <- [~S(\0), ~S(\D800), ~S(\110000)] do
      test "the escape #{escape} is U+FFFD" do
        escape = unquote(escape)
        html = PureHTML.parse("<p title=\uFFFD>x</p>")

        assert PureHTML.query!(html, ~s([title="#{escape}"])) ==
                 [{"p", [{"title", "\uFFFD"}], ["x"]}]
      end
    end

    # Any other escaped code point is itself, so \n is the letter n.
    test "an escaped letter that is not a hex digit is the letter" do
      html = PureHTML.parse("<p title=n>x</p>")

      assert PureHTML.query!(html, ~S([title="\n"])) == [{"p", [{"title", "n"}], ["x"]}]
    end

    # Consume a string token: a backslash before a newline consumes the newline.
    test "a backslash before a newline in a string continues the line" do
      html = PureHTML.parse("<p title=ab>x</p>")

      assert PureHTML.query!(html, "[title=\"a\\\nb\"]") == [{"p", [{"title", "ab"}], ["x"]}]
      assert PureHTML.query!(html, "[title=\"a\\\r\nb\"]") == [{"p", [{"title", "ab"}], ["x"]}]
    end

    # Consume a string token: an unescaped newline is a <bad-string-token>.
    # Preprocessing has turned CR and FF into newlines.
    for {name, char} <- [{"line feed", "\n"}, {"carriage return", "\r"}, {"form feed", "\f"}] do
      test "raises ArgumentError on an unescaped #{name} in a string" do
        char = unquote(char)
        html = PureHTML.parse("<p>x</p>")

        assert_raise ArgumentError, fn -> PureHTML.query!(html, "[title=\"a#{char}b\"]") end
      end
    end

    test "an escape in a class selector is part of the identifier" do
      html = PureHTML.parse("<p class=md:flex>x</p>")

      assert PureHTML.query!(html, ~S(.md\:flex)) == [{"p", [{"class", "md:flex"}], ["x"]}]
    end

    # An escaped asterisk is an identifier, so this is a type selector for an
    # element named *, not the universal selector.
    test "an escaped asterisk is a type selector" do
      html = PureHTML.parse("<div><p>x</p></div>")

      assert PureHTML.query!(html, ~S(\*)) == []
    end

    # Consume an escaped code point: "EOF: Return U+FFFD".
    test "a backslash at the end of an identifier is U+FFFD" do
      html = PureHTML.parse("<p class=a\u{FFFD}>x</p>")

      assert PureHTML.query!(html, ".a\\") == [{"p", [{"class", "a\u{FFFD}"}], ["x"]}]
    end
  end

  describe "query!/2 identifiers" do
    # CSS Syntax 3 lists ranges of non-ASCII ident code points, which leave
    # out each of these. Blink, WebKit, and rust-cssparser take any code point
    # from U+0080 up; ADR 1 records why PureHTML follows them.
    for {name, char} <- [
          {"U+0080", "\u0080"},
          {"U+00A0", "\u00A0"},
          {"U+200B", "\u200B"},
          {"U+FFFF", "\uFFFF"},
          {"U+10FFFF", "\u{10FFFF}"}
        ] do
      test "#{name} is part of an identifier" do
        char = unquote(char)
        html = PureHTML.parse("<p class=\"a#{char}b\">x</p>")

        assert PureHTML.query!(html, ".a#{char}b") == [{"p", [{"class", "a#{char}b"}], ["x"]}]
      end
    end

    test "a non-ASCII code point starts an identifier" do
      html = PureHTML.parse("<p id=\u00A0>x</p>")

      assert PureHTML.query!(html, "#\u00A0") == [{"p", [{"id", "\u00A0"}], ["x"]}]
    end

    # Preprocessing replaces U+0000 with U+FFFD, an ident code point.
    test "a NUL in an identifier is U+FFFD" do
      html = PureHTML.parse("<p id=\uFFFD>x</p>")

      assert PureHTML.query!(html, "#\0") == [{"p", [{"id", "\uFFFD"}], ["x"]}]
    end

    # Regional indicators pair into graphemes by position, so reversing the
    # graphemes of U, S, F reorders its code points to S, F, U.
    test "an identifier of regional indicator symbols keeps its order" do
      # Arrange
      class = "\u{1F1FA}\u{1F1F8}\u{1F1EB}"
      html = PureHTML.parse("<p class=#{class}>x</p>")

      # Act
      result = PureHTML.query!(html, "." <> class)

      # Assert
      assert result == [{"p", [{"class", class}], ["x"]}]
    end

    # Consume a token: a hyphen followed by "->" is a <CDC-token>, which no
    # selector holds, before it can start an identifier.
    test "raises ArgumentError on -->" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, fn -> PureHTML.query!(html, "--> p") end
    end

    # A "." is a <delim-token>, so the next token starts at "-->", a
    # <CDC-token>.
    test "raises ArgumentError on --> after a period" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, ~r/-->/, fn -> PureHTML.query!(html, ".-->b") end
    end

    # A "#" takes every ident code point after it, so this ID is "--".
    test "an ID selector may be two hyphens before >" do
      html = PureHTML.parse("<div id=--><b>x</b></div>")

      assert PureHTML.query!(html, "#-->b") == [{"b", [], ["x"]}]
    end

    # Inside an identifier the hyphens are ident code points, so x-- ends
    # before the >.
    test "an identifier may end in two hyphens before >" do
      html = PureHTML.parse("<x--><p>y</p></x-->")

      assert PureHTML.query!(html, "x-->p") == [{"p", [], ["y"]}]
    end
  end

  # CSS Syntax 3, consume comments: each token starts by consuming any
  # comments, and a comment is not whitespace.
  describe "query!/2 comments" do
    test "a comment between whitespace is skipped" do
      html = PureHTML.parse("<div><p>x</p></div>")

      assert PureHTML.query!(html, "div /* c */ p") == [{"p", [], ["x"]}]
    end

    test "a comment between two compound selectors is not a combinator" do
      html = PureHTML.parse("<div><p>x</p></div>")

      assert_raise ArgumentError, ~r/unexpected "p"/, fn -> PureHTML.query!(html, "div/**/p") end
    end

    test "a comment open at the end of the selector runs to the end" do
      html = PureHTML.parse("<div>x</div>")

      assert PureHTML.query!(html, "div /* c") == [{"div", [], ["x"]}]
    end

    test "a comment inside an attribute selector is skipped" do
      html = PureHTML.parse("<a href=x>y</a>")

      assert PureHTML.query!(html, "[href/* c */=x]") == [{"a", [{"href", "x"}], ["y"]}]
    end
  end

  # Selectors 4 defines the syntax of each, and "UAs must treat as invalid
  # any pseudo-classes, pseudo-elements, combinators, or other syntactic
  # constructs for which they have no usable level of support". Each error
  # names the feature, so it reads apart from a malformed selector. :before,
  # :after, :first-line, and :first-letter are pseudo-elements, never
  # pseudo-classes, in any case; :before( is a functional pseudo-class.
  describe "query!/2 unsupported selectors" do
    for {selector, feature} <- [
          {"p:first-child", "pseudo-classes are not supported"},
          {"p:before(x)", "pseudo-classes are not supported"},
          {"p::before", "pseudo-elements are not supported"},
          {"p:before", "pseudo-elements are not supported"},
          {"p:BEFORE", "pseudo-elements are not supported"},
          {~S(p:\62 efore), "pseudo-elements are not supported"},
          {"p:after", "pseudo-elements are not supported"},
          {"p:first-line", "pseudo-elements are not supported"},
          {"p:first-letter", "pseudo-elements are not supported"},
          {"p||td", "the column combinator is not supported"},
          {"[class~=a]", "the ~= operator is not supported"},
          {"[lang|=en]", "the |= operator is not supported"},
          {"[type=text i]", "attribute selector flags are not supported"},
          {"[type=text S]", "attribute selector flags are not supported"},
          {~s([type="text"i]), "attribute selector flags are not supported"},
          {"*|a", "the *| and | namespace forms are not supported"},
          {"*|*", "the *| and | namespace forms are not supported"},
          {"|a", "the *| and | namespace forms are not supported"},
          {"[*|href]", "the *| and | namespace forms are not supported"},
          {"[|href]", "the *| and | namespace forms are not supported"},
          {"[ |href]", "the *| and | namespace forms are not supported"},
          {"[lang |= en]", "the |= operator is not supported"}
        ] do
      test "the error for #{selector} names the feature" do
        selector = unquote(selector)
        feature = unquote(feature)
        html = PureHTML.parse("<p>x</p>")

        error = assert_raise ArgumentError, fn -> PureHTML.query!(html, selector) end

        assert error.message =~ feature
      end
    end

    # Each of these is malformed, whatever PureHTML supports: a flag needs a
    # value before it, and a pseudo-class an identifier or a function right
    # after the colon. A namespace prefix starts a compound selector or an
    # attribute name and needs a name after its "|", and "white space is
    # forbidden" between the components of a <wq-name>.
    for selector <- [
          "[a==i]",
          "[a=]i]",
          "p:",
          "p:1",
          "p: hover",
          "::",
          ".x|a",
          "#x|a",
          "[a]|b",
          "div|",
          "*|",
          "[*|=x]",
          "[|=x]",
          "[a |b]",
          "[a| b]"
        ] do
      test "the error for #{selector} names no unsupported feature" do
        selector = unquote(selector)
        html = PureHTML.parse("<p>x</p>")

        error = assert_raise ArgumentError, fn -> PureHTML.query!(html, selector) end

        refute error.message =~ ~r/not supported|undeclared/
      end
    end

    # Outside an attribute selector, ~ is the subsequent-sibling combinator.
    test "~ without whitespace is a combinator" do
      html = PureHTML.parse("<h1></h1><p>x</p>")

      assert PureHTML.query!(html, "h1~p") == [{"p", [], ["x"]}]
    end
  end

  # "A simple selector containing an undeclared namespace prefix is
  # invalid", and a query declares no prefixes.
  describe "query!/2 namespace prefixes" do
    for selector <- ~w(svg|a [xlink|href]) do
      test "raises ArgumentError on the undeclared prefix in #{selector}" do
        selector = unquote(selector)
        html = PureHTML.parse("<p>x</p>")

        assert_raise ArgumentError, ~r/undeclared namespace prefix/, fn ->
          PureHTML.query!(html, selector)
        end
      end
    end
  end

  describe "query!/2 descendant combinators" do
    # The query runs in a task it bounds itself, because mix test --trace
    # turns the ExUnit test timeout off. The p before the divs gives the
    # leftmost compound a match in the document.
    test "a failing descendant chain over a deep tree stays fast" do
      # Arrange
      html = PureHTML.parse("<p></p>" <> String.duplicate("<div>", 60))
      selector = "p" <> String.duplicate(" div", 8)

      # Act
      task = Task.async(fn -> PureHTML.query!(html, selector) end)
      result = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)

      # Assert
      assert result == {:ok, []}
    end

    # The nearest span is not a child of the div; the next one up is.
    test "a descendant combinator after a child combinator tries every ancestor" do
      # Arrange
      html = PureHTML.parse("<div><span><span><span>x</span></span></span></div>")

      # Act
      result = PureHTML.query!(html, "div > span span")

      # Assert
      assert result == [{"span", [], [{"span", [], ["x"]}]}, {"span", [], ["x"]}]
    end

    # A + that finds no sibling fails only for the ancestor it started from;
    # the descendant combinator to its right still tries a higher one.
    test "a descendant combinator after a sibling combinator tries every ancestor" do
      # Arrange
      html = PureHTML.parse("<h1></h1><div><div><p>x</p></div></div>")

      # Act
      result = PureHTML.query!(html, "h1 + div p")

      # Assert
      assert result == [{"p", [], ["x"]}]
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

    test "returns nil for an invalid selector" do
      html = PureHTML.parse("<p>x</p>")

      assert PureHTML.query_one(html, "div >") == nil
    end
  end

  describe "query_one!/2" do
    test "raises ArgumentError on an invalid selector" do
      html = PureHTML.parse("<p>x</p>")

      assert_raise ArgumentError, fn -> PureHTML.query_one!(html, "div >") end
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
    test "serializes a single node, such as a query_one/2 result" do
      # Arrange
      node =
        "<p>x</p>"
        |> PureHTML.parse()
        |> PureHTML.query_one("p")

      # Act
      result = PureHTML.to_html(node)

      # Assert
      assert result == "<p>x</p>"
    end

    test "serializes an element with text" do
      assert PureHTML.to_html([{"p", [], ["Hello"]}]) == "<p>Hello</p>"
    end

    test "serializes nested elements" do
      nodes = [{"div", [], [{"p", [], ["text"]}]}]
      assert PureHTML.to_html(nodes) == "<div><p>text</p></div>"
    end

    test "serializes an empty element with its end tag" do
      assert PureHTML.to_html([{"div", [], []}]) == "<div></div>"
    end

    test "serializes multiple children" do
      nodes = [{"div", [], ["a", {"span", [], ["b"]}, "c"]}]
      assert PureHTML.to_html(nodes) == "<div>a<span>b</span>c</div>"
    end

    test "serializes a processing instruction as target, a space, and data" do
      assert PureHTML.to_html([{:pi, "php", "echo 1; "}]) == "<?php echo 1; ?>"
    end

    test "keeps a processing instruction's space when its data is empty" do
      assert PureHTML.to_html([{:pi, "php", ""}]) == "<?php ?>"
    end

    test "serializes a comment" do
      assert PureHTML.to_html([{:comment, " hello "}]) == "<!-- hello -->"
    end

    test "serializes a comment inside an element" do
      nodes = [{"div", [], [{:comment, "x"}]}]
      assert PureHTML.to_html(nodes) == "<div><!--x--></div>"
    end

    test "a leading LF in a pre text node is emitted" do
      assert PureHTML.to_html([{"pre", [], ["\nx"]}]) == "<pre>\nx</pre>"
    end

    test "an interior tab in pre text is emitted" do
      assert PureHTML.to_html([{"pre", [], ["foo\tbar"]}]) == "<pre>foo\tbar</pre>"
    end

    test "serializes template contents without the content wrapper" do
      nodes = [{"template", [], [{:content, [{"div", [], ["inside"]}]}]}]
      assert PureHTML.to_html(nodes) == "<template><div>inside</div></template>"
    end
  end

  describe "to_html/2 void elements" do
    test "br has no closing tag" do
      assert PureHTML.to_html([{"br", [], []}]) == "<br>"
    end

    test "img has no closing tag" do
      assert PureHTML.to_html([{"img", [{"src", "a.png"}], []}]) == "<img src=\"a.png\">"
    end

    test "hr has no closing tag" do
      assert PureHTML.to_html([{"hr", [], []}]) == "<hr>"
    end

    test "input has no closing tag" do
      assert PureHTML.to_html([{"input", [{"type", "text"}], []}]) == "<input type=\"text\">"
    end

    test "meta has no closing tag" do
      assert PureHTML.to_html([{"meta", [{"charset", "utf-8"}], []}]) ==
               "<meta charset=\"utf-8\">"
    end

    test "frame is void and drops children" do
      assert PureHTML.to_html([{"frame", [], [{"p", [], ["x"]}]}]) == "<frame>"
    end

    test "SVG link is not void" do
      nodes = [{{:svg, "link"}, [], ["x"]}]
      assert PureHTML.to_html(nodes) == "<link>x</link>"
    end
  end

  describe "to_html/2 attributes" do
    test "always double-quotes attribute values" do
      assert PureHTML.to_html([{"span", [{"title", "foo"}], []}]) == "<span title=\"foo\"></span>"
    end

    test "double-quotes an attribute value with a space" do
      assert PureHTML.to_html([{"span", [{"title", "foo bar"}], []}]) ==
               "<span title=\"foo bar\"></span>"
    end

    test "double-quotes an attribute value with a single quote" do
      assert PureHTML.to_html([{"span", [{"title", "foo'bar"}], []}]) ==
               "<span title=\"foo'bar\"></span>"
    end

    test "escapes double quotes in attribute values" do
      assert PureHTML.to_html([{"span", [{"title", "foo\"bar"}], []}]) ==
               "<span title=\"foo&quot;bar\"></span>"
    end

    test "escapes double quotes when the value also has a single quote" do
      assert PureHTML.to_html([{"span", [{"title", "foo'bar\"baz"}], []}]) ==
               "<span title=\"foo'bar&quot;baz\"></span>"
    end

    test "escapes ampersand in attribute values" do
      assert PureHTML.to_html([{"span", [{"title", "a&b"}], []}]) ==
               "<span title=\"a&amp;b\"></span>"
    end

    test "escapes ampersand among other characters" do
      assert PureHTML.to_html([{"span", [{"title", "a & b"}], []}]) ==
               "<span title=\"a &amp; b\"></span>"
    end

    test "escapes angle brackets in attribute values" do
      assert PureHTML.to_html([{"span", [{"title", "foo<bar"}], []}]) ==
               "<span title=\"foo&lt;bar\"></span>"
    end

    test "attribute mode escapes greater-than" do
      assert PureHTML.to_html([{"span", [{"title", "a>b"}], []}]) ==
               "<span title=\"a&gt;b\"></span>"
    end

    test "empty attribute value is quoted empty" do
      assert PureHTML.to_html([{"button", [{"disabled", ""}], []}]) ==
               "<button disabled=\"\"></button>"
    end

    test "double-quotes an attribute value with an equals sign" do
      assert PureHTML.to_html([{"span", [{"title", "a=b"}], []}]) == "<span title=\"a=b\"></span>"
    end

    test "tab in an attribute is emitted inside quotes" do
      assert PureHTML.to_html([{"span", [{"title", "foo\tbar"}], []}]) ==
               "<span title=\"foo\tbar\"></span>"
    end

    test "LF in an attribute is emitted inside quotes" do
      assert PureHTML.to_html([{"span", [{"title", "foo\nbar"}], []}]) ==
               "<span title=\"foo\nbar\"></span>"
    end

    test "CR in an attribute is emitted inside quotes" do
      assert PureHTML.to_html([{"span", [{"title", "foo\rbar"}], []}]) ==
               "<span title=\"foo\rbar\"></span>"
    end

    test "form feed in an attribute is emitted inside quotes" do
      assert PureHTML.to_html([{"span", [{"title", "foo\fbar"}], []}]) ==
               "<span title=\"foo\fbar\"></span>"
    end

    test "vertical tab in an attribute is emitted inside quotes" do
      assert PureHTML.to_html([{"span", [{"title", "foo\vbar"}], []}]) ==
               "<span title=\"foo\vbar\"></span>"
    end

    test "NBSP in an attribute is escaped as &nbsp;" do
      assert PureHTML.to_html([{"span", [{"title", "\u00A0"}], []}]) ==
               "<span title=\"&nbsp;\"></span>"
    end

    test "serializes multiple attributes in order" do
      assert PureHTML.to_html([{"p", [{"title", "t"}, {"class", "c"}], []}]) ==
               ~s(<p title="t" class="c"></p>)
    end
  end

  describe "to_html/2 text escaping" do
    test "escapes less-than in text" do
      assert PureHTML.to_html([{"p", [], ["a<b"]}]) == "<p>a&lt;b</p>"
    end

    test "escapes greater-than in text" do
      assert PureHTML.to_html([{"p", [], ["a>b"]}]) == "<p>a&gt;b</p>"
    end

    test "escapes ampersand in text" do
      assert PureHTML.to_html([{"p", [], ["a&b"]}]) == "<p>a&amp;b</p>"
    end

    test "escapes every special character in text" do
      assert PureHTML.to_html([{"p", [], ["<script>alert('xss')</script>"]}]) ==
               "<p>&lt;script&gt;alert('xss')&lt;/script&gt;</p>"
    end

    test "NBSP in text is escaped as &nbsp;" do
      assert PureHTML.to_html(["\u00A0"]) == "&nbsp;"
    end
  end

  describe "to_html/2 raw text" do
    test "script content is not escaped" do
      assert PureHTML.to_html([{"script", [], ["a<b>c&d"]}]) == "<script>a<b>c&d</script>"
    end

    test "style content is not escaped" do
      assert PureHTML.to_html([{"style", [], ["a<b{color:red}"]}]) ==
               "<style>a<b{color:red}</style>"
    end

    test "noscript text is not escaped when scripting is on" do
      nodes = [{"noscript", [], ["<p>x</p>"]}]
      assert PureHTML.to_html(nodes) == "<noscript><p>x</p></noscript>"
    end

    test "noscript text is escaped when scripting is off" do
      nodes = [{"noscript", [], ["<p>x</p>"]}]

      assert PureHTML.to_html(nodes, scripting: false) ==
               "<noscript>&lt;p&gt;x&lt;/p&gt;</noscript>"
    end

    for tag <- ~w(xmp iframe noembed noframes plaintext) do
      test "#{tag} text is not escaped" do
        tag = unquote(tag)
        assert PureHTML.to_html([{tag, [], ["a<b>&c"]}]) == "<#{tag}>a<b>&c</#{tag}>"
      end
    end

    test "SVG script text is escaped" do
      nodes = [{{:svg, "script"}, [], ["a<b>c&d"]}]
      assert PureHTML.to_html(nodes) == "<script>a&lt;b&gt;c&amp;d</script>"
    end

    test "with the default :scripting, a scripting-off parse's noscript text reparses as markup" do
      # Arrange
      nodes =
        PureHTML.parse("<body><noscript>&lt;img src=x onerror=alert(1)&gt;</noscript>",
          scripting: false
        )

      # Act
      reparsed =
        nodes
        |> PureHTML.to_html()
        |> PureHTML.parse(scripting: false)

      # Assert
      assert [{"img", [{"src", "x"}, {"onerror", "alert(1)"}], []}] =
               PureHTML.query(reparsed, "img")
    end

    test "with the parse's scripting: false, noscript text round-trips as text" do
      # Arrange
      nodes =
        PureHTML.parse("<body><noscript>&lt;img src=x onerror=alert(1)&gt;</noscript>",
          scripting: false
        )

      # Act
      reparsed =
        nodes
        |> PureHTML.to_html(scripting: false)
        |> PureHTML.parse(scripting: false)

      # Assert
      assert reparsed == nodes
    end
  end

  describe "to_html/2 doctypes" do
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

    test "serializes the html doctype" do
      assert PureHTML.to_html([{:doctype, "html", nil, nil}]) == "<!DOCTYPE html>"
    end

    test "doctype with public identifier serializes the name only" do
      nodes = [{:doctype, "HTML", "-//W3C//DTD HTML 4.01//EN", nil}]
      assert PureHTML.to_html(nodes) == "<!DOCTYPE HTML>"
    end

    test "doctype with system identifier serializes the name only" do
      nodes = [{:doctype, "html", "", "http://example.com/dtd"}]
      assert PureHTML.to_html(nodes) == "<!DOCTYPE html>"
    end

    test "doctype with both identifiers serializes the name only" do
      nodes = [
        {:doctype, "HTML", "-//W3C//DTD HTML 4.01//EN", "http://www.w3.org/TR/html4/strict.dtd"}
      ]

      assert PureHTML.to_html(nodes) == "<!DOCTYPE HTML>"
    end

    test "doctype with a missing name keeps the space before the empty name" do
      assert PureHTML.to_html([{:doctype, nil, nil, nil}]) == "<!DOCTYPE >"
    end
  end

  describe "to_html/2 foreign content" do
    test "serializes xlink:href on an SVG element" do
      # Arrange
      html = "<svg><a xlink:href=foo></a></svg>"

      # Act
      result =
        html
        |> PureHTML.parse()
        |> PureHTML.to_html()

      # Assert
      assert result =~ "xlink:href=\"foo\""
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

    test "serializes an SVG element" do
      nodes = [{{:svg, "circle"}, [{"r", "5"}], []}]
      assert PureHTML.to_html(nodes) == "<circle r=\"5\"></circle>"
    end

    test "serializes a MathML element" do
      nodes = [{{:math, "mrow"}, [], []}]
      assert PureHTML.to_html(nodes) == "<mrow></mrow>"
    end

    test "serializes xmlns attributes with and without a prefix" do
      nodes = [{{:svg, "svg"}, [{{:xmlns, "xmlns"}, "s"}, {{:xmlns, "xlink"}, "x"}], []}]
      assert PureHTML.to_html(nodes) == "<svg xmlns=\"s\" xmlns:xlink=\"x\"></svg>"
    end

    test "serializes namespaced attribute tuples" do
      nodes = [{{:svg, "a"}, [{{:xlink, "href"}, "foo"}], []}]
      assert PureHTML.to_html(nodes) == "<a xlink:href=\"foo\"></a>"
    end

    test "serializes an xml-prefixed attribute" do
      nodes = [{{:svg, "text"}, [{{:xml, "lang"}, "en"}], []}]
      assert PureHTML.to_html(nodes) == "<text xml:lang=\"en\"></text>"
    end
  end

  describe "to_html/2 round trips" do
    test "simple HTML round-trips through parse/2" do
      html = "<p>Hello</p>"
      result = html |> PureHTML.parse() |> PureHTML.to_html()
      # Parser adds html/head/body structure
      assert result == "<html><head></head><body><p>Hello</p></body></html>"
    end

    test "a full document round-trips through parse/2" do
      html = "<!DOCTYPE html><html><head></head><body><p>Hi</p></body></html>"
      result = html |> PureHTML.parse() |> PureHTML.to_html()
      assert result == "<!DOCTYPE html><html><head></head><body><p>Hi</p></body></html>"
    end

    test "escaped text, quoted attributes, foreign content, and template contents reparse to the same tree" do
      # Arrange
      nodes =
        PureHTML.parse("""
        <!DOCTYPE html><title>a &amp; b</title><p title='say "hi" &amp; <go>'>1 &lt; 2&nbsp;3</p>\
        <svg viewBox="0 0 1 1"><a xlink:href="#x"><title>t</title></a></svg>\
        <template><td>cell</td></template><script>if (a < b && c) {}</script>
        """)

      # Act
      reparsed =
        nodes
        |> PureHTML.to_html()
        |> PureHTML.parse()

      # Assert
      assert reparsed == nodes
    end
  end

  describe "to_html/2 invalid input" do
    test "raises ArgumentError naming nil, a query_one/2 miss" do
      assert_raise ArgumentError, ~r/nil/, fn -> PureHTML.to_html(nil) end
    end

    test "raises ArgumentError naming an element whose children are not a list" do
      assert_raise ArgumentError, ~r/"text"/, fn -> PureHTML.to_html([{"p", [], "text"}]) end
    end

    test "raises ArgumentError naming an element whose attributes are a map" do
      assert_raise ArgumentError, ~r/%\{/, fn ->
        PureHTML.to_html([{"p", %{"class" => "a"}, []}])
      end
    end

    test "raises ArgumentError naming an attribute whose value is not a string" do
      assert_raise ArgumentError, ~r/"class"/, fn ->
        PureHTML.to_html([{"p", [{"class", nil}], []}])
      end
    end

    test "raises ArgumentError naming a doctype whose identifiers are not strings" do
      assert_raise ArgumentError, ~r/:doctype/, fn ->
        PureHTML.to_html({:doctype, "html", 1, :x})
      end
    end

    test "raises ArgumentError for an unknown option" do
      assert_raise ArgumentError, ~r/scriptng/, fn -> PureHTML.to_html([], scriptng: false) end
    end

    test "raises ArgumentError for a non-boolean :scripting" do
      assert_raise ArgumentError, ~r/scripting/, fn -> PureHTML.to_html([], scripting: "no") end
    end
  end

  defp assert_parsed(nodes, error_count) do
    assert is_list(nodes)
    assert is_integer(error_count) and error_count >= 0
    assert Enum.all?(nodes, &valid_node?/1)
    html = PureHTML.to_html(nodes)
    assert is_binary(html) and String.valid?(html)
    text = PureHTML.text(nodes)
    assert is_binary(text) and String.valid?(text)
  end

  defp valid_node?({tag, attrs, children}) when is_binary(tag) do
    valid_attrs?(attrs) and is_list(children) and Enum.all?(children, &valid_node?/1)
  end

  defp valid_node?({{ns, tag}, attrs, children})
       when ns in [:svg, :math] and is_binary(tag) do
    valid_attrs?(attrs) and is_list(children) and Enum.all?(children, &valid_node?/1)
  end

  defp valid_node?({:content, children}) when is_list(children) do
    Enum.all?(children, &valid_node?/1)
  end

  defp valid_node?(text) when is_binary(text), do: true
  defp valid_node?({:comment, text}) when is_binary(text), do: true
  defp valid_node?({:pi, target, data}) when is_binary(target) and is_binary(data), do: true

  defp valid_node?({:doctype, name, public, system})
       when (is_binary(name) or is_nil(name)) and (is_binary(public) or is_nil(public)) and
              (is_binary(system) or is_nil(system)),
       do: true

  defp valid_node?(_), do: false

  defp valid_attrs?(attrs) when is_list(attrs), do: Enum.all?(attrs, &valid_attr?/1)
  defp valid_attrs?(_), do: false

  defp valid_attr?({name, value}) when is_binary(value), do: valid_attr_name?(name)
  defp valid_attr?(_), do: false

  defp valid_attr_name?(name) when is_binary(name), do: true

  defp valid_attr_name?({ns, local}) when ns in [:xlink, :xml, :xmlns] and is_binary(local),
    do: true

  defp valid_attr_name?(_), do: false

  defp html_fragment do
    gen all(parts <- list_of(html_part(), max_length: 10)) do
      Enum.join(parts)
    end
  end

  defp html_part do
    one_of([
      string(:alphanumeric, max_length: 20),
      string(:utf8, max_length: 8),
      gen_tag(),
      constant(" "),
      constant("\n"),
      constant(<<0>>),
      constant("\u00A0"),
      constant("&#x0;"),
      constant("<![CDATA[x]]>"),
      constant("<?php x?>"),
      constant("<svg></svg>"),
      constant("<math></math>"),
      constant("<template><p>x</p></template>")
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
