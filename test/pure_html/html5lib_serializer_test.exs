defmodule PureHTML.Html5libSerializerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Serializer
  alias PureHTML.Test.Html5libSerializerTests, as: H5

  # Cases that test html5lib's token serializer rather than the fragment
  # serialization algorithm (see H5.skip_reason/2) get one skipped test each,
  # so they stay in the result line instead of inside a green count.
  for path <- H5.list_test_files() do
    name = H5.fixture_name(path)

    describe name do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        description = test["description"] || "test #{index}"

        case H5.skip_reason(name, test) do
          nil ->
            @tag :html5lib
            @tag :serializer
            @tag test_file: name
            @tag test_id: "#{name}:#{index}"
            test "##{index}: #{description}" do
              test = unquote(Macro.escape(test))
              {:ok, nodes} = H5.build_tree(test["input"])

              actual = Serializer.serialize(nodes)

              assert actual in test["expected"],
                     """
                     Expected one of: #{inspect(test["expected"])}
                     Got: #{inspect(actual)}
                     Nodes: #{inspect(nodes)}
                     """
            end

          reason ->
            @tag :html5lib
            @tag :serializer
            @tag test_file: name
            @tag test_id: "#{name}:#{index}"
            @tag skip: reason
            test "##{index}: #{description}" do
              flunk(unquote(reason))
            end
        end
      end
    end
  end
end
