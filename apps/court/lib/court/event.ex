defmodule Court.Event do
  @moduledoc """
  Persistence-neutral immutable event envelope.

  Actors use `role[/label]`. The closed role roster is `owner`,
  `resident`, `broker`, `scheduler`, `worker`, and `recovery`; labels
  remain open. `resident/<fork-label>` is reserved for future resident
  forks and is only a naming convention in M1.
  """

  @producer_fields [
    :event_type,
    :schema_version,
    :occurred_at,
    :actor,
    :causation_id,
    :correlation_id,
    :resident_id,
    :incarnation_id,
    :session_id,
    :episode_id,
    :segment_id,
    :window_id,
    :tick_id,
    :turn_id,
    :payload,
    :artifact_refs
  ]

  @input_fields [:event_id | @producer_fields]
  @required_fields ~w(event_id event_type schema_version occurred_at actor resident_id incarnation_id payload artifact_refs)a
  @optional_id_fields ~w(correlation_id resident_id incarnation_id session_id episode_id segment_id window_id tick_id turn_id)a
  @roles ~w(owner resident broker scheduler worker recovery)
  @ulid_pattern ~r/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/
  @actor_pattern ~r/^[a-z][a-z0-9_]*(?:\/[A-Za-z0-9][A-Za-z0-9._-]*)?$/
  @event_type_pattern ~r/^[a-z][a-z0-9_]*$/
  @artifact_ref_pattern ~r/^[a-z0-9][a-z0-9_-]*:[0-9a-f]+$/

  @enforce_keys @required_fields
  defstruct [
    :event_seq,
    :recorded_at,
    :event_id,
    :event_type,
    :schema_version,
    :occurred_at,
    :actor,
    :causation_id,
    :correlation_id,
    :resident_id,
    :incarnation_id,
    :session_id,
    :episode_id,
    :segment_id,
    :window_id,
    :tick_id,
    :turn_id,
    payload: %{},
    artifact_refs: []
  ]

  @type t :: %__MODULE__{
          event_seq: pos_integer() | nil,
          recorded_at: DateTime.t() | nil,
          event_id: String.t(),
          event_type: String.t(),
          schema_version: pos_integer(),
          occurred_at: DateTime.t(),
          actor: String.t(),
          causation_id: String.t() | nil,
          correlation_id: String.t() | nil,
          resident_id: String.t(),
          incarnation_id: String.t(),
          session_id: String.t() | nil,
          episode_id: String.t() | nil,
          segment_id: String.t() | nil,
          window_id: String.t() | nil,
          tick_id: String.t() | nil,
          turn_id: String.t() | nil,
          payload: map(),
          artifact_refs: [String.t()]
        }

  @spec normalize(map()) :: {:ok, t()} | {:error, map()}
  def normalize(attrs) when is_map(attrs) do
    {values, errors} = extract_fields(attrs)
    errors = reject_court_fields(attrs, errors)
    {values, errors} = normalize_values(values, errors)

    if map_size(errors) == 0 do
      {:ok, struct!(__MODULE__, values)}
    else
      {:error, errors}
    end
  end

  def normalize(_attrs), do: {:error, %{event: ["must be a map"]}}

  @spec producer_fingerprint(t()) :: String.t()
  def producer_fingerprint(%__MODULE__{} = event) do
    event
    |> Map.take(@producer_fields)
    |> canonicalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec canonicalize(term()) :: term()
  def canonicalize(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def canonicalize(%{} = value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonicalize(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  def canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  def canonicalize(value), do: value

  defp extract_fields(attrs) do
    Enum.reduce(@input_fields, {%{}, %{}}, fn field, {values, errors} ->
      case fetch_field(attrs, field) do
        {:ok, value} ->
          {Map.put(values, field, value), errors}

        :missing when field in @required_fields ->
          {values, add_error(errors, field, "is required")}

        :missing ->
          {Map.put(values, field, nil), errors}

        :duplicate ->
          {values, add_error(errors, field, "was provided twice")}
      end
    end)
  end

  defp fetch_field(attrs, field) do
    string_field = Atom.to_string(field)

    case {Map.fetch(attrs, field), Map.fetch(attrs, string_field)} do
      {{:ok, _}, {:ok, _}} -> :duplicate
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :missing
    end
  end

  defp reject_court_fields(attrs, errors) do
    Enum.reduce([:event_seq, :recorded_at], errors, fn field, acc ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
        add_error(acc, field, "is assigned by the court and cannot be supplied")
      else
        acc
      end
    end)
  end

  defp normalize_values(values, errors) do
    {occurred_at, errors} = normalize_datetime(values[:occurred_at], errors)
    {payload, errors} = normalize_json(values[:payload], :payload, errors)
    errors = validate_ulid(values[:event_id], :event_id, errors)
    errors = validate_optional_ulid(values[:causation_id], :causation_id, errors)

    errors =
      Enum.reduce(@optional_id_fields, errors, fn field, acc ->
        validate_nonempty(values[field], field, acc)
      end)

    errors = validate_event_type(values[:event_type], errors)
    errors = validate_schema_version(values[:schema_version], errors)
    errors = validate_actor(values[:actor], errors)
    errors = validate_artifact_refs(values[:artifact_refs], errors)

    {%{values | occurred_at: occurred_at, payload: payload}, errors}
  end

  defp normalize_datetime(%DateTime{} = value, errors) do
    normalized =
      value
      |> DateTime.to_unix(:microsecond)
      |> DateTime.from_unix!(:microsecond)

    {normalized, errors}
  end

  defp normalize_datetime(_value, errors),
    do: {nil, add_error(errors, :occurred_at, "must be a DateTime")}

  defp normalize_json(value, field, errors) do
    case do_normalize_json(value) do
      {:ok, normalized} -> {normalized, errors}
      {:error, message} -> {%{}, add_error(errors, field, message)}
    end
  end

  defp do_normalize_json(%{} = value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      normalized_key = if is_atom(key) or is_binary(key), do: to_string(key), else: nil

      cond do
        is_nil(normalized_key) ->
          {:halt, {:error, "must contain only string or atom object keys"}}

        Map.has_key?(acc, normalized_key) ->
          {:halt, {:error, "contains keys that collide after canonicalization"}}

        true ->
          case do_normalize_json(item) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, normalized_key, normalized)}}
            {:error, message} -> {:halt, {:error, message}}
          end
      end
    end)
  end

  defp do_normalize_json(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case do_normalize_json(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp do_normalize_json(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp do_normalize_json(_value), do: {:error, "must contain only JSON-compatible values"}

  defp validate_ulid(value, field, errors) do
    if is_binary(value) and Regex.match?(@ulid_pattern, value) and decodes_ulid?(value) do
      errors
    else
      add_error(errors, field, "must be a canonical 26-character ULID")
    end
  end

  defp validate_optional_ulid(nil, _field, errors), do: errors
  defp validate_optional_ulid(value, field, errors), do: validate_ulid(value, field, errors)

  defp decodes_ulid?(value) do
    byte_size(HumbleUlid.decode(value)) == 16
  rescue
    _ -> false
  end

  defp validate_nonempty(nil, field, errors)
       when field in [
              :correlation_id,
              :session_id,
              :episode_id,
              :segment_id,
              :window_id,
              :tick_id,
              :turn_id
            ],
       do: errors

  defp validate_nonempty(value, _field, errors) when is_binary(value) and byte_size(value) > 0,
    do: errors

  defp validate_nonempty(_value, field, errors),
    do: add_error(errors, field, "must be a non-empty string")

  defp validate_event_type(value, errors) when is_binary(value) do
    if Regex.match?(@event_type_pattern, value),
      do: errors,
      else: add_error(errors, :event_type, "must be lower snake case")
  end

  defp validate_event_type(_value, errors),
    do: add_error(errors, :event_type, "must be lower snake case")

  defp validate_schema_version(value, errors) when is_integer(value) and value >= 1, do: errors

  defp validate_schema_version(_value, errors),
    do: add_error(errors, :schema_version, "must be at least 1")

  defp validate_actor(value, errors) when is_binary(value) do
    with true <- Regex.match?(@actor_pattern, value),
         [role | _] <- String.split(value, "/", parts: 2),
         true <- role in @roles do
      errors
    else
      _ -> add_error(errors, :actor, "must use the closed role[/label] actor grammar")
    end
  end

  defp validate_actor(_value, errors),
    do: add_error(errors, :actor, "must use the closed role[/label] actor grammar")

  defp validate_artifact_refs(refs, errors) when is_list(refs) do
    if Enum.all?(refs, &(is_binary(&1) and Regex.match?(@artifact_ref_pattern, &1))) do
      errors
    else
      add_error(errors, :artifact_refs, "must contain algorithm-qualified lowercase hashes")
    end
  end

  defp validate_artifact_refs(_refs, errors),
    do: add_error(errors, :artifact_refs, "must be a list")

  defp add_error(errors, field, message),
    do: Map.update(errors, field, [message], &[message | &1])
end
