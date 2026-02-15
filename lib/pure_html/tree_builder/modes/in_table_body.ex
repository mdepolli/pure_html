defmodule PureHTML.TreeBuilder.Modes.InTableBody do
  @moduledoc """
  HTML5 "in table body" insertion mode.

  This mode handles content inside tbody, thead, or tfoot elements.

  Per HTML5 spec:
  - Character tokens: process using "in table" rules
  - Comments: process using "in table" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - tr: clear to table body context, insert tr, switch to "in row"
    - th, td: parse error, insert tr, reprocess
    - caption, col, colgroup, tbody, tfoot, thead: close table body, reprocess
    - Anything else: process using "in table" rules
  - End tags:
    - tbody, tfoot, thead: close if in scope, switch to "in table"
    - table: close table body, reprocess
    - body, caption, col, colgroup, html, td, th, tr: parse error, ignore
    - Anything else: process using "in table" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-intbody
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers,
    only: [
      push_element: 3,
      set_mode: 2,
      in_scope?: 3,
      pop_until_tag: 2,
      pop_until_one_of: 2
    ]

  alias PureHTML.TreeBuilder.Modes.InTable

  # Table body elements
  @table_body_tags ~w(tbody tfoot thead)

  # Start tags that close the table body
  @body_closing_start_tags ~w(caption col colgroup tbody tfoot thead)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html td th tr)

  # Table body context tags
  @table_body_context_tags ~w(tbody tfoot thead template html)

  @impl true
  # Character tokens: process using in_table rules (delegation)
  def process({:character, _} = token, state) do
    delegate_to_in_table(token, state)
  end

  # Comments: process using in_table rules (delegation)
  def process({:comment, _} = token, state) do
    delegate_to_in_table(token, state)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Start tag: tr - insert row, switch to in_row
  def process({:start_tag, "tr", attrs, _}, state) do
    state =
      state
      |> clear_to_table_body_context()
      |> push_element("tr", attrs)
      |> set_mode(:in_row)

    {:ok, state}
  end

  # Start tag: th, td - insert implied tr, reprocess
  def process({:start_tag, tag, _, _}, state) when tag in ["th", "td"] do
    state =
      state
      |> clear_to_table_body_context()
      |> push_element("tr", [])
      |> set_mode(:in_row)

    {:reprocess, state}
  end

  # Body-closing start tags: close table body, reprocess
  def process({:start_tag, tag, _, _}, state) when tag in @body_closing_start_tags do
    case close_table_body(state) do
      {:ok, new_state} ->
        {:reprocess, new_state}

      :not_found ->
        {:ok, state}
    end
  end

  # Other start tags: process using in_table rules (delegation, not mode switch).
  # Per WHATWG spec, "process the token using the rules for in_table" is a
  # delegation for one token. The tree construction dispatcher handles foreign
  # content routing for subsequent tokens.
  def process({:start_tag, _, _, _} = token, state) do
    delegate_to_in_table(token, state)
  end

  # End tag: tbody, tfoot, thead - close if in scope
  def process({:end_tag, tag}, state) when tag in @table_body_tags do
    with true <- in_scope?(state, tag, :table),
         {:ok, new_state} <- pop_until_tag(state, tag) do
      {:ok, %{new_state | mode: :in_table}}
    else
      _ -> {:ok, state}
    end
  end

  # End tag: table - close table body, reprocess
  def process({:end_tag, "table"}, state) do
    case close_table_body(state) do
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

  # Other end tags: process using in_table rules (delegation)
  def process({:end_tag, _} = token, state) do
    delegate_to_in_table(token, state)
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Per WHATWG spec: "Process the token using the rules for the 'in table'
  # insertion mode" is a delegation — call InTable for one token. Restore mode
  # to in_table_body only when InTable consumed the token without changing mode.
  # If InTable changed the mode (e.g., to :in_select_in_table, :in_head), or
  # said reprocess, respect that decision.
  defp delegate_to_in_table(token, state) do
    case InTable.process(token, %{state | mode: :in_table}) do
      {:ok, %{mode: :in_table} = new_state} ->
        {:ok, %{new_state | mode: :in_table_body}}

      # InTable switched to in_table_text for character processing.
      # Fix original_mode so in_table_text returns to in_table_body.
      {:reprocess, %{mode: :in_table_text, original_mode: :in_table} = new_state} ->
        {:reprocess, %{new_state | original_mode: :in_table_body}}

      other ->
        other
    end
  end

  # Clear stack to table body context (tbody, tfoot, thead, template, html)
  defp clear_to_table_body_context(state) do
    pop_until_one_of(state, @table_body_context_tags)
  end

  # Close the current table body if in table scope
  defp close_table_body(state) do
    with tag when tag != nil <- Enum.find(@table_body_tags, &in_scope?(state, &1, :table)),
         {:ok, new_state} <- pop_until_tag(state, tag) do
      {:ok, %{new_state | mode: :in_table}}
    else
      _ -> :not_found
    end
  end
end
