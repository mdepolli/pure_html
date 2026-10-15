defmodule PureHTML.Query.Selector.AttributeSelectorTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query.Selector.AttributeSelector

  # HTML, case-sensitivity of selectors: the name part is ASCII lowercased
  # for HTML elements, and the values of the listed attributes compare ASCII
  # case-insensitively on them.
  describe "new/3" do
    test "keeps the name as written and its ASCII lowercase" do
      assert %AttributeSelector{name: "D\u0130R", html_name: "d\u0130r"} =
               AttributeSelector.new("D\u0130R", :exists, nil)
    end

    test "lowercases the value of a listed attribute" do
      assert %AttributeSelector{value: "RTL", html_value: "rtl", case_insensitive: true} =
               AttributeSelector.new("DIR", :equal, "RTL")
    end

    test "keeps the value of an unlisted attribute" do
      assert %AttributeSelector{value: "A", html_value: "A", case_insensitive: false} =
               AttributeSelector.new("title", :equal, "A")
    end

    test "has no value for an existence selector" do
      assert %AttributeSelector{value: nil, html_value: nil, match_type: :exists} =
               AttributeSelector.new("type", :exists, nil)
    end
  end

  describe "match_html?/2" do
    test "folds the element's value of a listed attribute" do
      selector = AttributeSelector.new("TYPE", :equal, "TEXT")

      assert AttributeSelector.match_html?("Text", selector)
      refute AttributeSelector.match_html?("password", selector)
    end

    test "keeps the element's value of an unlisted attribute" do
      selector = AttributeSelector.new("TITLE", :equal, "a")

      assert AttributeSelector.match_html?("a", selector)
      refute AttributeSelector.match_html?("A", selector)
    end

    test "matches no missing attribute" do
      for match_type <- [:equal, :prefix, :suffix, :substring] do
        refute AttributeSelector.match_html?(nil, AttributeSelector.new("type", match_type, "a"))
      end

      refute AttributeSelector.match_html?(nil, AttributeSelector.new("type", :exists, nil))
    end

    # Selectors 4: a substring matching attribute selector whose value is the
    # empty string "does not represent anything".
    for name <- ~w(type title), match_type <- [:prefix, :suffix, :substring] do
      test "an empty #{match_type} value on #{name} matches nothing" do
        selector = AttributeSelector.new(unquote(name), unquote(match_type), "")

        refute AttributeSelector.match_html?("", selector)
        refute AttributeSelector.match_html?("a", selector)
      end
    end
  end

  describe "match_foreign?/2" do
    test "compares the value as written, even for a listed attribute" do
      selector = AttributeSelector.new("type", :equal, "TEXT")

      assert AttributeSelector.match_foreign?("TEXT", selector)
      refute AttributeSelector.match_foreign?("text", selector)
    end

    for match_type <- [:prefix, :suffix, :substring] do
      test "an empty #{match_type} value matches nothing" do
        selector = AttributeSelector.new("type", unquote(match_type), "")

        refute AttributeSelector.match_foreign?("a", selector)
      end
    end
  end
end
