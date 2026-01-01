defmodule PureHtml.Tokenizer do
  @moduledoc """
  HTML5 tokenizer that produces a stream of tokens.

  The tokenizer is implemented as a state machine. Each call to `next_token/1`
  advances the machine until it produces a token, then returns the token and
  the updated state.

  ## Usage

      iex> PureHtml.Tokenizer.tokenize("<p>Hello</p>") |> Enum.to_list()
      [{:start_tag, "p", %{}, false}, {:character, "Hello"}, {:end_tag, "p"}]

  ## Token Types

  - `{:doctype, name, public_id, system_id, force_quirks?}`
  - `{:start_tag, name, attrs, self_closing?}`
  - `{:end_tag, name}`
  - `{:comment, data}`
  - `{:character, data}`
  - `{:error, code}` (parse errors)

  """

  alias PureHtml.Entities

  # The tokenizer state struct
  defstruct [
    # remaining input binary
    :input,
    # current state atom
    :state,
    # state to return to (for character references, etc.)
    :return_state,
    # token being built
    :token,
    # temporary buffer for tag names, etc.
    :buffer,
    # current attribute name being built
    :attr_name,
    # current attribute value being built
    :attr_value,
    # for appropriate end tag checks
    :last_start_tag,
    # accumulated errors (emitted with tokens)
    :errors,
    # pending character data (for coalescing)
    :pending_chars,
    # deferred token (to emit after flushing pending chars)
    :deferred_token
  ]

  @type t :: %__MODULE__{}

  @type token ::
          {:doctype, String.t() | nil, String.t() | nil, String.t() | nil, boolean()}
          | {:start_tag, String.t(), map(), boolean()}
          | {:end_tag, String.t()}
          | {:comment, String.t()}
          | {:character, String.t()}
          | {:error, atom()}

  # Guards
  defguardp is_ascii_alpha(c) when c in ?a..?z or c in ?A..?Z
  defguardp is_ascii_lower(c) when c in ?a..?z
  defguardp is_ascii_upper(c) when c in ?A..?Z
  defguardp is_ascii_digit(c) when c in ?0..?9
  defguardp is_ascii_whitespace(c) when c in ~c[\t\n\f ]
  defguardp is_ascii_hex_digit(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # Match "doctype" case-insensitively using bitwise OR with 0x20 to force lowercase
  # "doctype" as 56-bit integer: 0x646F6374797065
  defguardp is_doctype(prefix)
            when :erlang.bor(prefix, 0x20202020202020) == 0x646F6374797065

  # "public" as 48-bit integer: 0x7075626C6963
  defguardp is_public(prefix)
            when :erlang.bor(prefix, 0x202020202020) == 0x7075626C6963

  # "system" as 48-bit integer: 0x73797374656D
  defguardp is_system(prefix)
            when :erlang.bor(prefix, 0x202020202020) == 0x73797374656D

  defguardp is_attribute_value_state(state)
            when state in [
                   :attribute_value_double_quoted,
                   :attribute_value_single_quoted,
                   :attribute_value_unquoted
                 ]

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Tokenizes an HTML string, returning a Stream of tokens.

  The stream is lazy - tokens are produced on demand as the stream is consumed.
  """
  @spec tokenize(String.t(), keyword()) :: Enumerable.t()
  def tokenize(input, opts \\ []) when is_binary(input) do
    initial_state = Keyword.get(opts, :initial_state, :data)
    last_start_tag = Keyword.get(opts, :last_start_tag, nil)

    # Normalize newlines per HTML5 spec: CRLF → LF, CR → LF
    normalized_input = input |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    tokenizer = %__MODULE__{
      input: normalized_input,
      state: initial_state,
      return_state: nil,
      token: nil,
      buffer: "",
      attr_name: "",
      attr_value: "",
      last_start_tag: last_start_tag,
      errors: [],
      pending_chars: [],
      deferred_token: nil
    }

    Stream.unfold(tokenizer, &next_token/1)
  end

  # --------------------------------------------------------------------------
  # Token emission
  # --------------------------------------------------------------------------

  # Returns {token, updated_tokenizer} or nil when done
  # First, check for a deferred token from previous flush
  defp next_token(%__MODULE__{deferred_token: token} = state) when token != nil do
    {token, %{state | deferred_token: nil}}
  end

  # States where EOF should flush pending chars and terminate.
  # Excludes "less_than_sign" states which have implicit pending '<' to emit via step.
  @eof_flush_states [
    :data,
    :rawtext,
    :rcdata,
    :plaintext,
    :script_data,
    :script_data_escape_start,
    :script_data_escape_start_dash,
    :script_data_escaped,
    :script_data_escaped_dash,
    :script_data_escaped_dash_dash,
    :script_data_double_escaped,
    :script_data_double_escaped_dash,
    :script_data_double_escaped_dash_dash
  ]

  defp next_token(%__MODULE__{input: "", state: s, pending_chars: []} = _state)
       when s in @eof_flush_states do
    nil
  end

  defp next_token(%__MODULE__{input: "", state: s, pending_chars: pending} = state)
       when s in @eof_flush_states do
    # Flush pending chars at EOF
    {flush_pending(pending), %{state | pending_chars: []}}
  end

  defp next_token(%__MODULE__{} = state) do
    case step(state) do
      {:emit_char, chars, new_state} ->
        # Accumulate characters instead of emitting immediately
        next_token(%{new_state | pending_chars: [chars | new_state.pending_chars]})

      {:emit, token, new_state} ->
        # Flush pending chars before emitting non-char token
        case new_state.pending_chars do
          [] ->
            {token, new_state}

          pending ->
            # Emit chars now, defer the non-char token
            {flush_pending(pending), %{new_state | pending_chars: [], deferred_token: token}}
        end

      {:continue, new_state} ->
        next_token(new_state)

      nil when state.pending_chars == [] ->
        nil

      nil ->
        {flush_pending(state.pending_chars), %{state | pending_chars: []}}
    end
  end

  defp flush_pending(pending) do
    {:character, pending |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  # --------------------------------------------------------------------------
  # State machine
  # --------------------------------------------------------------------------

  # Data state - the default state, reading regular content
  defp step(%{state: :data, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :tag_open, input: rest)
  end

  defp step(%{state: :data, input: <<?&, _rest::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :data)
  end

  defp step(%{state: :data, input: <<0, rest::binary>>} = state) do
    # Null character - parse error, emit as character
    emit_char(state, <<0>>, input: rest)
  end

  defp step(%{state: :data, input: input} = state) when input != "" do
    # Read ahead until we hit <, &, null, or end - emit coalesced characters
    {chars, rest} = chars_until(input, [?<, ?&, 0])
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :data, input: ""} = _state) do
    # Handled by next_token/1 - but keeping for completeness
    nil
  end

  # RAWTEXT state - for <style>, <xmp>, etc. No entity decoding.
  defp step(%{state: :rawtext, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :rawtext_less_than_sign, input: rest)
  end

  defp step(%{state: :rawtext, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :rawtext, input: ""} = _state), do: nil

  defp step(%{state: :rawtext, input: input} = state) do
    {chars, rest} = chars_until(input, [?<, 0])
    emit_char(state, chars, input: rest)
  end

  # PLAINTEXT state - consumes everything until EOF, no end tag recognition
  defp step(%{state: :plaintext, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :plaintext, input: ""} = _state), do: nil

  defp step(%{state: :plaintext, input: input} = state) do
    {chars, rest} = chars_until(input, [0])
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :rawtext_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :rawtext_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :rawtext_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :rawtext)
  end

  defp step(%{state: :rawtext_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :rawtext_end_tag_name,
      token: {:end_tag, ""},
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :rawtext_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :rawtext)
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      emit_rawtext_buffer(state, rest)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      emit_rawtext_buffer(state, rest)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :rawtext, token: nil, input: rest)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rawtext_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rawtext_end_tag_name, input: _} = state) do
    emit_rawtext_buffer(state, state.input)
  end

  # RCDATA state - for <textarea>, <title>. Processes entities.
  defp step(%{state: :rcdata, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :rcdata_less_than_sign, input: rest)
  end

  defp step(%{state: :rcdata, input: <<?&, _rest::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :rcdata)
  end

  defp step(%{state: :rcdata, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :rcdata, input: ""} = _state), do: nil

  defp step(%{state: :rcdata, input: input} = state) do
    {chars, rest} = chars_until(input, [?<, ?&, 0])
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :rcdata_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :rcdata_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :rcdata_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :rcdata)
  end

  defp step(%{state: :rcdata_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :rcdata_end_tag_name,
      token: {:end_tag, ""},
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :rcdata_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :rcdata)
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      emit_rcdata_buffer(state, rest)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      emit_rcdata_buffer(state, rest)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :rcdata, token: nil, input: rest)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rcdata_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rcdata_end_tag_name, input: _} = state) do
    emit_rcdata_buffer(state, state.input)
  end

  # Script data state - for <script>. Similar to RAWTEXT but handles escaped states.
  defp step(%{state: :script_data, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data, input: ""} = _state), do: nil

  defp step(%{state: :script_data, input: input} = state) do
    {chars, rest} = chars_until(input, [?<, 0])
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :script_data_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: <<?!, rest::binary>>} = state) do
    emit_char(state, "<!", state: :script_data_escape_start, input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :script_data)
  end

  defp step(%{state: :script_data_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :script_data_end_tag_name,
      token: {:end_tag, ""},
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :script_data_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :script_data)
  end

  defp step(%{state: :script_data_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      emit_script_buffer(state, rest)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      emit_script_buffer(state, rest)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :script_data, token: nil, input: rest)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_end_tag_name, input: _} = state) do
    emit_script_buffer(state, state.input)
  end

  # Script data escape start
  defp step(%{state: :script_data_escape_start, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escape_start_dash, input: rest)
  end

  defp step(%{state: :script_data_escape_start, input: _} = state) do
    continue(state, state: :script_data)
  end

  defp step(%{state: :script_data_escape_start_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_escape_start_dash, input: _} = state) do
    continue(state, state: :script_data)
  end

  # Script data escaped state
  defp step(%{state: :script_data_escaped, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: ""} = _state), do: nil

  defp step(%{state: :script_data_escaped, input: input} = state) do
    {chars, rest} = chars_until(input, [?-, ?<, 0])
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: ""} = _state), do: nil

  defp step(%{state: :script_data_escaped_dash, input: <<c::utf8, rest::binary>>} = state) do
    emit_char(state, <<c::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<?<, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<?>, rest::binary>>} = state) do
    emit_char(state, ">", state: :script_data, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: ""} = _state), do: nil

  defp step(%{state: :script_data_escaped_dash_dash, input: <<c::utf8, rest::binary>>} = state) do
    emit_char(state, <<c::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :script_data_escaped_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>

    emit_char(state, "<" <> char,
      state: :script_data_double_escape_start,
      buffer: char,
      input: rest
    )
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :script_data_escaped)
  end

  defp step(%{state: :script_data_escaped_end_tag_open, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :script_data_escaped_end_tag_name,
      token: {:end_tag, ""},
      input: <<c, rest::binary>>
    )
  end

  defp step(%{state: :script_data_escaped_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :script_data_escaped)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      emit_char(state, "</" <> state.buffer, state: :script_data_escaped, token: nil, input: rest)
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<?/, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      emit_char(state, "</" <> state.buffer, state: :script_data_escaped, token: nil, input: rest)
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<?>, rest::binary>>} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :script_data_escaped, token: nil, input: rest)
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: _} = state) do
    emit_char(state, "</" <> state.buffer, state: :script_data_escaped, token: nil)
  end

  # Script data double escape start
  defp step(%{state: :script_data_double_escape_start, input: <<c, rest::binary>>} = state)
       when c in ~c[\t\n\f /] or c == ?> do
    if state.buffer == "script" do
      emit_char(state, <<c>>, state: :script_data_double_escaped, input: rest)
    else
      emit_char(state, <<c>>, state: :script_data_escaped, input: rest)
    end
  end

  defp step(%{state: :script_data_double_escape_start, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>
    emit_char(state, <<c>>, buffer: state.buffer <> char, input: rest)
  end

  defp step(%{state: :script_data_double_escape_start, input: _} = state) do
    continue(state, state: :script_data_escaped)
  end

  # Script data double escaped state
  defp step(%{state: :script_data_double_escaped, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_double_escaped_dash, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: <<?<, rest::binary>>} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: ""} = _state), do: nil

  defp step(%{state: :script_data_double_escaped, input: input} = state) do
    {chars, rest} = chars_until(input, [?-, ?<, 0])
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", state: :script_data_double_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: <<?<, rest::binary>>} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: ""} = _state), do: nil

  defp step(%{state: :script_data_double_escaped_dash, input: <<c::utf8, rest::binary>>} = state) do
    emit_char(state, <<c::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<?-, rest::binary>>} = state) do
    emit_char(state, "-", input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<?<, rest::binary>>} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<?>, rest::binary>>} = state) do
    emit_char(state, ">", state: :script_data, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: <<0, rest::binary>>} = state) do
    emit_char(state, <<0xFFFD::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: ""} = _state), do: nil

  defp step(
         %{state: :script_data_double_escaped_dash_dash, input: <<c::utf8, rest::binary>>} = state
       ) do
    emit_char(state, <<c::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(
         %{state: :script_data_double_escaped_less_than_sign, input: <<?/, rest::binary>>} = state
       ) do
    emit_char(state, "/", state: :script_data_double_escape_end, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_double_escaped_less_than_sign, input: _} = state) do
    continue(state, state: :script_data_double_escaped)
  end

  defp step(%{state: :script_data_double_escape_end, input: <<c, rest::binary>>} = state)
       when c in ~c[\t\n\f /] or c == ?> do
    if state.buffer == "script" do
      emit_char(state, <<c>>, state: :script_data_escaped, input: rest)
    else
      emit_char(state, <<c>>, state: :script_data_double_escaped, input: rest)
    end
  end

  defp step(%{state: :script_data_double_escape_end, input: <<c, rest::binary>>} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>
    emit_char(state, <<c>>, buffer: state.buffer <> char, input: rest)
  end

  defp step(%{state: :script_data_double_escape_end, input: _} = state) do
    continue(state, state: :script_data_double_escaped)
  end

  # Tag open state - saw '<', determine what kind of tag
  defp step(%{state: :tag_open, input: <<?!, rest::binary>>} = state) do
    continue(state, state: :markup_declaration_open, input: rest)
  end

  defp step(%{state: :tag_open, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :end_tag_open, input: rest)
  end

  defp step(%{state: :tag_open, input: <<c, rest::binary>>} = state) when is_ascii_alpha(c) do
    continue(state,
      state: :tag_name,
      input: <<c, rest::binary>>,
      token: {:start_tag, "", %{}, false}
    )
  end

  defp step(%{state: :tag_open, input: <<??, _rest::binary>>} = state) do
    continue(state, state: :bogus_comment, token: {:comment, ""})
  end

  defp step(%{state: :tag_open, input: ""} = state) do
    # EOF before tag name - emit '<' as character
    emit_char(state, "<", state: :data)
  end

  defp step(%{state: :tag_open, input: _} = state) do
    # Anything else - emit '<' as character and reconsume in data state
    emit_char(state, "<", state: :data)
  end

  # End tag open state - saw '</'
  defp step(%{state: :end_tag_open, input: <<c, rest::binary>>} = state) when is_ascii_alpha(c) do
    continue(state, state: :tag_name, input: <<c, rest::binary>>, token: {:end_tag, ""})
  end

  defp step(%{state: :end_tag_open, input: <<?>, rest::binary>>} = state) do
    # Missing end tag name - parse error, ignore token
    continue(state, state: :data, input: rest)
  end

  defp step(%{state: :end_tag_open, input: ""} = state) do
    # EOF - emit '</' as characters
    emit_char(state, "</", state: :data)
  end

  defp step(%{state: :end_tag_open, input: _} = state) do
    # Anything else - bogus comment
    continue(state, state: :bogus_comment, token: {:comment, ""})
  end

  # Tag name state - reading the tag name
  defp step(%{state: :tag_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest, state: :before_attribute_name)
  end

  defp step(%{state: :tag_name, input: <<?/, rest::binary>>} = state) do
    continue(state, input: rest, state: :self_closing_start_tag)
  end

  defp step(%{state: :tag_name, input: <<?>, rest::binary>>} = state) do
    state
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :tag_name, input: <<c, rest::binary>>} = state) when is_ascii_upper(c) do
    # Uppercase - lowercase it
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(input: rest)
  end

  defp step(%{state: :tag_name, input: <<0, rest::binary>>} = state) do
    # Null - replacement character
    state
    |> append_to_tag_name(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :tag_name, input: ""} = _state) do
    # EOF in tag - discard the incomplete tag (parse error)
    nil
  end

  defp step(%{state: :tag_name, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_tag_name(<<c::utf8>>)
    |> continue(input: rest)
  end

  # Before attribute name state
  defp step(%{state: :before_attribute_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_attribute_name, input: <<c, _::binary>>} = state)
       when c in ~c[/>] do
    continue(state, state: :after_attribute_name)
  end

  defp step(%{state: :before_attribute_name, input: ""} = _state) do
    # EOF in tag - discard (parse error)
    nil
  end

  defp step(%{state: :before_attribute_name, input: <<?=, rest::binary>>} = state) do
    # Unexpected equals sign - start attribute with '=' as name
    state
    |> start_new_attribute("=")
    |> continue(state: :attribute_name, input: rest)
  end

  defp step(%{state: :before_attribute_name, input: _} = state) do
    state
    |> start_new_attribute("")
    |> continue(state: :attribute_name)
  end

  # Attribute name state
  defp step(%{state: :attribute_name, input: <<c, _::binary>>} = state)
       when c in ~c[\t\n\f />] do
    state
    |> finalize_attribute_name()
    |> continue(state: :after_attribute_name)
  end

  defp step(%{state: :attribute_name, input: ""} = _state) do
    # EOF in tag - discard (parse error)
    nil
  end

  defp step(%{state: :attribute_name, input: <<?=, rest::binary>>} = state) do
    state
    |> finalize_attribute_name()
    |> continue(state: :before_attribute_value, input: rest)
  end

  defp step(%{state: :attribute_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c + 32>>)
  end

  defp step(%{state: :attribute_name, input: <<0, rest::binary>>} = state) do
    continue(state, input: rest, buffer: state.buffer <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_name, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, buffer: state.buffer <> <<c::utf8>>)
  end

  # After attribute name state
  defp step(%{state: :after_attribute_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: <<?/, rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :self_closing_start_tag, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: <<?=, rest::binary>>} = state) do
    continue(state, state: :before_attribute_value, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: <<?>, rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :after_attribute_name, input: ""} = _state) do
    # EOF in tag - discard (parse error)
    nil
  end

  defp step(%{state: :after_attribute_name, input: _} = state) do
    state
    |> finalize_attribute_value()
    |> start_new_attribute("")
    |> continue(state: :attribute_name)
  end

  # Before attribute value state
  defp step(%{state: :before_attribute_value, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: <<?", rest::binary>>} = state) do
    continue(state, state: :attribute_value_double_quoted, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: <<?', rest::binary>>} = state) do
    continue(state, state: :attribute_value_single_quoted, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: <<?>, rest::binary>>} = state) do
    # Missing attribute value - finalize with empty value
    state
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :before_attribute_value, input: ""} = _state) do
    # EOF in tag - discard (parse error)
    nil
  end

  defp step(%{state: :before_attribute_value, input: _} = state) do
    continue(state, state: :attribute_value_unquoted)
  end

  # Attribute value (double-quoted) state
  defp step(%{state: :attribute_value_double_quoted, input: <<?", rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :after_attribute_value_quoted, input: rest)
  end

  defp step(%{state: :attribute_value_double_quoted, input: <<?&, _::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_double_quoted)
  end

  defp step(%{state: :attribute_value_double_quoted, input: <<0, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_double_quoted, input: ""} = _state) do
    # EOF in tag - discard (parse error)
    nil
  end

  defp step(%{state: :attribute_value_double_quoted, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<c::utf8>>)
  end

  # Attribute value (single-quoted) state
  defp step(%{state: :attribute_value_single_quoted, input: <<?', rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :after_attribute_value_quoted, input: rest)
  end

  defp step(%{state: :attribute_value_single_quoted, input: <<?&, _::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_single_quoted)
  end

  defp step(%{state: :attribute_value_single_quoted, input: <<0, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_single_quoted, input: ""} = _state) do
    # EOF in tag - discard (parse error)
    nil
  end

  defp step(%{state: :attribute_value_single_quoted, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<c::utf8>>)
  end

  # Attribute value (unquoted) state
  defp step(%{state: :attribute_value_unquoted, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    state
    |> finalize_attribute_value()
    |> continue(state: :before_attribute_name, input: rest)
  end

  defp step(%{state: :attribute_value_unquoted, input: <<?&, _::binary>>} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_unquoted)
  end

  defp step(%{state: :attribute_value_unquoted, input: <<?>, rest::binary>>} = state) do
    state
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :attribute_value_unquoted, input: <<0, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_unquoted, input: ""} = _state) do
    # EOF in tag - discard (parse error)
    nil
  end

  defp step(%{state: :attribute_value_unquoted, input: <<c::utf8, rest::binary>>} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> <<c::utf8>>)
  end

  # After attribute value (quoted) state
  defp step(%{state: :after_attribute_value_quoted, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_attribute_name, input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: <<?/, rest::binary>>} = state) do
    continue(state, state: :self_closing_start_tag, input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: <<?>, rest::binary>>} = state) do
    state
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: ""} = _state) do
    nil
  end

  defp step(%{state: :after_attribute_value_quoted, input: _} = state) do
    # Missing whitespace between attributes - reconsume
    continue(state, state: :before_attribute_name)
  end

  # Self-closing start tag state
  defp step(%{state: :self_closing_start_tag, input: <<?>, rest::binary>>} = state) do
    state
    |> set_self_closing()
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :self_closing_start_tag, input: ""} = _state) do
    nil
  end

  defp step(%{state: :self_closing_start_tag, input: _} = state) do
    # Unexpected solidus - reconsume in before attribute name
    continue(state, state: :before_attribute_name)
  end

  # Markup declaration open state - after '<!'
  defp step(%{state: :markup_declaration_open, input: <<"--", rest::binary>>} = state) do
    continue(state, state: :comment_start, input: rest, token: {:comment, ""})
  end

  defp step(%{state: :markup_declaration_open, input: <<prefix::56, rest::binary>>} = state)
       when is_doctype(prefix) do
    continue(state, state: :doctype, input: rest)
  end

  defp step(%{state: :markup_declaration_open, input: _} = state) do
    continue(state, state: :bogus_comment, token: {:comment, ""})
  end

  # Comment start state
  defp step(%{state: :comment_start, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_start_dash, input: rest)
  end

  defp step(%{state: :comment_start, input: <<?>, rest::binary>>} = state) do
    # Abrupt closing of empty comment
    emit(state, input: rest)
  end

  defp step(%{state: :comment_start, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment start dash state
  defp step(%{state: :comment_start_dash, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_end, input: rest)
  end

  defp step(%{state: :comment_start_dash, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :comment_start_dash, input: ""} = state) do
    emit(state, [])
  end

  defp step(%{state: :comment_start_dash, input: _} = state) do
    state
    |> append_to_comment("-")
    |> continue(state: :comment)
  end

  # Comment state
  defp step(%{state: :comment, input: <<?<, rest::binary>>} = state) do
    state
    |> append_to_comment("<")
    |> continue(state: :comment_less_than_sign, input: rest)
  end

  defp step(%{state: :comment, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_end_dash, input: rest)
  end

  defp step(%{state: :comment, input: <<0, rest::binary>>} = state) do
    state
    |> append_to_comment(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :comment, input: ""} = state) do
    emit(state, [])
  end

  defp step(%{state: :comment, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_comment(<<c::utf8>>)
    |> continue(input: rest)
  end

  # Comment less-than sign state
  defp step(%{state: :comment_less_than_sign, input: <<?!, rest::binary>>} = state) do
    state
    |> append_to_comment("!")
    |> continue(state: :comment_less_than_sign_bang, input: rest)
  end

  defp step(%{state: :comment_less_than_sign, input: <<?<, rest::binary>>} = state) do
    state
    |> append_to_comment("<")
    |> continue(input: rest)
  end

  defp step(%{state: :comment_less_than_sign, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment less-than sign bang state
  defp step(%{state: :comment_less_than_sign_bang, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_less_than_sign_bang_dash, input: rest)
  end

  defp step(%{state: :comment_less_than_sign_bang, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment less-than sign bang dash state
  defp step(%{state: :comment_less_than_sign_bang_dash, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_less_than_sign_bang_dash_dash, input: rest)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash, input: _} = state) do
    continue(state, state: :comment_end_dash)
  end

  # Comment less-than sign bang dash dash state
  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: <<?>, _::binary>>} = state) do
    continue(state, state: :comment_end)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: ""} = state) do
    continue(state, state: :comment_end)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: _} = state) do
    # Nested comment - parse error
    continue(state, state: :comment_end)
  end

  # Comment end dash state
  defp step(%{state: :comment_end_dash, input: <<?-, rest::binary>>} = state) do
    continue(state, state: :comment_end, input: rest)
  end

  defp step(%{state: :comment_end_dash, input: ""} = state) do
    emit(state, [])
  end

  defp step(%{state: :comment_end_dash, input: _} = state) do
    state
    |> append_to_comment("-")
    |> continue(state: :comment)
  end

  # Comment end state
  defp step(%{state: :comment_end, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :comment_end, input: <<?!, rest::binary>>} = state) do
    continue(state, state: :comment_end_bang, input: rest)
  end

  defp step(%{state: :comment_end, input: <<?-, rest::binary>>} = state) do
    state
    |> append_to_comment("-")
    |> continue(input: rest)
  end

  defp step(%{state: :comment_end, input: ""} = state) do
    emit(state, [])
  end

  defp step(%{state: :comment_end, input: _} = state) do
    state
    |> append_to_comment("--")
    |> continue(state: :comment)
  end

  # Comment end bang state
  defp step(%{state: :comment_end_bang, input: <<?-, rest::binary>>} = state) do
    state
    |> append_to_comment("--!")
    |> continue(state: :comment_end_dash, input: rest)
  end

  defp step(%{state: :comment_end_bang, input: <<?>, rest::binary>>} = state) do
    # Incorrectly closed comment
    emit(state, input: rest)
  end

  defp step(%{state: :comment_end_bang, input: ""} = state) do
    emit(state, [])
  end

  defp step(%{state: :comment_end_bang, input: _} = state) do
    state
    |> append_to_comment("--!")
    |> continue(state: :comment)
  end

  # DOCTYPE state
  defp step(%{state: :doctype, input: <<c, rest::binary>>} = state) when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_name, input: rest)
  end

  defp step(%{state: :doctype, input: <<?>, _::binary>>} = state) do
    continue(state, state: :before_doctype_name)
  end

  defp step(%{state: :doctype, input: ""} = state) do
    emit(%{state | token: {:doctype, nil, nil, nil, true}}, [])
  end

  defp step(%{state: :doctype, input: _} = state) do
    # Missing whitespace before doctype name
    continue(state, state: :before_doctype_name)
  end

  # Before DOCTYPE name state
  defp step(%{state: :before_doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    continue(state,
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<c + 32>>, nil, nil, false}
    )
  end

  defp step(%{state: :before_doctype_name, input: <<0, rest::binary>>} = state) do
    continue(state,
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<0xFFFD::utf8>>, nil, nil, false}
    )
  end

  defp step(%{state: :before_doctype_name, input: <<?>, rest::binary>>} = state) do
    emit(%{state | token: {:doctype, nil, nil, nil, true}}, input: rest)
  end

  defp step(%{state: :before_doctype_name, input: ""} = state) do
    emit(%{state | token: {:doctype, nil, nil, nil, true}}, [])
  end

  defp step(%{state: :before_doctype_name, input: <<c::utf8, rest::binary>>} = state) do
    continue(state,
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<c::utf8>>, nil, nil, false}
    )
  end

  # DOCTYPE name state
  defp step(%{state: :doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest, state: :after_doctype_name)
  end

  defp step(%{state: :doctype_name, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_doctype_name(<<c + 32>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_name, input: <<0, rest::binary>>} = state) do
    state
    |> append_to_doctype_name(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_name, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :doctype_name, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_doctype_name(<<c::utf8>>)
    |> continue(input: rest)
  end

  # After DOCTYPE name state
  defp step(%{state: :after_doctype_name, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :after_doctype_name, input: <<prefix::48, rest::binary>>} = state)
       when is_public(prefix) do
    continue(state, state: :after_doctype_public_keyword, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: <<prefix::48, rest::binary>>} = state)
       when is_system(prefix) do
    continue(state, state: :after_doctype_system_keyword, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: _} = state) do
    state
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # After DOCTYPE public keyword state
  defp step(%{state: :after_doctype_public_keyword, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_public_identifier, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: <<?", rest::binary>>} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: <<?', rest::binary>>} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: <<?>, rest::binary>>} = state) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :after_doctype_public_keyword, input: _} = state) do
    state
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Before DOCTYPE public identifier state
  defp step(%{state: :before_doctype_public_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: <<?", rest::binary>>} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: <<?', rest::binary>>} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: <<?>, rest::binary>>} = state) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :before_doctype_public_identifier, input: _} = state) do
    state
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # DOCTYPE public identifier (double-quoted) state
  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<?", rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_public_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<0, rest::binary>>} = state
       ) do
    state
    |> append_to_doctype_public_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<?>, rest::binary>>} = state
       ) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_double_quoted, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_public_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # DOCTYPE public identifier (single-quoted) state
  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<?', rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_public_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<0, rest::binary>>} = state
       ) do
    state
    |> append_to_doctype_public_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<?>, rest::binary>>} = state
       ) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_single_quoted, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_public_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # After DOCTYPE public identifier state
  defp step(%{state: :after_doctype_public_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :between_doctype_public_and_system_identifiers, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: <<?", rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: <<?', rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :after_doctype_public_identifier, input: _} = state) do
    # Missing quote before system identifier - triggers quirks mode
    state
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Between DOCTYPE public and system identifiers state
  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<c, rest::binary>>} =
           state
       )
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<?>, rest::binary>>} =
           state
       ) do
    emit(state, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<?", rest::binary>>} =
           state
       ) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: <<?', rest::binary>>} =
           state
       ) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :between_doctype_public_and_system_identifiers, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :between_doctype_public_and_system_identifiers, input: _} = state) do
    state
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # After DOCTYPE system keyword state
  defp step(%{state: :after_doctype_system_keyword, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_system_identifier, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: <<?", rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: <<?', rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: <<?>, rest::binary>>} = state) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :after_doctype_system_keyword, input: _} = state) do
    state
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Before DOCTYPE system identifier state
  defp step(%{state: :before_doctype_system_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: <<?", rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: <<?', rest::binary>>} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: <<?>, rest::binary>>} = state) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :before_doctype_system_identifier, input: _} = state) do
    state
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # DOCTYPE system identifier (double-quoted) state
  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<?", rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_system_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<0, rest::binary>>} = state
       ) do
    state
    |> append_to_doctype_system_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<?>, rest::binary>>} = state
       ) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_double_quoted, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_system_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # DOCTYPE system identifier (single-quoted) state
  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<?', rest::binary>>} = state
       ) do
    continue(state, state: :after_doctype_system_identifier, input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<0, rest::binary>>} = state
       ) do
    state
    |> append_to_doctype_system_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<?>, rest::binary>>} = state
       ) do
    state
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_single_quoted, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: <<c::utf8, rest::binary>>} =
           state
       ) do
    state
    |> append_to_doctype_system_id(<<c::utf8>>)
    |> continue(input: rest)
  end

  # After DOCTYPE system identifier state
  defp step(%{state: :after_doctype_system_identifier, input: <<c, rest::binary>>} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_doctype_system_identifier, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_system_identifier, input: ""} = state) do
    state
    |> set_force_quirks()
    |> emit([])
  end

  defp step(%{state: :after_doctype_system_identifier, input: _} = state) do
    continue(state, state: :bogus_doctype)
  end

  # Bogus comment state
  defp step(%{state: :bogus_comment, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :bogus_comment, input: ""} = state) do
    emit(state, [])
  end

  defp step(%{state: :bogus_comment, input: <<0, rest::binary>>} = state) do
    state
    |> append_to_comment(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :bogus_comment, input: <<c::utf8, rest::binary>>} = state) do
    state
    |> append_to_comment(<<c::utf8>>)
    |> continue(input: rest)
  end

  # Bogus DOCTYPE state
  defp step(%{state: :bogus_doctype, input: <<?>, rest::binary>>} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :bogus_doctype, input: ""} = state) do
    emit(state, [])
  end

  defp step(%{state: :bogus_doctype, input: <<_, rest::binary>>} = state) do
    continue(state, input: rest)
  end

  # Character reference state - handles &entities;
  defp step(%{state: :character_reference, input: <<"&#", rest::binary>>} = state) do
    continue(state, input: rest, buffer: "", state: :numeric_character_reference)
  end

  defp step(%{state: :character_reference, input: <<?&, _::binary>> = input} = state) do
    with {chars, rest} <- Entities.lookup(input),
         true <- consumable_entity?(state.return_state, input, rest) do
      flush_char_ref(state, chars, rest)
    else
      _ ->
        <<_, after_amp::binary>> = input
        flush_char_ref(state, "&", after_amp)
    end
  end

  # Numeric character reference state
  defp step(%{state: :numeric_character_reference, input: <<c, rest::binary>>} = state)
       when c in ~c[xX] do
    # Store the x/X in buffer to preserve case if we need to emit it as text
    continue(state, input: rest, buffer: <<c>>, state: :hexadecimal_character_reference_start)
  end

  defp step(%{state: :numeric_character_reference, input: _} = state) do
    continue(state, buffer: "", state: :decimal_character_reference_start)
  end

  # Decimal character reference start
  defp step(%{state: :decimal_character_reference_start, input: <<c, _::binary>>} = state)
       when is_ascii_digit(c) do
    continue(state, state: :decimal_character_reference)
  end

  defp step(%{state: :decimal_character_reference_start, input: _} = state) do
    # No digits - emit &#
    emit_failed_char_ref(state, "&#")
  end

  # Decimal character reference
  defp step(%{state: :decimal_character_reference, input: <<c, rest::binary>>} = state)
       when is_ascii_digit(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :decimal_character_reference, input: <<?;, rest::binary>>} = state) do
    finish_numeric_char_ref(state, rest, 10)
  end

  defp step(%{state: :decimal_character_reference, input: _} = state) do
    # Missing semicolon
    finish_numeric_char_ref(state, state.input, 10)
  end

  # Hexadecimal character reference start
  defp step(%{state: :hexadecimal_character_reference_start, input: <<c, _::binary>>} = state)
       when is_ascii_hex_digit(c) do
    # Clear the x/X from buffer, start collecting digits
    continue(state, buffer: "", state: :hexadecimal_character_reference)
  end

  defp step(%{state: :hexadecimal_character_reference_start, input: _} = state) do
    # Buffer contains the x/X, preserve its case
    emit_failed_char_ref(state, "&#" <> state.buffer)
  end

  # Hexadecimal character reference
  defp step(%{state: :hexadecimal_character_reference, input: <<c, rest::binary>>} = state)
       when is_ascii_hex_digit(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :hexadecimal_character_reference, input: <<?;, rest::binary>>} = state) do
    finish_numeric_char_ref(state, rest, 16)
  end

  defp step(%{state: :hexadecimal_character_reference, input: _} = state) do
    finish_numeric_char_ref(state, state.input, 16)
  end

  defp emit_failed_char_ref(state, prefix) do
    case state.return_state do
      return_state when is_attribute_value_state(return_state) ->
        continue(state,
          attr_value: state.attr_value <> prefix,
          state: state.return_state,
          return_state: nil
        )

      :data ->
        emit_char(state, prefix, state: :data, return_state: nil)
    end
  end

  # Windows-1252 replacements for 0x80-0x9F per HTML5 spec
  @windows_1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  defp finish_numeric_char_ref(state, rest, base) do
    codepoint = String.to_integer(state.buffer, base)

    # Handle special cases per spec
    char =
      cond do
        codepoint == 0 -> <<0xFFFD::utf8>>
        codepoint > 0x10FFFF -> <<0xFFFD::utf8>>
        codepoint >= 0xD800 and codepoint <= 0xDFFF -> <<0xFFFD::utf8>>
        Map.has_key?(@windows_1252, codepoint) -> <<@windows_1252[codepoint]::utf8>>
        true -> <<codepoint::utf8>>
      end

    case state.return_state do
      return_state when is_attribute_value_state(return_state) ->
        continue(state,
          input: rest,
          attr_value: state.attr_value <> char,
          state: state.return_state,
          return_state: nil,
          buffer: ""
        )

      :data ->
        emit_char(state, char, input: rest, state: :data, return_state: nil, buffer: "")
    end
  end

  # --------------------------------------------------------------------------
  # Helper functions
  # --------------------------------------------------------------------------

  defp continue(state, updates) do
    {:continue, struct!(state, updates)}
  end

  @rawtext_elements ~w(style xmp iframe noembed noframes)
  @rcdata_elements ~w(textarea title)

  defp emit(%{token: {:start_tag, "plaintext", _, false}} = state, updates) do
    base_updates = [state: :plaintext, token: nil]
    all_updates = Keyword.merge(base_updates, updates)
    {:emit, state.token, struct!(state, all_updates)}
  end

  defp emit(%{token: {:start_tag, "script", _, false}} = state, updates) do
    base_updates = [state: :script_data, token: nil]
    all_updates = Keyword.merge(base_updates, updates)
    {:emit, state.token, struct!(state, all_updates)}
  end

  defp emit(%{token: {:start_tag, tag, _, false}} = state, updates)
       when tag in @rawtext_elements do
    base_updates = [state: :rawtext, token: nil]
    all_updates = Keyword.merge(base_updates, updates)
    {:emit, state.token, struct!(state, all_updates)}
  end

  defp emit(%{token: {:start_tag, tag, _, false}} = state, updates)
       when tag in @rcdata_elements do
    base_updates = [state: :rcdata, token: nil]
    all_updates = Keyword.merge(base_updates, updates)
    {:emit, state.token, struct!(state, all_updates)}
  end

  defp emit(state, updates) do
    base_updates = [state: :data, token: nil]
    all_updates = Keyword.merge(base_updates, updates)
    {:emit, state.token, struct!(state, all_updates)}
  end

  defp emit_char(state, char, updates) do
    {:emit_char, char, struct!(state, updates)}
  end

  defp append_to_tag_name(%{token: {:start_tag, name, attrs, sc}} = state, char) do
    %{state | token: {:start_tag, name <> char, attrs, sc}}
  end

  defp append_to_tag_name(%{token: {:end_tag, name}} = state, char) do
    %{state | token: {:end_tag, name <> char}}
  end

  defp start_new_attribute(%{token: {:start_tag, _, _, _}} = state, initial_char) do
    %{state | attr_name: initial_char, attr_value: ""}
  end

  defp start_new_attribute(state, _), do: state

  defp finalize_attribute_name(%{token: {:start_tag, _, _, _}} = state) do
    # Move buffer contents to attr_name, clear buffer
    %{state | attr_name: state.attr_name <> state.buffer, buffer: ""}
  end

  defp finalize_attribute_name(state), do: state

  defp finalize_attribute_value(
         %{token: {:start_tag, name, attrs, sc}, attr_name: attr_name, attr_value: attr_value} =
           state
       ) do
    # Add the attribute to the token (only if name is non-empty and not duplicate)
    attrs =
      if attr_name != "" and not Map.has_key?(attrs, attr_name) do
        Map.put(attrs, attr_name, attr_value)
      else
        attrs
      end

    %{state | token: {:start_tag, name, attrs, sc}, attr_name: "", attr_value: ""}
  end

  defp finalize_attribute_value(state), do: state

  defp set_self_closing(%{token: {:start_tag, name, attrs, _}} = state) do
    %{state | token: {:start_tag, name, attrs, true}}
  end

  defp set_self_closing(state), do: state

  defp append_to_doctype_name(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, (name || "") <> char, pub, sys, quirks}}
  end

  defp set_force_quirks(%{token: {:doctype, name, pub, sys, _}} = state) do
    %{state | token: {:doctype, name, pub, sys, true}}
  end

  defp set_force_quirks(state), do: state

  defp set_doctype_public_id(%{token: {:doctype, name, _pub, sys, quirks}} = state, value) do
    %{state | token: {:doctype, name, value, sys, quirks}}
  end

  defp append_to_doctype_public_id(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, name, (pub || "") <> char, sys, quirks}}
  end

  defp set_doctype_system_id(%{token: {:doctype, name, pub, _sys, quirks}} = state, value) do
    %{state | token: {:doctype, name, pub, value, quirks}}
  end

  defp append_to_doctype_system_id(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, name, pub, (sys || "") <> char, quirks}}
  end

  defp append_to_comment(%{token: {:comment, data}} = state, char) do
    %{state | token: {:comment, data <> char}}
  end

  defp maybe_update_last_start_tag(%{token: {:start_tag, name, _, _}} = state) do
    %{state | last_start_tag: name}
  end

  defp maybe_update_last_start_tag(state), do: state

  defp appropriate_end_tag?(%{token: {:end_tag, name}, last_start_tag: last}) do
    name == last
  end

  defp appropriate_end_tag?(_state), do: false

  defp emit_rawtext_buffer(state, rest) do
    emit_char(state, "</" <> state.buffer, state: :rawtext, token: nil, input: rest)
  end

  defp emit_rcdata_buffer(state, rest) do
    emit_char(state, "</" <> state.buffer, state: :rcdata, token: nil, input: rest)
  end

  defp emit_script_buffer(state, rest) do
    emit_char(state, "</" <> state.buffer, state: :script_data, token: nil, input: rest)
  end

  defp flush_char_ref(%{return_state: return_state} = state, chars, rest)
       when is_attribute_value_state(return_state) do
    continue(state,
      input: rest,
      attr_value: state.attr_value <> chars,
      state: return_state,
      return_state: nil
    )
  end

  defp flush_char_ref(state, chars, rest) do
    emit_char(state, chars, input: rest, state: state.return_state, return_state: nil)
  end

  # Per HTML5 spec: in attribute values, legacy entities (no semicolon) followed
  # by = or alphanumeric should NOT be consumed (to preserve URLs like ?a=1&lang=en)
  defp consumable_entity?(return_state, input, rest)
       when is_attribute_value_state(return_state) do
    matched_len = byte_size(input) - byte_size(rest)
    <<matched::binary-size(matched_len), _::binary>> = input
    has_semicolon? = String.ends_with?(matched, ";")

    legacy_follows_problematic_char? =
      case rest do
        <<?=, _::binary>> -> true
        <<c, _::binary>> when is_ascii_digit(c) or is_ascii_alpha(c) -> true
        _ -> false
      end

    has_semicolon? or not legacy_follows_problematic_char?
  end

  defp consumable_entity?(_, _, _), do: true

  # Read characters until we hit one of the stop characters
  # Returns {collected_chars, remaining_input}
  defp chars_until(input, stop_chars) do
    chars_until(input, stop_chars, [])
  end

  defp chars_until(<<c, rest::binary>>, stop_chars, acc) when c < 128 do
    if c in stop_chars do
      {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<c, rest::binary>>}
    else
      chars_until(rest, stop_chars, [c | acc])
    end
  end

  defp chars_until(<<c::utf8, rest::binary>>, stop_chars, acc) do
    # Multi-byte UTF-8 characters are never stop chars
    chars_until(rest, stop_chars, [<<c::utf8>> | acc])
  end

  defp chars_until(<<byte, rest::binary>>, stop_chars, acc) do
    # Invalid UTF-8 byte
    chars_until(rest, stop_chars, [byte | acc])
  end

  defp chars_until("", _stop_chars, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
  end
end
