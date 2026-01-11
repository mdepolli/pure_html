defmodule PureHTML.TreeBuilder.InsertionMode do
  @moduledoc """
  Behavior for HTML5 insertion mode handlers.

  Each insertion mode module implements this behavior to handle tokens
  according to the HTML5 tree construction algorithm.

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-insertion-mode
  """

  alias PureHTML.TreeBuilder.State

  @type token ::
          {:doctype, String.t(), String.t() | nil, String.t() | nil, boolean()}
          | {:start_tag, String.t(), map(), boolean()}
          | {:end_tag, String.t()}
          | {:character, String.t()}
          | {:comment, String.t()}
          | {:error, atom()}
          | :eof

  @type result ::
          {:ok, State.t()}
          | {:reprocess, State.t()}

  @doc """
  Process a token in this insertion mode.

  Returns either:
  - `{:ok, state}` - Token fully processed, continue with next token
  - `{:reprocess, state}` - Token should be reprocessed in the new mode

  The state may include a mode transition.
  """
  @callback process(token(), State.t()) :: result()
end
