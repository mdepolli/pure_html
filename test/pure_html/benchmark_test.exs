defmodule PureHTML.BenchmarkTest do
  use ExUnit.Case, async: true

  @moduletag :benchmark

  setup_all do
    html = File.read!("test/fixtures/wikipedia_homepage.html")
    tokens = html |> PureHTML.Tokenizer.tokenize() |> Enum.to_list()
    %{html: html, tokens: tokens}
  end

  test "Tokenizer: Wikipedia homepage", %{html: html} do
    file_size = byte_size(html)

    {time_us, tokens} =
      :timer.tc(fn ->
        html |> PureHTML.Tokenizer.tokenize() |> Enum.to_list()
      end)

    time_ms = time_us / 1000
    throughput_mb_s = file_size / 1024 / 1024 / (time_us / 1_000_000)

    IO.puts("""

      Tokenizer benchmark:
        File size: #{Float.round(file_size / 1024, 1)} KB
        Tokens: #{length(tokens)}
        Time: #{Float.round(time_ms, 1)} ms
        Throughput: #{Float.round(throughput_mb_s, 2)} MB/s
    """)

    assert tokens != []
  end

  test "TreeBuilder: Wikipedia homepage", %{tokens: tokens} do
    {time_us, {_doctype, tree}} = :timer.tc(fn -> PureHTML.TreeBuilder.build(tokens) end)
    time_ms = time_us / 1000
    nodes = count_nodes(tree)

    IO.puts("""

      TreeBuilder benchmark:
        Tokens: #{length(tokens)}
        Nodes: #{nodes}
        Time: #{Float.round(time_ms, 1)} ms
    """)

    assert tree != nil
  end

  defp count_nodes(nodes) when is_list(nodes) do
    Enum.reduce(nodes, 0, fn node, acc -> acc + count_nodes(node) end)
  end

  defp count_nodes({_tag, _attrs, children}), do: 1 + count_nodes(children)
  defp count_nodes({:comment, _}), do: 1
  defp count_nodes(_text), do: 1
end
