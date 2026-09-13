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

  import PureHTML.TreeBuilder.Helpers

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
    state
    |> parse_error()
    |> ok()
  end

  # Table-related start tags: close caption and reprocess.
  # Per spec: if no caption is in table scope, parse error; ignore.
  def process({:start_tag, tag, _, _}, state) when tag in @table_tags do
    if in_scope?(state, "caption", :table) do
      state
      |> close_caption()
      |> reprocess()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Other start tags: process using in_body rules
  def process({:start_tag, _, _, _} = token, state) do
    InBody.process(token, state)
  end

  # End tag: caption
  def process({:end_tag, "caption"}, state) do
    if in_scope?(state, "caption", :table) do
      state
      |> close_caption()
      |> ok()
    else
      # Parse error, ignore
      state
      |> parse_error()
      |> ok()
    end
  end

  # End tag: table - close caption and reprocess.
  # Per spec: if no caption is in table scope, parse error; ignore.
  def process({:end_tag, "table"}, state) do
    if in_scope?(state, "caption", :table) do
      state
      |> close_caption()
      |> reprocess()
    else
      state
      |> parse_error()
      |> ok()
    end
  end

  # Ignored end tags: parse error, ignore
  def process({:end_tag, tag}, state) when tag in @ignored_end_tags do
    state
    |> parse_error()
    |> ok()
  end

  # Other end tags: process using in_body rules
  def process({:end_tag, _} = token, state) do
    InBody.process(token, state)
  end

  # EOF: process using in_body rules
  def process(:eof, state), do: process_in_body(state, :eof)

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Caller guarantees a caption is in table scope.
  # Per spec: generate implied end tags; if the current node is not a caption,
  # parse error; pop until a caption has been popped.
  defp close_caption(state) do
    state
    |> generate_implied_end_tags()
    |> parse_error_unless_current_caption()
    |> pop_caption()
  end

  defp parse_error_unless_current_caption(state) do
    state
    |> current_tag()
    |> mismatch_if_not_caption(state)
  end

  defp mismatch_if_not_caption("caption", state), do: state
  defp mismatch_if_not_caption(_tag, state), do: parse_error(state)

  defp pop_caption(state) do
    state
    |> pop_until_tag("caption")
    |> after_pop_caption()
  end

  # Per spec: clear the list of active formatting elements up to the last marker,
  # then switch the insertion mode to "in table".
  defp after_pop_caption({:ok, state}) do
    state
    |> clear_af_to_marker()
    |> set_mode(:in_table)
  end
end
