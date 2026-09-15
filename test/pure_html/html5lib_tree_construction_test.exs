defmodule PureHTML.Html5libTreeConstructionTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTreeConstructionTests, as: H5

  # One test per fixture file and scripting mode; the cases run in a loop at
  # run time. Generating a test function per case made compiling this file the
  # slowest part of the suite.
  for path <- H5.list_test_files(),
      not H5.needs_script_execution?(path),
      {scripting, label} <- [{true, "on"}, {false, "off"}] do
    name = H5.fixture_name(path)

    @tag :html5lib
    @tag :tree_construction
    @tag test_file: name
    @tag scripting: String.to_atom(label)
    test "#{name} [script-#{label}]" do
      failures = H5.failures(unquote(path), unquote(scripting))

      assert failures == [],
             "#{length(failures)} failing case(s):\n\n" <> Enum.join(failures, "\n")
    end
  end

  # Fixtures that expect the DOM after their scripts ran (see
  # H5.needs_script_execution?/1). One skipped test each keeps them in the
  # result line instead of inside a green count.
  for path <- H5.list_test_files(), H5.needs_script_execution?(path) do
    name = H5.fixture_name(path)

    @tag :html5lib
    @tag :tree_construction
    @tag test_file: name
    @tag skip: "expects the DOM after its scripts ran; the parser has no script engine"
    test name do
      flunk("expects the DOM after its scripts ran; the parser has no script engine")
    end
  end
end
