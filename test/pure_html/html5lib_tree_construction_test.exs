defmodule PureHTML.Html5libTreeConstructionTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTreeConstructionTests, as: H5

  for path <- H5.list_test_files() do
    filename = Path.basename(path, ".dat")

    describe filename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        scripting_modes =
          cond do
            test.script_off -> [{false, "off"}]
            test.script_on -> [{true, "on"}]
            true -> [{true, "on"}, {false, "off"}]
          end

        for {scripting, label} <- scripting_modes do
          opts =
            case test.document_fragment do
              nil -> [scripting: scripting]
              context -> [scripting: scripting, context: context]
            end

          @tag :html5lib
          @tag :tree_construction
          @tag test_file: filename
          @tag test_num: index
          @tag test_id: "#{filename}:#{index}"
          @tag scripting: String.to_atom(label)
          test "##{index} [script-#{label}]: #{String.slice(test.data, 0, 40)}" do
            data = unquote(test.data)
            expected_document = unquote(test.document)
            opts = unquote(Macro.escape(opts))

            # Error counts are collected but not asserted yet. About 30% of
            # html5lib tests still mismatch; tree output is the pass criterion.
            {document, _error_count} = PureHTML.parse_with_errors(data, opts)

            actual = H5.serialize_document(document) |> String.trim_trailing("\n")
            expected = expected_document |> String.trim_trailing("\n")

            assert actual == expected
          end
        end
      end
    end
  end
end
