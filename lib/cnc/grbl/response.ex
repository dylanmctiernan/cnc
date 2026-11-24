defmodule CNC.Grbl.Response do
  @moduledoc """
  Classify one line received from the controller.
  """

  alias CNC.Grbl.Status

  @type t ::
          :ok
          | {:error, non_neg_integer}
          | {:alarm, non_neg_integer}
          | {:status, Status.t()}
          | {:msg, binary}
          | {:banner, binary}
          | {:unknown, binary}

  @doc """
  Parse a line. Trailing `\\r`/`\\n` are ignored. Anything unrecognised,
  including malformed known forms, comes back as `{:unknown, line}`.
  """
  @spec parse(binary) :: t
  def parse(line) do
    line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
    classify(line) || {:unknown, line}
  end

  defp classify("ok"), do: :ok
  defp classify("error:" <> code), do: code_of(code, :error)
  defp classify("ALARM:" <> code), do: code_of(code, :alarm)
  defp classify("[MSG:" <> rest), do: bracketed(rest, &{:msg, &1})
  defp classify("Grbl" <> _ = line), do: {:banner, line}

  defp classify("<" <> rest) do
    with {:ok, body} <- strip_suffix(rest, ">"),
         {:ok, status} <- Status.parse(body) do
      {:status, status}
    else
      :error -> nil
    end
  end

  defp classify(_), do: nil

  # Some firmwares append a description after the code ("error:20 (Unsupported command)").
  defp code_of(s, tag) do
    case Integer.parse(s) do
      {n, rest} when n >= 0 and (rest == "" or binary_part(rest, 0, 1) == " ") -> {tag, n}
      _ -> nil
    end
  end

  defp bracketed(rest, wrap) do
    case strip_suffix(rest, "]") do
      {:ok, body} -> wrap.(body)
      :error -> nil
    end
  end

  defp strip_suffix(s, suffix) do
    if String.ends_with?(s, suffix),
      do: {:ok, binary_part(s, 0, byte_size(s) - byte_size(suffix))},
      else: :error
  end
end
