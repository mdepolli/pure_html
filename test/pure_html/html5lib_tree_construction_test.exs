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
          @tag :html5lib
          @tag :tree_construction
          @tag test_file: filename
          @tag test_num: index
          @tag test_id: "#{filename}:#{index}"
          @tag scripting: String.to_atom(label)
          test "##{index} [script-#{label}]: #{String.slice(test.data, 0, 40)}" do
            test = unquote(Macro.escape(test))
            scripting = unquote(scripting)

            document =
              case test.document_fragment do
                nil ->
                  PureHTML.parse(test.data, scripting: scripting)

                context ->
                  PureHTML.parse(test.data, context: context, scripting: scripting)
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
