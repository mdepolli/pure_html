defmodule PureHTML.Html5libSerializerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libSerializerTests, as: H5

  # One running test per file that has fragment-algorithm evidence; the cases
  # loop at run time. Cases that test html5lib's token serializer rather than
  # the fragment algorithm (see H5.skip_reason/1) get one skipped test per
  # file, with counts, so they stay in the result line instead of inside a
  # green count.
  for path <- H5.list_test_files() do
    name = H5.fixture_name(path)
    {running, skip_counts} = H5.classify(path)

    if running != [] do
      @tag :html5lib
      @tag :serializer
      @tag test_file: name
      test name do
        failures = H5.failures(unquote(path))

        assert failures == [],
               "#{length(failures)} failing case(s):\n\n" <> Enum.join(failures, "\n")
      end
    end

    if skip_counts != [] do
      summary = H5.skip_summary(skip_counts)

      @tag :html5lib
      @tag :serializer
      @tag test_file: name
      @tag skip: summary
      test "#{name} (not fragment-algorithm evidence)" do
        flunk(unquote(summary))
      end
    end
  end
end
