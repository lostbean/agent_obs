defmodule AgentObs.Handlers.Phoenix.Translator do
  @moduledoc """
  Translates AgentObs event metadata to OpenInference semantic conventions.

  This module is responsible for converting the backend-agnostic AgentObs event
  metadata into the flattened, indexed attribute format required by OpenInference.

  OpenInference is an extension of OpenTelemetry semantic conventions specifically
  designed for AI and LLM observability. It enables rich, contextualized visualization
  in platforms like Arize Phoenix.

  ## OpenInference Span Kinds

  - `AGENT` - Agent loop or orchestration
  - `LLM` - Large Language Model API call
  - `TOOL` - Tool or function execution
  - `CHAIN` - Sequence of operations (not used in AgentObs currently)
  - `RETRIEVER` - Vector/document retrieval (not used in AgentObs currently)

  ## Key Attributes

  The translator produces flattened attributes following the OpenInference spec:
  - `openinference.span.kind` - The span kind (AGENT, LLM, TOOL, etc.)
  - `input.value` / `output.value` - Primary input/output
  - `llm.model_name` - Model identifier
  - `llm.input_messages.N.message.role` - Message role (user, assistant, etc.)
  - `llm.input_messages.N.message.content` - Message content
  - `llm.token_count.prompt` / `llm.token_count.completion` - Token usage
  - `tool.name` / `tool.description` - Tool metadata

  ## References

  - OpenInference Spec: https://arize-ai.github.io/openinference/spec/semantic_conventions.html
  - Arize Phoenix Docs: https://arize.com/docs/phoenix/
  """

  @doc """
  Translates start event metadata to OpenInference attributes.

  ## Parameters

  - `event_type` - One of `:agent`, `:tool`, `:llm`, `:prompt`
  - `metadata` - The start metadata from AgentObs event

  ## Returns

  A map of OpenInference attributes (string keys, primitive values).
  """
  @spec from_start_metadata(atom(), map()) :: map()
  def from_start_metadata(:agent, metadata) do
    %{
      "openinference.span.kind" => "AGENT",
      "input.value" => to_json_safe(metadata.input),
      "input.mime_type" => "text/plain"
    }
    |> maybe_add("llm.model_name", metadata[:model])
    |> maybe_add("session.id", metadata[:session_id])
    |> maybe_add("user.id", metadata[:user_id])
    |> maybe_add_metadata(metadata[:metadata])
  end

  def from_start_metadata(:tool, metadata) do
    %{
      "openinference.span.kind" => "TOOL",
      "tool.name" => metadata.name
    }
    |> maybe_add("tool.description", metadata[:description])
    |> add_tool_arguments(metadata[:arguments])
  end

  def from_start_metadata(:llm, metadata) do
    %{
      "openinference.span.kind" => "LLM",
      "llm.model_name" => metadata.model,
      # Add gen_ai attributes for compatibility
      "gen_ai.system" => extract_provider(metadata.model),
      "gen_ai.request.model" => metadata.model
    }
    |> maybe_add("llm.invocation_parameters", encode_invocation_parameters(metadata))
    |> maybe_add("ai.operationId", "ai.generateText.doGenerate")
    |> maybe_add("ai.model.id", metadata.model)
    |> maybe_add("ai.model.provider", extract_provider(metadata.model))
    |> Map.merge(flatten_input_messages(metadata[:input_messages]))
  end

  def from_start_metadata(:prompt, metadata) do
    %{
      "openinference.span.kind" => "CHAIN",
      "input.value" => to_json_safe(metadata.variables)
    }
    |> maybe_add("llm.prompt_template.template", metadata[:template])
    |> maybe_add("llm.prompt_template.variables", encode_json(metadata.variables))
  end

  @doc """
  Translates stop event metadata to OpenInference attributes.

  ## Parameters

  - `event_type` - One of `:agent`, `:tool`, `:llm`, `:prompt`
  - `metadata` - The stop metadata from AgentObs event
  - `measurements` - Measurements map containing duration

  ## Returns

  A map of OpenInference attributes to be added to the span.
  """
  @spec from_stop_metadata(atom(), map(), map()) :: map()
  def from_stop_metadata(:agent, metadata, measurements) do
    %{
      "output.value" => to_json_safe(metadata[:output]),
      "output.mime_type" => "text/plain"
    }
    |> add_tools_used(metadata[:tools_used])
    |> maybe_add("agent.iterations", metadata[:iterations])
    |> maybe_add("llm.token_count.total", get_in(metadata, [:tokens, :total]))
    |> maybe_add("llm.token_count.prompt", get_in(metadata, [:tokens, :prompt]))
    |> maybe_add("llm.token_count.completion", get_in(metadata, [:tokens, :completion]))
    |> maybe_add("llm.cost.total", metadata[:cost])
    |> add_duration(measurements)
  end

  def from_stop_metadata(:tool, metadata, measurements) do
    %{
      "output.value" => to_json_safe(metadata[:result])
    }
    |> add_duration(measurements)
  end

  def from_stop_metadata(:llm, metadata, measurements) do
    %{}
    |> Map.merge(flatten_output_messages(metadata[:output_messages]))
    |> maybe_add("llm.token_count.prompt", get_in(metadata, [:tokens, :prompt]))
    |> maybe_add("llm.token_count.completion", get_in(metadata, [:tokens, :completion]))
    |> maybe_add("llm.token_count.total", get_in(metadata, [:tokens, :total]))
    |> maybe_add("llm.cost.total", metadata[:cost])
    |> maybe_add("output.value", metadata[:finish_reason])
    # Add gen_ai usage attributes
    |> maybe_add("gen_ai.usage.input_tokens", get_in(metadata, [:tokens, :prompt]))
    |> maybe_add("gen_ai.usage.output_tokens", get_in(metadata, [:tokens, :completion]))
    |> maybe_add(
      "gen_ai.response.finish_reasons",
      metadata[:finish_reason] && [metadata[:finish_reason]]
    )
    |> add_duration(measurements)
  end

  def from_stop_metadata(:prompt, metadata, measurements) do
    %{
      "output.value" => to_json_safe(metadata[:rendered])
    }
    |> add_duration(measurements)
  end

  @doc """
  Translates exception event metadata to OpenInference attributes.

  ## Parameters

  - `event_type` - One of `:agent`, `:tool`, `:llm`, `:prompt`
  - `metadata` - The exception metadata from telemetry
  - `measurements` - Measurements map containing duration

  ## Returns

  A map of OpenInference attributes for the exception.
  """
  @spec from_exception_metadata(atom(), map(), map()) :: map()
  def from_exception_metadata(_event_type, metadata, measurements) do
    kind = metadata[:kind] || :error
    reason = metadata[:reason]
    stacktrace = metadata[:stacktrace] || []

    %{
      "exception.type" => exception_type(kind, reason),
      "exception.message" => exception_message(reason),
      "exception.escaped" => false
    }
    |> maybe_add("exception.stacktrace", format_stacktrace(stacktrace))
    |> add_duration(measurements)
  end

  # Private helper functions

  defp flatten_input_messages(nil), do: %{}

  defp flatten_input_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {msg, idx}, acc ->
      acc
      |> Map.put("llm.input_messages.#{idx}.message.role", to_string(msg.role))
      |> maybe_add(
        "llm.input_messages.#{idx}.message.content",
        get_message_field(msg, :content) && to_string(get_message_field(msg, :content))
      )
      |> maybe_add_tool_calls("llm.input_messages.#{idx}", get_message_field(msg, :tool_calls))
    end)
  end

  defp flatten_output_messages(nil), do: %{}

  defp flatten_output_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {msg, idx}, acc ->
      acc
      |> Map.put("llm.output_messages.#{idx}.message.role", to_string(msg.role))
      |> maybe_add(
        "llm.output_messages.#{idx}.message.content",
        get_message_field(msg, :content) && to_string(get_message_field(msg, :content))
      )
      |> maybe_add_tool_calls("llm.output_messages.#{idx}", get_message_field(msg, :tool_calls))
    end)
  end

  defp maybe_add_tool_calls(attrs, _prefix, nil), do: attrs

  defp maybe_add_tool_calls(attrs, prefix, tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Enum.reduce(attrs, fn {tool_call, idx}, acc ->
      tool_prefix = "#{prefix}.message.tool_calls.#{idx}.tool_call"

      # Handle both map-based and struct-based tool calls
      function_name = get_tool_call_field(tool_call, :name)
      function_args = get_tool_call_field(tool_call, :arguments)

      acc
      |> maybe_add("#{tool_prefix}.function.name", function_name)
      |> maybe_add("#{tool_prefix}.function.arguments", encode_json(function_args))
    end)
  end

  defp add_tool_arguments(attrs, nil), do: attrs

  defp add_tool_arguments(attrs, arguments) when is_map(arguments) do
    Map.put(attrs, "tool.parameters", encode_json(arguments))
  end

  defp add_tool_arguments(attrs, arguments) when is_binary(arguments) do
    Map.put(attrs, "tool.parameters", arguments)
  end

  # Helper to add tools_used as a proper array (not JSON string)
  defp add_tools_used(attrs, nil), do: attrs

  defp add_tools_used(attrs, tools) when is_list(tools) do
    # Add each tool with an index for proper OpenInference format
    tools
    |> Enum.with_index()
    |> Enum.reduce(attrs, fn {tool, idx}, acc ->
      Map.put(acc, "agent.tools_used.#{idx}", to_string(tool))
    end)
  end

  defp add_tools_used(attrs, _), do: attrs

  defp encode_invocation_parameters(metadata) do
    params =
      metadata
      |> Map.take([
        :temperature,
        :max_tokens,
        :top_p,
        :top_k,
        :frequency_penalty,
        :presence_penalty
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(params) > 0 do
      encode_json(params)
    else
      nil
    end
  end

  defp add_duration(attrs, measurements) do
    case Map.get(measurements, :duration) do
      nil ->
        attrs

      duration when is_integer(duration) ->
        # Convert nanoseconds to milliseconds
        duration_ms = duration / 1_000_000
        Map.put(attrs, "latency_ms", duration_ms)

      _ ->
        attrs
    end
  end

  defp maybe_add(attrs, _key, nil), do: attrs
  defp maybe_add(attrs, key, value), do: Map.put(attrs, key, value)

  defp maybe_add_metadata(attrs, nil), do: attrs

  defp maybe_add_metadata(attrs, metadata) when is_map(metadata) do
    metadata
    |> Enum.reduce(attrs, fn {key, value}, acc ->
      Map.put(acc, "metadata.#{key}", to_json_safe(value))
    end)
  end

  defp to_json_safe(value) when is_binary(value), do: value
  defp to_json_safe(value) when is_number(value), do: value
  defp to_json_safe(value) when is_boolean(value), do: value
  defp to_json_safe(value) when is_atom(value), do: to_string(value)
  defp to_json_safe(value) when is_map(value) or is_list(value), do: encode_json(value)
  defp to_json_safe(nil), do: nil

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  # Helper to safely access message fields (handles both maps and structs)
  defp get_message_field(msg, field) when is_map(msg) do
    # Try struct field access first, then map access
    case Map.get(msg, field) do
      nil ->
        nil

      # Handle ContentPart list - extract text content
      value when is_list(value) and field == :content ->
        extract_text_content(value)

      value ->
        value
    end
  end

  # Extract text from ContentPart structs or list of plain strings
  # Note: Only called when value is a list (see guard on line 329)
  defp extract_text_content([]), do: nil

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{type: :text, text: text} -> text
      %{text: text} -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> case do
      "" -> nil
      text -> text
    end
  end

  # Helper to safely access tool call fields (handles both maps and structs)
  # Supports both flat format (name/arguments) and nested format (function: %{name, arguments})
  defp get_tool_call_field(tool_call, field) when is_map(tool_call) do
    case Map.get(tool_call, field) do
      nil ->
        # Try nested function format (OpenAI-style)
        case Map.get(tool_call, :function) do
          %{} = func -> Map.get(func, field)
          _ -> nil
        end

      value ->
        value
    end
  end

  defp exception_type(_kind, reason) when is_exception(reason) do
    reason.__struct__ |> Module.split() |> List.last()
  end

  defp exception_type(kind, _reason), do: to_string(kind)

  defp exception_message(%{message: message}), do: message

  defp exception_message(reason) when is_exception(reason) do
    Exception.message(reason)
  end

  defp exception_message(reason) when is_binary(reason), do: reason
  defp exception_message(reason), do: inspect(reason)

  defp format_stacktrace([]), do: nil

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    Enum.map_join(stacktrace, "\n", fn
      {module, function, arity, location} ->
        file = Keyword.get(location, :file, "unknown")
        line = Keyword.get(location, :line, 0)
        "#{format_module_name(module)}.#{function}/#{arity} (#{file}:#{line})"

      {module, function, arity} ->
        "#{format_module_name(module)}.#{function}/#{arity}"

      other ->
        inspect(other)
    end)
  end

  defp format_stacktrace(_), do: nil

  defp format_module_name(module) when is_atom(module) do
    module
    |> to_string()
    |> String.trim_leading("Elixir.")
  end

  defp format_module_name(module), do: to_string(module)

  # Extract provider from model string (e.g., "anthropic:claude-3" -> "anthropic")
  defp extract_provider(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model] ->
        provider

      [model] ->
        cond do
          String.starts_with?(model, "gpt-") -> "openai"
          String.starts_with?(model, "claude-") -> "anthropic"
          String.contains?(model, "gemini") -> "google"
          true -> "unknown"
        end
    end
  end

  defp extract_provider(_), do: "unknown"
end
