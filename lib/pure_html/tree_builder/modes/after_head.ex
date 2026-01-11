defmodule PureHTML.TreeBuilder.Modes.AfterHead do
  @moduledoc """
  HTML5 "after head" insertion mode.

  This mode is entered after the head element is closed.

  Per HTML5 spec:
  - Whitespace: Insert the character
  - Comment: Insert a comment
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules
  - <body> start tag: Insert body element, switch to "in body"
  - <frameset> start tag: Insert frameset element, switch to "in frameset"
  - Head elements (<base>, <link>, <meta>, <script>, <style>, <template>, <title>):
    Parse error, reprocess using "in head" rules
  - </template>: Process using "in head" rules
  - </body>, </html>, </br>: Act as "anything else"
  - <head> start tag: Parse error, ignore
  - Any other end tag: Parse error, ignore
  - Anything else: Insert implied <body>, switch to "in body", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-after-head-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers,
    only: [add_child: 2, add_text: 2, push_element: 3, set_mode: 2, set_frameset_ok: 2]

  @head_elements ~w(base basefont bgsound link meta noframes script style template title)

  @impl true
  def process({:character, text}, %{stack: stack} = state) do
    case String.trim(text) do
      "" ->
        # Whitespace: insert directly as child of current element (html)
        {:ok, %{state | stack: add_text(stack, text)}}

      _ ->
        # Non-whitespace: insert implied body, switch to in_body, reprocess
        {:reprocess, insert_implied_body(state)}
    end
  end

  def process({:comment, text}, %{stack: stack} = state) do
    # Insert comment as child of current element (html)
    {:ok, %{state | stack: add_child(stack, {:comment, text})}}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules - reprocess in :in_body mode
    # Body will be created by transition_to if needed
    {:reprocess, insert_implied_body(state)}
  end

  def process({:start_tag, "body", attrs, _self_closing}, state) do
    # Insert body element, switch to "in body", set frameset-ok to false
    state =
      state
      |> push_element("body", attrs)
      |> set_mode(:in_body)
      |> set_frameset_ok(false)

    {:ok, state}
  end

  def process({:start_tag, "frameset", attrs, _self_closing}, state) do
    # Insert frameset element, switch to "in frameset"
    state =
      state
      |> push_element("frameset", attrs)
      |> set_mode(:in_frameset)

    {:ok, state}
  end

  def process({:start_tag, tag, _attrs, _self_closing}, state) when tag in @head_elements do
    # Parse error, but process using "in head" rules
    # Delegate to main process/2 which will reopen head properly
    {:reprocess, %{state | mode: :in_body}}
  end

  def process({:start_tag, "head", _attrs, _self_closing}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:end_tag, "template"}, state) do
    # Process using "in head" rules
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:end_tag, tag}, state) when tag in ~w(body html br) do
    # Act as "anything else" - insert implied body and reprocess
    {:reprocess, insert_implied_body(state)}
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: insert implied <body>, switch to "in body", reprocess
    {:reprocess, insert_implied_body(state)}
  end

  # Insert an implied body element and switch to :in_body mode
  defp insert_implied_body(state) do
    state
    |> push_element("body", %{})
    |> set_mode(:in_body)
  end
end
