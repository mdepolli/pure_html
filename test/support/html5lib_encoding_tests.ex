defmodule PureHTML.Test.Html5libEncodingTests do
  @moduledoc """
  Parses html5lib encoding test files (.dat format).

  Each test has:
  - #data: raw HTML bytes to sniff encoding from
  - #encoding: expected encoding name (e.g., "windows-1252", "utf-8")
  """

  @test_dir Path.expand("../html5lib-tests/encoding", __DIR__)

  def test_dir, do: @test_dir

  def list_test_files do
    @test_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".dat"))
    |> Enum.sort()
    |> Enum.map(&Path.join(@test_dir, &1))
  end

  def parse_file(path) do
    path
    |> File.read!()
    |> split_tests()
    |> Enum.map(&parse_test/1)
    |> Enum.reject(&is_nil/1)
  end

  # Split on #data that appears at start of line after a newline
  defp split_tests(content) do
    # First test starts with #data, subsequent tests are separated by \n#data
    case String.split(content, "\n#data\n") do
      ["#data\n" <> first | rest] ->
        [first | rest]

      ["#data" <> first | rest] ->
        [String.trim_leading(first, "\n") | rest]

      _ ->
        []
    end
  end

  defp parse_test(text) do
    case String.split(text, "\n#encoding\n", parts: 2) do
      [data, encoding_and_rest] ->
        # Encoding may have trailing content (comments, next test markers)
        encoding =
          encoding_and_rest
          |> String.split("\n", parts: 2)
          |> List.first()
          |> String.trim()

        %{
          data: data,
          encoding: normalize_expected_encoding(encoding)
        }

      _ ->
        nil
    end
  end

  # Normalize expected encoding names to lowercase for consistent comparison
  defp normalize_expected_encoding(encoding) do
    encoding
    |> String.downcase()
    |> String.trim()
  end
end
