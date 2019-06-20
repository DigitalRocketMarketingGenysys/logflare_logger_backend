defmodule LogflareLogger.LogParams do
  @moduledoc """
  Parses and encodes incoming Logger messages for further serialization.
  """
  alias LogflareLogger.{Stacktrace, Utils}
  @default_metadata_keys Utils.default_metadata_keys()

  @doc """
  Creates a LogParams struct when all fields have serializable values
  """
  def encode(timestamp, level, message, metadata) do
    new(timestamp, level, message, metadata)
    |> to_payload()
    |> jsonify()
    |> encode_metadata_charlists()
  end

  def new(timestamp, level, message, metadata) do
    log =
      %{
        timestamp: timestamp,
        level: level,
        message: message,
        metadata: metadata
      }
      |> encode_message()
      |> encode_timestamp()
      |> encode_metadata()

    {system_context, user_context} =
      log.metadata
      |> Map.split(@default_metadata_keys)

    log
    |> Map.drop([:metadata])
    |> Map.put(:context, %{
      system: system_context,
      user: user_context
    })
  end

  @doc """
  Encodes message, if is iodata converts to binary.
  """
  def encode_message(%{message: m} = log) do
    %{log | message: to_string(m)}
  end

  @doc """
  Converts erlang datetime tuple into ISO:Extended binary.
  """
  def encode_timestamp(%{timestamp: t} = log) when is_tuple(t) do
    timestamp =
      t
      |> Timex.to_naive_datetime()
      |> Timex.to_datetime(Timex.Timezone.local())
      |> Timex.format!("{ISO:Extended}")

    %{log | timestamp: timestamp}
  end

  def encode_metadata(%{metadata: meta} = log) do
    meta =
      meta
      |> encode_pid()
      |> encode_crash_reason()
      |> traverse_convert()
      |> encode_metadata_charlists()

    %{log | metadata: meta}
  end

  @doc """
  Converts pid to string
  """
  def encode_pid(%{pid: pid} = meta) when is_pid(pid) do
    pid =
      pid
      |> :erlang.pid_to_list()
      |> to_string()

    %{meta | pid: pid}
  end

  def encode_pid(meta), do: meta

  @doc """
  Adds formatted stacktrace to the metadata
  """
  def encode_crash_reason(%{crash_reason: cr} = meta) when not is_nil(cr) do
    {_err, stacktrace} = cr

    meta
    |> Map.drop([:crash_reason])
    |> Map.merge(%{stacktrace: Stacktrace.format(stacktrace)})
  end

  def encode_crash_reason(meta), do: meta

  @doc """
  jsonify deeply converts all keywords to maps and all atoms to strings
  for Logflare server to be able to safely convert binary to terms
  using :erlang.binary_to_term(binary, [:safe])
  """
  def jsonify(log) do
    Iteraptor.jsonify(log, values: true)
  end

  def to_payload(log) do
    metadata =
      %{}
      |> Map.merge(log.context[:user] || %{})
      |> Map.put(:context, log.context[:system] || %{})
      |> encode_metadata_charlists()

    log
    |> Map.put(:metadata, metadata)
    |> Map.drop([:context])
  end

  def encode_metadata_charlists(metadata) do
    case metadata do
      xs when is_map(xs) ->
        for {k, v} <- xs, into: Map.new() do
          v =
            cond do
              is_list(v) and List.ascii_printable?(v) -> to_string(v)
              is_map(v) or is_list(v) -> encode_metadata_charlists(v)
              true -> v
            end

          {k, v}
        end

      xs when is_list(xs) ->
        for x <- xs, do: encode_metadata_charlists(x)

      xs ->
        xs
    end
  end

  def traverse_convert(data) when is_list(data) do
    for x <- data, do: traverse_convert(x)
  end

  def traverse_convert(%{__struct__: _} = v), do: v |> Map.from_struct() |> traverse_convert()

  def traverse_convert(data) when is_map(data) do
    for {k,v} <- data, into: Map.new do
      {k, traverse_convert(v)}
    end
  end

  def traverse_convert(x) when is_tuple(x), do: Tuple.to_list(x) |> traverse_convert()
  def traverse_convert(x), do: x

end
