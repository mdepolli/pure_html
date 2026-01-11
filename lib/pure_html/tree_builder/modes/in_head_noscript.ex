defmodule PureHTML.TreeBuilder.Modes.InHeadNoscript do
  @moduledoc """
  HTML5 "in head noscript" insertion mode.

  This mode handles content inside a <noscript> element within <head>.

  Per HTML5 spec:
  - Character tokens (whitespace): process using "in head" rules
  - Comments: process using "in head" rules
  - DOCTYPE: parse error, ignore
  - Start tags:
    - html: process using "in body" rules
    - basefont, bgsound, link, meta, noframes, style: process using "in head" rules
    - head, noscript: parse error, ignore
    - Anything else: parse error, pop noscript, switch to "in head", reprocess
  - End tags:
    - noscript: pop noscript, switch to "in head"
    - br: parse error, pop noscript, switch to "in head", reprocess
    - Anything else: parse error, ignore
  - EOF: process using "in head" rules

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inheadnoscript
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  alias PureHTML.TreeBuilder.Modes.InHead
  alias PureHTML.TreeBuilder.Modes.InBody

  import PureHTML.TreeBuilder.Helpers, only: [add_child: 2]

  # Start tags processed using "in head" rules
  @in_head_start_tags ~w(basefont bgsound link meta noframes style)

  # Start tags that are parse errors and ignored
  @ignored_start_tags ~w(head noscript)

  @impl true
  # Whitespace characters: process using "in head" rules
  def process({:character, text} = token, state) do
    if String.trim(text) == "" do
      InHead.process(token, state)
    else
      # Non-whitespace: parse error, pop noscript, switch to in_head, reprocess
      {:reprocess, pop_noscript(state)}
    end
  end

  # Comments: process using "in head" rules
  def process({:comment, _} = token, state) do
    InHead.process(token, state)
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    {:ok, state}
  end

  # Start tag: html - process using "in body" rules
  def process({:start_tag, "html", _, _} = token, state) do
    InBody.process(token, state)
  end

  # Start tags processed using "in head" rules
  def process({:start_tag, tag, _, _} = token, state) when tag in @in_head_start_tags do
    InHead.process(token, state)
  end

  # Start tags that are parse errors and ignored
  def process({:start_tag, tag, _, _}, state) when tag in @ignored_start_tags do
    {:ok, state}
  end

  # Any other start tag: parse error, pop noscript, switch to in_head, reprocess
  def process({:start_tag, _, _, _}, state) do
    {:reprocess, pop_noscript(state)}
  end

  # End tag: noscript - pop noscript, switch to "in head"
  def process({:end_tag, "noscript"}, state) do
    {:ok, pop_noscript(state)}
  end

  # End tag: br - parse error, pop noscript, switch to in_head, reprocess
  def process({:end_tag, "br"}, state) do
    {:reprocess, pop_noscript(state)}
  end

  # Any other end tag: parse error, ignore
  def process({:end_tag, _}, state) do
    {:ok, state}
  end

  # EOF: process using "in head" rules
  def process(:eof, state) do
    InHead.process(:eof, state)
  end

  # Error tokens: ignore
  def process({:error, _}, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  # Pop noscript element and switch to in_head mode
  defp pop_noscript(%{stack: stack} = state) do
    new_stack = close_noscript(stack)
    %{state | stack: new_stack, mode: :in_head}
  end

  defp close_noscript([%{tag: "noscript"} = noscript | rest]) do
    add_child(rest, noscript)
  end

  defp close_noscript(stack), do: stack
end
