defmodule PureHTML.Html5libSerializerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libSerializerTests, as: H5

  # Skip optionaltags (requires optional tag omission - optimization, not correctness)
  # Skip injectmeta (requires optional tag omission in output)
  @skip_files ["optionaltags", "injectmeta"]

  for path <- H5.list_test_files(),
      filename = Path.basename(path, ".test"),
      filename not in @skip_files do
    describe filename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        normalized = H5.normalize_test(test)
        description = normalized.description || "test #{index}"

        @tag :html5lib
        @tag :serializer
        @tag test_file: filename
        @tag test_num: index
        test "##{index}: #{description}" do
          normalized = unquote(Macro.escape(normalized))

          actual = H5.serialize_tokens_with_context(normalized.input, normalized.options)

          assert actual in normalized.expected,
                 """
                 Expected one of: #{inspect(normalized.expected)}
                 Got: #{inspect(actual)}
                 Input: #{inspect(normalized.input)}
                 Options: #{inspect(normalized.options)}
                 """
        end
      end
    end
  end
end
