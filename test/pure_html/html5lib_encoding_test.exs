defmodule PureHTML.Html5libEncodingTest do
  use ExUnit.Case, async: true

  alias PureHTML.Encoding
  alias PureHTML.Test.Html5libEncodingTests, as: H5

  for path <- H5.list_test_files(), not H5.needs_script_execution?(path) do
    name = H5.fixture_name(path)

    describe name do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        @tag :html5lib
        @tag :encoding
        @tag test_file: name
        @tag test_num: index
        @tag test_id: "#{name}:#{index}"
        test "##{index}: expects #{test.encoding}" do
          test = unquote(Macro.escape(test))

          actual = Encoding.sniff(test.data)

          assert String.downcase(actual) == test.encoding,
                 """
                 Expected encoding: #{test.encoding}
                 Got: #{actual}
                 Data (first 100 bytes): #{inspect(String.slice(test.data, 0, 100))}
                 """
        end
      end
    end
  end

  # Fixtures whose <meta charset> is written by a script (see
  # H5.needs_script_execution?/1). One skipped test each keeps them in the
  # result line instead of inside a green count.
  for path <- H5.list_test_files(), H5.needs_script_execution?(path) do
    name = H5.fixture_name(path)

    describe name do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        @tag :html5lib
        @tag :encoding
        @tag test_file: name
        @tag test_num: index
        @tag test_id: "#{name}:#{index}"
        @tag skip: "the meta charset is written by a script; the sniffer has no script engine"
        test "##{index}: expects #{test.encoding}" do
          flunk("the meta charset is written by a script; the sniffer has no script engine")
        end
      end
    end
  end
end
