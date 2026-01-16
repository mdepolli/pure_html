defmodule PureHTML.TreeBuilder.Modes.InCaption do
  @moduledoc """
  HTML5 "in caption" insertion mode.

  This mode handles content inside a <caption> element within a table.

  Per HTML5 spec:
  - Character tokens: process using "in body" rules
  - Comments: process using "in body" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - caption, col, colgroup, tbody, td, tfoot, th, thead, tr: close caption, reprocess
    - Anything else: process using "in body" rules
  - End tags:
    - caption: close caption, switch to "in table"
    - table: parse error, close caption, reprocess
    - body, col, colgroup, html, tbody, td, tfoot, th, thead, tr: parse error, ignore
    - Anything else: process using "in body" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-incaption
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers, only: [in_scope?: 3, pop_until_tag: 2]

  alias PureHTML.TreeBuilder.Modes.InBody

  # Table-related start tags that close the caption
  @table_tags ~w(caption col colgroup tbody td tfoot th thead tr)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body col colgroup html tbody td tfoot th thead tr)

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

  # Table-related start tags: close caption, reprocess
  def process({:start_tag, tag, _, _}, state) when tag in @table_tags do
    case close_caption(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        # Caption not in scope, ignore
        {:ok, state}
    end
  end

  # Other start tags: process using in_body rules
  def process({:start_tag, _, _, _} = token, state) do
    InBody.process(token, state)
  end

  # End tag: caption
  def process({:end_tag, "caption"}, state) do
    case close_caption(state) do
      {:ok, new_state} ->
        {:ok, %{new_state | mode: :in_table}}

      :not_found ->
        {:ok, state}
    end
  end

  # End tag: table - close caption, reprocess
  def process({:end_tag, "table"}, state) do
    case close_caption(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        {:ok, state}
    end
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    {:ok, state}
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

  # Close caption if in table scope
  defp close_caption(state) do
    with true <- in_scope?(state, "caption", :table),
         {:ok, new_state} <- pop_until_tag(state, "caption") do
      {:ok, %{new_state | mode: :in_table}}
    else
      _ -> :not_found
    end
  end
end
