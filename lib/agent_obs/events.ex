defmodule AgentObs.Events do
  @moduledoc """
  Defines and validates standardized event schemas for AgentObs.

  This module provides the core event schema that is backend-agnostic and represents
  the contract between instrumentation code and handler implementations.

  ## Event Types

  AgentObs supports four primary event types:

  - `:agent` - Agent loop or invocation tracking
  - `:tool` - Tool call execution tracking
  - `:llm` - LLM API call tracking
  - `:prompt` - Prompt template rendering tracking

  ## Event Phases

  Each event type has three phases:

  - `:start` - Emitted when the operation begins
  - `:stop` - Emitted when the operation completes successfully
  - `:exception` - Emitted when the operation fails

  ## Metadata Structures

  Each event type and phase combination has a standardized metadata structure.
  See individual functions for details.
  """

  @event_types [:agent, :tool, :llm, :prompt]
  @event_phases [:start, :stop, :exception]

  @type event_type :: :agent | :tool | :llm | :prompt
  @type event_phase :: :start | :stop | :exception
  @type metadata :: map()
  @type validation_result :: :ok | {:error, String.t()}

  @doc """
  Validates event metadata for a given event type and phase.

  Returns `:ok` if metadata is valid, `{:error, reason}` otherwise.

  ## Examples

      iex> AgentObs.Events.validate_event(:agent, :start, %{name: "my_agent", input: "task"})
      :ok

      iex> AgentObs.Events.validate_event(:agent, :start, %{name: "my_agent"})
      {:error, "Missing required field: input"}
  """
  @spec validate_event(event_type(), event_phase(), metadata()) :: validation_result()
  def validate_event(event_type, phase, metadata)
      when event_type in @event_types and phase in @event_phases do
    do_validate_event(event_type, phase, metadata)
  end

  def validate_event(event_type, _phase, _metadata) when event_type not in @event_types do
    {:error,
     "Invalid event type: #{inspect(event_type)}. Must be one of #{inspect(@event_types)}"}
  end

  def validate_event(_event_type, phase, _metadata) when phase not in @event_phases do
    {:error, "Invalid event phase: #{inspect(phase)}. Must be one of #{inspect(@event_phases)}"}
  end

  @doc """
  Normalizes event metadata, converting values to standard formats.

  This includes:
  - Converting atom keys to strings where appropriate
  - Normalizing role atoms to strings
  - Ensuring consistent data types

  ## Examples

      iex> AgentObs.Events.normalize_metadata(:llm, :start, %{model: "gpt-4", input_messages: [%{role: :user, content: "Hi"}]})
      %{model: "gpt-4", input_messages: [%{role: "user", content: "Hi"}]}
  """
  @spec normalize_metadata(event_type(), event_phase(), metadata()) :: metadata()
  def normalize_metadata(event_type, phase, metadata)
      when event_type in @event_types and phase in @event_phases do
    do_normalize_metadata(event_type, phase, metadata)
  end

  # Private validation functions

  defp do_validate_event(:agent, :start, metadata) do
    with :ok <- require_field(metadata, :name) do
      require_field(metadata, :input)
    end
  end

  defp do_validate_event(:agent, :stop, metadata) do
    require_field(metadata, :output)
  end

  defp do_validate_event(:agent, :exception, _metadata), do: :ok

  defp do_validate_event(:tool, :start, metadata) do
    with :ok <- require_field(metadata, :name) do
      require_field(metadata, :arguments)
    end
  end

  defp do_validate_event(:tool, :stop, metadata) do
    require_field(metadata, :result)
  end

  defp do_validate_event(:tool, :exception, _metadata), do: :ok

  defp do_validate_event(:llm, :start, metadata) do
    with :ok <- require_field(metadata, :model),
         :ok <- validate_llm_type(metadata) do
      # input_messages is required for chat type
      case Map.get(metadata, :type, "chat") do
        "chat" -> require_field(metadata, :input_messages)
        _ -> :ok
      end
    end
  end

  defp do_validate_event(:llm, :stop, _metadata), do: :ok

  defp do_validate_event(:llm, :exception, _metadata), do: :ok

  defp do_validate_event(:prompt, :start, metadata) do
    with :ok <- require_field(metadata, :name) do
      require_field(metadata, :variables)
    end
  end

  defp do_validate_event(:prompt, :stop, metadata) do
    require_field(metadata, :rendered)
  end

  defp do_validate_event(:prompt, :exception, _metadata), do: :ok

  defp require_field(metadata, field) do
    if Map.has_key?(metadata, field) do
      :ok
    else
      {:error, "Missing required field: #{field}"}
    end
  end

  defp validate_llm_type(metadata) do
    case Map.get(metadata, :type) do
      nil -> :ok
      type when type in ["chat", "completion", "embedding"] -> :ok
      type -> {:error, "Invalid LLM type: #{type}. Must be one of: chat, completion, embedding"}
    end
  end

  # Private normalization functions

  defp do_normalize_metadata(:llm, _phase, metadata) do
    metadata
    |> normalize_messages(:input_messages)
    |> normalize_messages(:output_messages)
  end

  defp do_normalize_metadata(_event_type, _phase, metadata), do: metadata

  defp normalize_messages(metadata, key) do
    case Map.get(metadata, key) do
      nil ->
        metadata

      messages when is_list(messages) ->
        normalized = Enum.map(messages, &normalize_message/1)
        Map.put(metadata, key, normalized)

      _ ->
        metadata
    end
  end

  defp normalize_message(%{role: role} = message) when is_atom(role) do
    %{message | role: to_string(role)}
  end

  defp normalize_message(message), do: message

  @doc """
  Returns the list of supported event types.
  """
  @spec event_types() :: [event_type()]
  def event_types, do: @event_types

  @doc """
  Returns the list of supported event phases.
  """
  @spec event_phases() :: [event_phase()]
  def event_phases, do: @event_phases
end
