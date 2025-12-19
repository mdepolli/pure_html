defmodule PureHtml.BenchmarkTest do
  use ExUnit.Case, async: true

  @moduletag :benchmark

  setup_all do
    html = File.read!("test/fixtures/wikipedia_homepage.html")
    tokens = html |> PureHtml.Tokenizer.tokenize() |> Enum.to_list()
    %{html: html, tokens: tokens}
  end

  test "Tokenizer: Wikipedia homepage", %{html: html} do
    file_size = byte_size(html)

    {time_us, tokens} =
      :timer.tc(fn ->
        html |> PureHtml.Tokenizer.tokenize() |> Enum.to_list()
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

    assert length(tokens) > 0
  end

  test "TreeBuilder: Wikipedia homepage", %{tokens: tokens} do
    {time_us, doc} = :timer.tc(fn -> PureHtml.TreeBuilder.build(tokens) end)
    time_ms = time_us / 1000

    IO.puts("""

      TreeBuilder benchmark:
        Tokens: #{length(tokens)}
        Nodes: #{map_size(doc.nodes)}
        Time: #{Float.round(time_ms, 1)} ms
    """)

    assert doc.root_id != nil
  end
end
