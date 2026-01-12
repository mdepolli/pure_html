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
      in_table_scope?: 2,
      pop_until_tag: 2,
      pop_until_one_of: 2
    ]

  # Table body elements
  @table_body_tags ~w(tbody tfoot thead)

  # Start tags that close the table body
  @body_closing_start_tags ~w(caption col colgroup tbody tfoot thead)

  # End tags that are parse errors and ignored
  @ignored_end_tags ~w(body caption col colgroup html td th tr)

  # Table body context tags
  @table_body_context_tags ~w(tbody tfoot thead template html)

  @impl true
  # Character tokens: process using in_table rules
  def process({:character, _}, state) do
    {:reprocess, %{state | mode: :in_table}}
  end

  # Comments: process using in_table rules
  def process({:comment, _}, state) do
    {:reprocess, %{state | mode: :in_table}}
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
      |> push_element("tr", %{})
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

  # Other start tags: process using in_table rules
  def process({:start_tag, _, _, _}, state) do
    {:reprocess, %{state | mode: :in_table}}
  end

  # End tag: tbody, tfoot, thead - close if in scope
  def process({:end_tag, tag}, state) when tag in @table_body_tags do
    if in_table_scope?(state, tag) do
      case pop_until_tag(state, tag) do
        {:ok, new_state} ->
          {:ok, %{new_state | mode: :in_table}}

        {:not_found, _} ->
          {:ok, state}
      end
    else
      {:ok, state}
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

  # Other end tags: process using in_table rules
  def process({:end_tag, _}, state) do
    {:reprocess, %{state | mode: :in_table}}
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Clear stack to table body context (tbody, tfoot, thead, template, html)
  defp clear_to_table_body_context(state) do
    pop_until_one_of(state, @table_body_context_tags)
  end

  # Close the current table body if in table scope
  defp close_table_body(state) do
    tag_to_close =
      Enum.find(@table_body_tags, fn tag -> in_table_scope?(state, tag) end)

    case tag_to_close do
      nil ->
        :not_found

      tag ->
        case pop_until_tag(state, tag) do
          {:ok, new_state} -> {:ok, %{new_state | mode: :in_table}}
          {:not_found, _} -> :not_found
        end
    end
  end
end
