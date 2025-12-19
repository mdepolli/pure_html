defmodule PureHtml.Html5libTreeConstructionTest do
  use ExUnit.Case, async: true

  alias PureHtml.Test.Html5libTreeConstructionTests, as: H5
  alias PureHtml.{Tokenizer, TreeBuilder}

  for path <- H5.list_test_files() do
    filename = Path.basename(path, ".dat")

    describe filename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        # Skip fragment tests for now
        if test.document_fragment == nil do
          @tag :html5lib
          @tag :tree_construction
          @tag test_file: filename
          test "##{index}: #{String.slice(test.data, 0, 40)}" do
            test = unquote(Macro.escape(test))

            document =
              test.data
              |> Tokenizer.tokenize()
              |> TreeBuilder.build()

            actual = H5.serialize_document(document) |> String.trim_trailing("\n")
            expected = test.document |> String.trim_trailing("\n")

            assert actual == expected
          end
        end
      end
    end
  end
end
