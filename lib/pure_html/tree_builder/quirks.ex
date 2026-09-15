defmodule PureHTML.TreeBuilder.Quirks do
  @moduledoc """
  The document mode a DOCTYPE token selects.

  The lists are the initial insertion mode's, fetched from the standard on
  2026-09-15. Identifiers compare ASCII case-insensitively, and an empty
  system identifier is not missing for the quirks-only-without-system rows.
  """

  @quirks_public_ids [
    "-//W3O//DTD W3 HTML Strict 3.0//EN//",
    "-/W3C/DTD HTML 4.0 Transitional/EN",
    "HTML"
  ]

  @quirks_system_ids ["http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"]

  @quirks_public_prefixes [
    "+//Silmaril//dtd html Pro v0r11 19970101//",
    "-//AS//DTD HTML 3.0 asWedit + extensions//",
    "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",
    "-//IETF//DTD HTML 2.0 Level 1//",
    "-//IETF//DTD HTML 2.0 Level 2//",
    "-//IETF//DTD HTML 2.0 Strict Level 1//",
    "-//IETF//DTD HTML 2.0 Strict Level 2//",
    "-//IETF//DTD HTML 2.0 Strict//",
    "-//IETF//DTD HTML 2.0//",
    "-//IETF//DTD HTML 2.1E//",
    "-//IETF//DTD HTML 3.0//",
    "-//IETF//DTD HTML 3.2 Final//",
    "-//IETF//DTD HTML 3.2//",
    "-//IETF//DTD HTML 3//",
    "-//IETF//DTD HTML Level 0//",
    "-//IETF//DTD HTML Level 1//",
    "-//IETF//DTD HTML Level 2//",
    "-//IETF//DTD HTML Level 3//",
    "-//IETF//DTD HTML Strict Level 0//",
    "-//IETF//DTD HTML Strict Level 1//",
    "-//IETF//DTD HTML Strict Level 2//",
    "-//IETF//DTD HTML Strict Level 3//",
    "-//IETF//DTD HTML Strict//",
    "-//IETF//DTD HTML//",
    "-//Metrius//DTD Metrius Presentational//",
    "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
    "-//Microsoft//DTD Internet Explorer 2.0 HTML//",
    "-//Microsoft//DTD Internet Explorer 2.0 Tables//",
    "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",
    "-//Microsoft//DTD Internet Explorer 3.0 HTML//",
    "-//Microsoft//DTD Internet Explorer 3.0 Tables//",
    "-//Netscape Comm. Corp.//DTD HTML//",
    "-//Netscape Comm. Corp.//DTD Strict HTML//",
    "-//O'Reilly and Associates//DTD HTML 2.0//",
    "-//O'Reilly and Associates//DTD HTML Extended 1.0//",
    "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
    "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",
    "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//",
    "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",
    "-//Spyglass//DTD HTML 2.0 Extended//",
    "-//Sun Microsystems Corp.//DTD HotJava HTML//",
    "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
    "-//W3C//DTD HTML 3 1995-03-24//",
    "-//W3C//DTD HTML 3.2 Draft//",
    "-//W3C//DTD HTML 3.2 Final//",
    "-//W3C//DTD HTML 3.2//",
    "-//W3C//DTD HTML 3.2S Draft//",
    "-//W3C//DTD HTML 4.0 Frameset//",
    "-//W3C//DTD HTML 4.0 Transitional//",
    "-//W3C//DTD HTML Experimental 19960712//",
    "-//W3C//DTD HTML Experimental 970421//",
    "-//W3C//DTD W3 HTML//",
    "-//W3O//DTD W3 HTML 3.0//",
    "-//WebTechs//DTD Mozilla HTML 2.0//",
    "-//WebTechs//DTD Mozilla HTML//"
  ]

  # Quirks only when the system identifier is missing or empty; with one
  # present they are limited-quirks instead.
  @html401_prefixes ["-//W3C//DTD HTML 4.01 Frameset//", "-//W3C//DTD HTML 4.01 Transitional//"]

  @limited_quirks_public_prefixes [
    "-//W3C//DTD XHTML 1.0 Frameset//",
    "-//W3C//DTD XHTML 1.0 Transitional//"
  ]

  # Compared lowercase against lowercased identifiers.
  @quirks_public_ids_lower Enum.map(@quirks_public_ids, &String.downcase/1)
  @quirks_system_ids_lower Enum.map(@quirks_system_ids, &String.downcase/1)
  @quirks_public_prefixes_lower Enum.map(@quirks_public_prefixes, &String.downcase/1)
  @html401_prefixes_lower Enum.map(@html401_prefixes, &String.downcase/1)
  @limited_quirks_public_prefixes_lower Enum.map(
                                          @limited_quirks_public_prefixes,
                                          &String.downcase/1
                                        )

  @type mode :: :quirks | :limited_quirks | :no_quirks

  @doc """
  The mode for a DOCTYPE token's name, public identifier, system identifier,
  and force-quirks flag. Missing identifiers are `nil`.
  """
  @spec mode(String.t() | nil, String.t() | nil, String.t() | nil, boolean()) :: mode()
  def mode(_name, _public_id, _system_id, true = _force_quirks), do: :quirks
  def mode("html", public_id, system_id, false), do: identifiers_mode(public_id, system_id)
  def mode(_name, _public_id, _system_id, false), do: :quirks

  defp identifiers_mode(public_id, system_id) do
    public = downcase(public_id)
    system = downcase(system_id)

    cond do
      quirks?(public, system) -> :quirks
      limited_quirks?(public, system) -> :limited_quirks
      true -> :no_quirks
    end
  end

  defp quirks?(public, system) do
    public in @quirks_public_ids_lower or
      system in @quirks_system_ids_lower or
      starts_with_any?(public, @quirks_public_prefixes_lower) or
      (system in [nil, ""] and starts_with_any?(public, @html401_prefixes_lower))
  end

  defp limited_quirks?(public, system) do
    starts_with_any?(public, @limited_quirks_public_prefixes_lower) or
      (system not in [nil, ""] and starts_with_any?(public, @html401_prefixes_lower))
  end

  defp starts_with_any?(nil, _prefixes), do: false
  defp starts_with_any?(value, prefixes), do: String.starts_with?(value, prefixes)

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)
end
