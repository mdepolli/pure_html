alias PureHTML.{Tokenizer, TreeBuilder}

html = File.read!("test/fixtures/wikipedia_homepage.html")
file_size = byte_size(html)

IO.puts("File size: #{Float.round(file_size / 1024, 1)} KB\n")

# Tokenizer benchmark
{time_us, tokens} =
  :timer.tc(fn ->
    html |> Tokenizer.tokenize() |> Enum.to_list()
  end)

time_ms = time_us / 1000
throughput_mb_s = file_size / 1024 / 1024 / (time_us / 1_000_000)

IO.puts("""
Tokenizer:
  Tokens: #{length(tokens)}
  Time: #{Float.round(time_ms, 1)} ms
  Throughput: #{Float.round(throughput_mb_s, 2)} MB/s
""")

# Full parse benchmark
{time_us, tree} =
  :timer.tc(fn ->
    html |> Tokenizer.new() |> TreeBuilder.build()
  end)

time_ms = time_us / 1000
throughput_mb_s = file_size / 1024 / 1024 / (time_us / 1_000_000)

count_nodes = fn count_nodes, nodes ->
  case nodes do
    nodes when is_list(nodes) ->
      Enum.reduce(nodes, 0, fn node, acc -> acc + count_nodes.(count_nodes, node) end)

    {_tag, _attrs, children} ->
      1 + count_nodes.(count_nodes, children)

    {:comment, _} ->
      1

    _text ->
      1
  end
end

nodes = count_nodes.(count_nodes, tree)

IO.puts("""
Full parse (tokenizer + tree builder):
  Nodes: #{nodes}
  Time: #{Float.round(time_ms, 1)} ms
  Throughput: #{Float.round(throughput_mb_s, 2)} MB/s
""")
