defmodule PureHTML.Html5libTreeConstructionTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTreeConstructionTests, as: H5

  for path <- H5.list_test_files() do
    filename = Path.basename(path, ".dat")

    describe filename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        # Skip script-off tests (we assume scripting enabled)
        if not test.script_off do
          @tag :html5lib
          @tag :tree_construction
          @tag test_file: filename
          @tag test_num: index
          @tag test_id: "#{filename}:#{index}"
          test "##{index}: #{String.slice(test.data, 0, 40)}" do
            test = unquote(Macro.escape(test))

            document =
              case test.document_fragment do
                nil ->
                  PureHTML.parse(test.data)

                context ->
                  PureHTML.parse(test.data, context: context)
              end

            actual = H5.serialize_document(document) |> String.trim_trailing("\n")
            expected = test.document |> String.trim_trailing("\n")

            assert actual == expected
          end
        end
      end
    end
  end
end
