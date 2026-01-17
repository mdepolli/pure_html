defmodule PureHTML.TreeBuilder.Modes.InCell do
  @moduledoc """
  HTML5 "in cell" insertion mode.

  This mode handles content inside a <td> or <th> element.

  Per HTML5 spec:
  - Character tokens: process using "in body" rules
  - Comments: process using "in body" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - caption, col, colgroup, tbody, td, tfoot, th, thead, tr: close cell, reprocess
    - Anything else: process using "in body" rules
  - End tags:
    - td, th: close cell, switch to "in row"
    - body, caption, col, colgroup, html: parse error, ignore
    - table, tbody, tfoot, thead, tr: close cell if in scope, reprocess
    - Anything else: process using "in body" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incell
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers,
    only: [in_scope?: 3, pop_until_tag: 2, clear_af_to_marker: 1]

  alias PureHTML.TreeBuilder.Modes.InBody

  # Start tags that close the cell
  @cell_closing_start_tags ~w(caption col colgroup tbody td tfoot th thead tr)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html)

  # End tags that close the cell if in scope
  @cell_closing_end_tags ~w(table tbody tfoot thead tr)

  @impl true
  # Character tokens: process using in_body rules
  def process({:character, _} = token, state) do
    InBody.process(token, state)
  end

  # Comments: process using in_body rules
  def process({:comment, _} = token, state) do
    InBody.process(token, state)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Cell-closing start tags: close cell, reprocess
  # But first check if we're in foreign content - if so, delegate to in_body
  def process({:start_tag, tag, _, _} = token, state) when tag in @cell_closing_start_tags do
    if in_foreign_content?(state) do
      # In foreign content, let in_body handle it (may push as foreign element)
      InBody.process(token, state)
    else
      case close_cell(state) do
        {:ok, new_state} ->
          {:reprocess, new_state}

        :not_found ->
          # Cell not in scope, ignore
          {:ok, state}
      end
    end
  end

  # Other start tags: process using in_body rules
  def process({:start_tag, _, _, _} = token, state) do
    InBody.process(token, state)
  end

  # End tag: td or th - close cell, switch to in_row
  def process({:end_tag, tag}, state) when tag in ["td", "th"] do
    case close_cell_for_tag(state, tag) do
      {:ok, new_state} ->
        {:ok, %{new_state | mode: :in_row}}

      :not_found ->
        {:ok, state}
    end
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    {:ok, state}
  end

  # Cell-closing end tags: close cell if TARGET tag is in table scope, reprocess
  def process({:end_tag, tag}, state) when tag in @cell_closing_end_tags do
    # Per spec: only close cell if the end tag's target is in table scope
    if in_scope?(state, tag, :table) do
      case close_cell(state) do
        {:ok, new_state} ->
          {:reprocess, new_state}

        :not_found ->
          {:ok, state}
      end
    else
      # Target not in scope, ignore
      {:ok, state}
    end
  end

  # Other end tags: process using in_body rules
  def process({:end_tag, _} = token, state) do
    InBody.process(token, state)
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Close td or th cell if in table scope
  @cell_tags ~w(td th)

  defp close_cell(state) do
    case Enum.find(@cell_tags, &in_scope?(state, &1, :table)) do
      nil -> :not_found
      tag -> close_cell_for_tag(state, tag)
    end
  end

  # Close specific cell tag if in table scope
  defp close_cell_for_tag(state, tag) do
    with true <- in_scope?(state, tag, :table),
         {:ok, new_state} <- pop_until_tag(state, tag) do
      {:ok, clear_af_to_marker(%{new_state | mode: :in_row})}
    else
      _ -> :not_found
    end
  end

  # Check if the current node is in a foreign namespace (SVG/MathML)
  defp in_foreign_content?(%{stack: [ref | _], elements: elements}) do
    case elements[ref].tag do
      {ns, _} when ns in [:svg, :math] -> true
      _ -> false
    end
  end

  defp in_foreign_content?(%{stack: []}), do: false
end
