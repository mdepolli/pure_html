defmodule PureHTML.Html5libSerializerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libSerializerTests, as: H5

  # Only run core.test for now - other test files test optional features
  # like tag omission and serializer options that we haven't implemented
  @test_files ["core.test"]

  for filename <- @test_files do
    path = Path.join(H5.test_dir(), filename)
    basename = Path.basename(filename, ".test")

    describe basename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        normalized = H5.normalize_test(test)
        description = normalized.description || "test #{index}"

        # Skip tests that require options we don't support
        if map_size(normalized.options) == 0 or
             Map.keys(normalized.options) == ["encoding"] do
          @tag :html5lib
          @tag :serializer
          @tag test_file: basename
          test "##{index}: #{description}" do
            normalized = unquote(Macro.escape(normalized))

            actual = H5.serialize_tokens_with_context(normalized.input)

            assert actual in normalized.expected,
                   """
                   Expected one of: #{inspect(normalized.expected)}
                   Got: #{inspect(actual)}
                   Input: #{inspect(normalized.input)}
                   """
          end
        end
      end
    end
  end
end
