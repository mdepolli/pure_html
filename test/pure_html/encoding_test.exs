defmodule PureHTML.EncodingTest do
  use ExUnit.Case, async: true

  alias PureHTML.Encoding

  doctest Encoding

  describe "sniff/2 order" do
    test "BOM wins over transport encoding" do
      bytes = <<0xEF, 0xBB, 0xBF, "<html>">>
      assert Encoding.sniff(bytes, transport_encoding: "windows-1252") == "utf-8"
    end

    test "unsupported transport is skipped so a meta charset can win" do
      assert Encoding.sniff("<meta charset=utf-8>", transport_encoding: "utf-7") == "utf-8"
    end

    test "supported transport wins over a later meta charset" do
      assert Encoding.sniff("<meta charset=utf-8>", transport_encoding: "shift_jis") ==
               "shift_jis"
    end

    test "transport utf-16 is not remapped to utf-8" do
      assert Encoding.sniff("x", transport_encoding: "utf-16") == "utf-16le"
    end
  end

  describe "get an encoding" do
    test "shift_jis is a named encoding, not silent windows-1252" do
      assert Encoding.sniff("<meta charset=shift_jis>") == "shift_jis"
    end

    test "bogus meta charset is not a hit so a later meta can win" do
      html = "<meta charset=bogus><meta charset=utf-8>"
      assert Encoding.sniff(html) == "utf-8"
    end

    test "x-user-defined in a meta charset is a hit remapped to windows-1252" do
      html = "<meta charset=x-user-defined><meta charset=utf-8>"
      assert Encoding.sniff(html) == "windows-1252"
    end

    test "meta charset utf-16 is remapped to utf-8" do
      assert Encoding.sniff("<meta charset=utf-16>") == "utf-8"
    end
  end

  describe "prescan a byte stream" do
    test "meta slash is allowed before attributes" do
      assert Encoding.sniff("<meta/ charset=utf-8>") == "utf-8"
    end

    test "unquoted content value keeps slash" do
      html = "<meta http-equiv=content-type content=text/html;charset=iso-8859-2>"
      assert Encoding.sniff(html) == "iso-8859-2"
    end

    test "first duplicate attribute wins" do
      assert Encoding.sniff("<meta charset=iso-8859-2 charset=utf-8>") == "iso-8859-2"
    end

    test "content charset requires an equals sign" do
      html = "<meta http-equiv=content-type content='text/html; charsetutf-8'>"
      assert Encoding.sniff(html) == "windows-1252"
    end

    test "a less-than inside a meta tag is an attribute name, not a rescan" do
      assert Encoding.sniff("<meta <meta charset='euc-jp'>") == "euc-jp"
    end
  end

  describe "get an XML encoding" do
    test "unterminated comment after an XML declaration still yields the XML encoding" do
      html = "<?xml version=\"1.0\" encoding=\"ISO-8859-2\"?><!-- open comment"
      assert Encoding.sniff(html) == "iso-8859-2"
    end

    test "XML encoding utf-16 is remapped to utf-8" do
      html = "<?xml encoding=\"utf-16\"?><!--"
      assert Encoding.sniff(html) == "utf-8"
    end

    test "the encoding is read from the declaration only, not from later markup" do
      html = "<?xml version=\"1.0\"?><meta encoding=\"iso-8859-2\"><!-- open comment"
      assert Encoding.sniff(html) == "windows-1252"
    end

    test "an XML declaration that is not at the start of the stream is not a hit" do
      html = "<!-- unterminated <?xml encoding=\"iso-8859-2\"?>"
      assert Encoding.sniff(html) == "windows-1252"
    end
  end
end
