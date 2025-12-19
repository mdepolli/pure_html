defmodule PureHtml.TokenizerTest do
  use ExUnit.Case, async: true

  alias PureHtml.Tokenizer

  describe "basic tokenization" do
    test "simple tag" do
      tokens = Tokenizer.tokenize("<p>Hello</p>") |> Enum.to_list()

      assert {:start_tag, "p", %{}, false} in tokens
      assert {:end_tag, "p"} in tokens
    end

    test "doctype" do
      assert [{:doctype, "html", nil, nil, false}] =
               Tokenizer.tokenize("<!DOCTYPE html>") |> Enum.to_list()
    end

    test "attributes" do
      assert [{:start_tag, "div", %{"class" => "foo", "id" => "bar"}, false}] =
               Tokenizer.tokenize("<div class=\"foo\" id=bar>") |> Enum.to_list()
    end

    test "self-closing tag" do
      assert [{:start_tag, "br", %{}, true}] =
               Tokenizer.tokenize("<br/>") |> Enum.to_list()
    end

    test "comment" do
      assert [{:comment, " hello "}] =
               Tokenizer.tokenize("<!-- hello -->") |> Enum.to_list()
    end
  end

  describe "character handling" do
    test "emits coalesced character tokens" do
      tokens = Tokenizer.tokenize("abc") |> Enum.to_list()

      assert [{:character, "abc"}] = tokens
    end
  end

  describe "tag names" do
    test "lowercases tag names" do
      assert [{:start_tag, "div", %{}, false}] =
               Tokenizer.tokenize("<DIV>") |> Enum.to_list()
    end
  end

  describe "attributes" do
    test "double-quoted attribute value" do
      assert [{:start_tag, "a", %{"href" => "http://example.com"}, false}] =
               Tokenizer.tokenize("<a href=\"http://example.com\">") |> Enum.to_list()
    end

    test "single-quoted attribute value" do
      assert [{:start_tag, "a", %{"href" => "http://example.com"}, false}] =
               Tokenizer.tokenize("<a href='http://example.com'>") |> Enum.to_list()
    end

    test "unquoted attribute value" do
      assert [{:start_tag, "input", %{"type" => "text"}, false}] =
               Tokenizer.tokenize("<input type=text>") |> Enum.to_list()
    end

    test "attribute without value" do
      assert [{:start_tag, "input", %{"disabled" => ""}, false}] =
               Tokenizer.tokenize("<input disabled>") |> Enum.to_list()
    end

    test "multiple attributes" do
      assert [
               {:start_tag, "input", %{"type" => "text", "name" => "foo", "disabled" => ""},
                false}
             ] =
               Tokenizer.tokenize("<input type=text name=foo disabled>") |> Enum.to_list()
    end
  end
end
