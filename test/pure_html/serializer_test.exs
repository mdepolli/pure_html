defmodule PureHTML.SerializerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Serializer

  doctest Serializer

  describe "basic element serialization" do
    test "simple element with text" do
      assert Serializer.serialize([{"p", [], ["Hello"]}]) == "<p>Hello</p>"
    end

    test "nested elements" do
      nodes = [{"div", [], [{"p", [], ["text"]}]}]
      assert Serializer.serialize(nodes) == "<div><p>text</p></div>"
    end

    test "empty element" do
      assert Serializer.serialize([{"div", [], []}]) == "<div></div>"
    end

    test "multiple children" do
      nodes = [{"div", [], ["a", {"span", [], ["b"]}, "c"]}]
      assert Serializer.serialize(nodes) == "<div>a<span>b</span>c</div>"
    end
  end

  describe "void elements" do
    test "br has no closing tag" do
      assert Serializer.serialize([{"br", [], []}]) == "<br>"
    end

    test "img has no closing tag" do
      assert Serializer.serialize([{"img", [{"src", "a.png"}], []}]) == "<img src=\"a.png\">"
    end

    test "hr has no closing tag" do
      assert Serializer.serialize([{"hr", [], []}]) == "<hr>"
    end

    test "input has no closing tag" do
      assert Serializer.serialize([{"input", [{"type", "text"}], []}]) ==
               "<input type=\"text\">"
    end

    test "meta has no closing tag" do
      assert Serializer.serialize([{"meta", [{"charset", "utf-8"}], []}]) ==
               "<meta charset=\"utf-8\">"
    end

    test "frame is void and drops children" do
      assert Serializer.serialize([{"frame", [], [{"p", [], ["x"]}]}]) == "<frame>"
    end

    test "SVG link is not void" do
      nodes = [{{:svg, "link"}, [], ["x"]}]
      assert Serializer.serialize(nodes) == "<link>x</link>"
    end
  end

  describe "attribute serialization" do
    test "always double-quotes attribute values" do
      assert Serializer.serialize([{"span", [{"title", "foo"}], []}]) ==
               "<span title=\"foo\"></span>"
    end

    test "double quoted with space" do
      assert Serializer.serialize([{"span", [{"title", "foo bar"}], []}]) ==
               "<span title=\"foo bar\"></span>"
    end

    test "double quoted with single quote" do
      assert Serializer.serialize([{"span", [{"title", "foo'bar"}], []}]) ==
               "<span title=\"foo'bar\"></span>"
    end

    test "escapes double quotes in attribute values" do
      assert Serializer.serialize([{"span", [{"title", "foo\"bar"}], []}]) ==
               "<span title=\"foo&quot;bar\"></span>"
    end

    test "escapes double quotes when the value also has a single quote" do
      assert Serializer.serialize([{"span", [{"title", "foo'bar\"baz"}], []}]) ==
               "<span title=\"foo'bar&quot;baz\"></span>"
    end

    test "escapes ampersand in attribute values" do
      assert Serializer.serialize([{"span", [{"title", "a&b"}], []}]) ==
               "<span title=\"a&amp;b\"></span>"
    end

    test "escapes ampersand among other characters" do
      assert Serializer.serialize([{"span", [{"title", "a & b"}], []}]) ==
               "<span title=\"a &amp; b\"></span>"
    end

    test "escapes angle brackets in attribute values" do
      assert Serializer.serialize([{"span", [{"title", "foo<bar"}], []}]) ==
               "<span title=\"foo&lt;bar\"></span>"
    end

    test "attribute mode escapes greater-than" do
      assert Serializer.serialize([{"span", [{"title", "a>b"}], []}]) ==
               "<span title=\"a&gt;b\"></span>"
    end

    test "empty attribute value is quoted empty" do
      assert Serializer.serialize([{"button", [{"disabled", ""}], []}]) ==
               "<button disabled=\"\"></button>"
    end

    test "double quoted with equals sign" do
      assert Serializer.serialize([{"span", [{"title", "a=b"}], []}]) ==
               "<span title=\"a=b\"></span>"
    end

    test "NBSP in an attribute is escaped as &nbsp;" do
      assert Serializer.serialize([{"span", [{"title", "\u00A0"}], []}]) ==
               "<span title=\"&nbsp;\"></span>"
    end

    test "multiple attributes" do
      result = Serializer.serialize([{"div", [{"class", "y"}, {"id", "x"}], []}])
      assert result == "<div class=\"y\" id=\"x\"></div>"
    end
  end

  describe "text escaping" do
    test "escapes less than" do
      assert Serializer.serialize([{"p", [], ["a<b"]}]) == "<p>a&lt;b</p>"
    end

    test "escapes greater than" do
      assert Serializer.serialize([{"p", [], ["a>b"]}]) == "<p>a&gt;b</p>"
    end

    test "escapes ampersand" do
      assert Serializer.serialize([{"p", [], ["a&b"]}]) == "<p>a&amp;b</p>"
    end

    test "escapes all special characters" do
      assert Serializer.serialize([{"p", [], ["<script>alert('xss')</script>"]}]) ==
               "<p>&lt;script&gt;alert('xss')&lt;/script&gt;</p>"
    end

    test "NBSP is escaped as &nbsp;" do
      assert Serializer.serialize(["\u00A0"]) == "&nbsp;"
    end
  end

  describe "raw text elements" do
    test "script content is not escaped" do
      assert Serializer.serialize([{"script", [], ["a<b>c&d"]}]) ==
               "<script>a<b>c&d</script>"
    end

    test "style content is not escaped" do
      assert Serializer.serialize([{"style", [], ["a<b{color:red}"]}]) ==
               "<style>a<b{color:red}</style>"
    end

    test "noscript text is not escaped when scripting is on" do
      nodes = [{"noscript", [], ["<p>x</p>"]}]
      assert Serializer.serialize(nodes) == "<noscript><p>x</p></noscript>"
    end

    test "noscript text is escaped when scripting is off" do
      nodes = [{"noscript", [], ["<p>x</p>"]}]

      assert Serializer.serialize(nodes, scripting: false) ==
               "<noscript>&lt;p&gt;x&lt;/p&gt;</noscript>"
    end

    test "SVG script text is escaped" do
      nodes = [{{:svg, "script"}, [], ["a<b>c&d"]}]
      assert Serializer.serialize(nodes) == "<script>a&lt;b&gt;c&amp;d</script>"
    end
  end

  describe "comments" do
    test "basic comment" do
      assert Serializer.serialize([{:comment, " hello "}]) == "<!-- hello -->"
    end

    test "comment inside element" do
      nodes = [{"div", [], [{:comment, "x"}]}]
      assert Serializer.serialize(nodes) == "<div><!--x--></div>"
    end
  end

  describe "DOCTYPE" do
    test "simple html5 doctype" do
      assert Serializer.serialize([{:doctype, "html", nil, nil}]) == "<!DOCTYPE html>"
    end

    test "doctype with public identifier serializes the name only" do
      nodes = [{:doctype, "HTML", "-//W3C//DTD HTML 4.01//EN", nil}]
      assert Serializer.serialize(nodes) == "<!DOCTYPE HTML>"
    end

    test "doctype with system identifier serializes the name only" do
      nodes = [{:doctype, "html", "", "http://example.com/dtd"}]
      assert Serializer.serialize(nodes) == "<!DOCTYPE html>"
    end

    test "doctype with both identifiers serializes the name only" do
      nodes = [
        {:doctype, "HTML", "-//W3C//DTD HTML 4.01//EN", "http://www.w3.org/TR/html4/strict.dtd"}
      ]

      assert Serializer.serialize(nodes) == "<!DOCTYPE HTML>"
    end

    test "doctype with a missing name keeps the space before the empty name" do
      assert Serializer.serialize([{:doctype, nil, nil, nil}]) == "<!DOCTYPE >"
    end
  end

  describe "foreign content" do
    test "svg element" do
      nodes = [{{:svg, "circle"}, [{"r", "5"}], []}]
      assert Serializer.serialize(nodes) == "<circle r=\"5\"></circle>"
    end

    test "mathml element" do
      nodes = [{{:math, "mrow"}, [], []}]
      assert Serializer.serialize(nodes) == "<mrow></mrow>"
    end

    test "serializes xmlns attributes with and without a prefix" do
      nodes = [{{:svg, "svg"}, [{{:xmlns, "xmlns"}, "s"}, {{:xmlns, "xlink"}, "x"}], []}]
      assert Serializer.serialize(nodes) == "<svg xmlns=\"s\" xmlns:xlink=\"x\"></svg>"
    end

    test "serializes namespaced attribute tuples" do
      nodes = [{{:svg, "a"}, [{{:xlink, "href"}, "foo"}], []}]
      assert Serializer.serialize(nodes) == "<a xlink:href=\"foo\"></a>"
    end
  end

  describe "pre" do
    test "a leading LF in a pre text node is emitted" do
      assert Serializer.serialize([{"pre", [], ["\nx"]}]) == "<pre>\nx</pre>"
    end
  end

  describe "template content" do
    test "unwraps content wrapper" do
      nodes = [{"template", [], [{:content, [{"div", [], ["inside"]}]}]}]
      assert Serializer.serialize(nodes) == "<template><div>inside</div></template>"
    end
  end

  describe "round-trip with parser" do
    test "simple html round-trips" do
      html = "<p>Hello</p>"
      result = html |> PureHTML.parse() |> PureHTML.to_html()
      # Parser adds html/head/body structure
      assert result == "<html><head></head><body><p>Hello</p></body></html>"
    end

    test "full document round-trips" do
      html = "<!DOCTYPE html><html><head></head><body><p>Hi</p></body></html>"
      result = html |> PureHTML.parse() |> PureHTML.to_html()
      assert result == "<!DOCTYPE html><html><head></head><body><p>Hi</p></body></html>"
    end
  end
end
