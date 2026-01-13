defmodule PureHTML.Html5libEncodingTest do
  use ExUnit.Case, async: true

  alias PureHTML.Encoding
  alias PureHTML.Test.Html5libEncodingTests, as: H5

  for path <- H5.list_test_files() do
    filename = Path.basename(path, ".dat")

    describe filename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        @tag :html5lib
        @tag :encoding
        @tag test_file: filename
        @tag test_num: index
        @tag test_id: "#{filename}:#{index}"
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
end
