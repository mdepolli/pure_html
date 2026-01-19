defmodule PureHTML.SerializerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Serializer

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
      assert Serializer.serialize([{"img", [{"src", "a.png"}], []}]) == "<img src=a.png>"
    end

    test "hr has no closing tag" do
      assert Serializer.serialize([{"hr", [], []}]) == "<hr>"
    end

    test "input has no closing tag" do
      assert Serializer.serialize([{"input", [{"type", "text"}], []}]) == "<input type=text>"
    end

    test "meta has no closing tag" do
      assert Serializer.serialize([{"meta", [{"charset", "utf-8"}], []}]) ==
               "<meta charset=utf-8>"
    end
  end

  describe "attribute serialization" do
    test "unquoted when safe" do
      assert Serializer.serialize([{"span", [{"title", "foo"}], []}]) ==
               "<span title=foo></span>"
    end

    test "double quoted with space" do
      assert Serializer.serialize([{"span", [{"title", "foo bar"}], []}]) ==
               "<span title=\"foo bar\"></span>"
    end

    test "double quoted with single quote" do
      assert Serializer.serialize([{"span", [{"title", "foo'bar"}], []}]) ==
               "<span title=\"foo'bar\"></span>"
    end

    test "single quoted with double quote" do
      assert Serializer.serialize([{"span", [{"title", "foo\"bar"}], []}]) ==
               "<span title='foo\"bar'></span>"
    end

    test "double quoted with both quotes - escapes double" do
      assert Serializer.serialize([{"span", [{"title", "foo'bar\"baz"}], []}]) ==
               "<span title=\"foo'bar&quot;baz\"></span>"
    end

    test "ampersand in simple value is unquoted" do
      # &b is not a valid entity ref, so unquoted is valid HTML
      assert Serializer.serialize([{"span", [{"title", "a&b"}], []}]) ==
               "<span title=a&b></span>"
    end

    test "escapes ampersand when quoting is required" do
      # Space forces quoting, then & must be escaped
      assert Serializer.serialize([{"span", [{"title", "a & b"}], []}]) ==
               "<span title=\"a &amp; b\"></span>"
    end

    test "empty attribute value renders as bare name" do
      assert Serializer.serialize([{"button", [{"disabled", ""}], []}]) ==
               "<button disabled></button>"
    end

    test "double quoted with equals sign" do
      assert Serializer.serialize([{"span", [{"title", "a=b"}], []}]) ==
               "<span title=\"a=b\"></span>"
    end

    test "double quoted with greater than" do
      assert Serializer.serialize([{"span", [{"title", "a>b"}], []}]) ==
               "<span title=\"a>b\"></span>"
    end

    test "multiple attributes" do
      # Attributes are sorted alphabetically, so order is deterministic
      result = Serializer.serialize([{"div", [{"class", "y"}, {"id", "x"}], []}])
      assert result == "<div class=y id=x></div>"
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

    test "doctype with public identifier" do
      nodes = [{:doctype, "HTML", "-//W3C//DTD HTML 4.01//EN", nil}]
      assert Serializer.serialize(nodes) == "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">"
    end

    test "doctype with system identifier only" do
      nodes = [{:doctype, "html", "", "http://example.com/dtd"}]
      assert Serializer.serialize(nodes) == "<!DOCTYPE html SYSTEM \"http://example.com/dtd\">"
    end

    test "doctype with both identifiers" do
      nodes = [
        {:doctype, "HTML", "-//W3C//DTD HTML 4.01//EN", "http://www.w3.org/TR/html4/strict.dtd"}
      ]

      assert Serializer.serialize(nodes) ==
               "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">"
    end
  end

  describe "foreign content" do
    test "svg element" do
      nodes = [{{:svg, "circle"}, [{"r", "5"}], []}]
      assert Serializer.serialize(nodes) == "<circle r=5></circle>"
    end

    test "mathml element" do
      nodes = [{{:math, "mrow"}, [], []}]
      assert Serializer.serialize(nodes) == "<mrow></mrow>"
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
