defmodule AgentObs.ReqLLM do
  @moduledoc """
  High-level helpers for instrumenting ReqLLM streaming operations with AgentObs.

  This module provides automatic instrumentation wrappers around ReqLLM's streaming API,
  eliminating the need for manual telemetry instrumentation when using ReqLLM.

  ## Installation

  Add `:req_llm` as a dependency in your `mix.exs`:

      def deps do
        [
          {:agent_obs, "~> 0.1"},
          {:req_llm, "~> 1.0.0-rc.7"}
        ]
      end

  ## Features

  - Automatic LLM call instrumentation:
    - `trace_generate_text/3` - Non-streaming text generation
    - `trace_generate_text!/3` - Non-streaming text generation (bang variant)
    - `trace_stream_text/3` - Streaming text generation
    - `trace_generate_object/4` - Non-streaming structured data generation
    - `trace_generate_object!/4` - Non-streaming structured data (bang variant)
    - `trace_stream_object/4` - Streaming structured data generation
  - Automatic tool execution instrumentation with `trace_tool_execution/3`
  - Token usage extraction from all response types
  - Tool call parsing and extraction
  - Seamless integration with ReqLLM's API

  ## Usage

  ### Non-Streaming Text Generation

      {:ok, response} =
        AgentObs.ReqLLM.trace_generate_text(
          "anthropic:claude-3-5-sonnet",
          [%{role: "user", content: "Hello!"}]
        )

      text = ReqLLM.Response.text(response)
      usage = ReqLLM.Response.usage(response)

  ### Non-Streaming Structured Data Generation

      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]

      {:ok, response} =
        AgentObs.ReqLLM.trace_generate_object(
          "anthropic:claude-3-5-sonnet",
          [%{role: "user", content: "Generate a person"}],
          schema
        )

      object = ReqLLM.Response.object(response)
      #=> %{name: "John Doe", age: 30}

  ### Basic Streaming with Instrumentation

      {:ok, stream_response} =
        AgentObs.ReqLLM.trace_stream_text(
          "anthropic:claude-3-5-sonnet",
          [%{role: "user", content: "Hello!"}]
        )

      # Stream output in real-time
      stream_response.stream
      |> Stream.filter(&(&1.type == :content))
      |> Stream.each(&IO.write(&1.text))
      |> Stream.run()

      # Get metadata (automatically instrumented)
      tokens = ReqLLM.StreamResponse.usage(stream_response)

  ### With Tool Calls

      tools = [
        ReqLLM.Tool.new!(
          name: "calculator",
          description: "Perform calculations",
          parameter_schema: [expression: [type: :string, required: true]],
          callback: &calculator/1
        )
      ]

      {:ok, stream_response} =
        AgentObs.ReqLLM.trace_stream_text(
          "anthropic:claude-3-5-sonnet",
          [%{role: "user", content: "What is 2 + 2?"}],
          tools: tools
        )

      # Extract and execute tool calls with instrumentation
      tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

      Enum.each(tool_calls, fn tool_call ->
        tool = Enum.find(tools, & &1.name == tool_call.name)
        {:ok, result} = AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)
      end)

  ### Complete Agent Loop Example

      defmodule MyAgent do
        def chat(model, message, tools) do
          AgentObs.trace_agent("my_agent", %{input: message}, fn ->
            # First LLM call with instrumentation
            {:ok, stream_response} =
              AgentObs.ReqLLM.trace_stream_text(model,
                [%{role: "user", content: message}],
                tools: tools
              )

            # Collect text and tool calls
            text = ReqLLM.StreamResponse.text(stream_response)
            tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

            # Execute tools if any
            tool_results = Enum.map(tool_calls, fn tc ->
              tool = Enum.find(tools, & &1.name == tc.name)
              AgentObs.ReqLLM.trace_tool_execution(tool, tc)
            end)

            {:ok, text, %{
              tools_used: Enum.map(tool_calls, & &1.name),
              iterations: if(tool_calls == [], do: 1, else: 2)
            }}
          end)
        end
      end

  ## Comparison with Manual Instrumentation

  ### Without AgentObs.ReqLLM (manual):

      AgentObs.trace_llm(model, %{input_messages: messages}, fn ->
        case ReqLLM.stream_text(model, messages) do
          {:ok, stream_response} ->
            # Manually extract metadata
            chunks = Enum.to_list(stream_response.stream)
            text = chunks |> Enum.filter(&(&1.type == :content)) |> Enum.map_join("", & &1.text)
            tokens = ReqLLM.StreamResponse.usage(stream_response)
            tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

            {:ok, text, %{
              output_messages: [%{role: "assistant", content: text}],
              tokens: tokens,
              tool_calls: tool_calls
            }}
        end
      end)

  ### With AgentObs.ReqLLM (automatic):

      {:ok, stream_response} =
        AgentObs.ReqLLM.trace_stream_text(model, messages)

      # All metadata automatically captured in telemetry!

  ## Important Notes

  - This module requires `:req_llm` to be available at runtime
  - Instrumentation happens automatically - spans are created for each LLM/tool call
  - Token usage is extracted after stream completion (non-blocking during streaming)
  - Compatible with all ReqLLM providers (Anthropic, OpenAI, Google, etc.)

  ## See Also

  - `ReqLLM.stream_text/3` - The underlying streaming function
  - `ReqLLM.StreamResponse` - Stream response structure
  - `AgentObs.trace_llm/3` - Low-level LLM instrumentation
  - `AgentObs.trace_tool/3` - Low-level tool instrumentation
  """

  alias ReqLLM.StreamResponse.MetadataHandle

  @doc """
  Wraps `ReqLLM.generate_text/3` with automatic AgentObs instrumentation.

  Instruments the LLM text generation call and automatically extracts token usage,
  output messages, and other metadata for observability. This is the non-streaming
  version that returns a complete response.

  ## Parameters

  - `model` - Model specification (string like "anthropic:claude-3-5-sonnet" or Model struct)
  - `messages` - List of message maps or Context
  - `opts` - Options passed to `ReqLLM.generate_text/3` (tools, temperature, etc.)

  ## Returns

  - `{:ok, response}` - ReqLLM.Response with full metadata
  - `{:error, reason}` - Error from ReqLLM

  ## Examples

      # Basic usage
      {:ok, response} = AgentObs.ReqLLM.trace_generate_text(
        "anthropic:claude-3-5-sonnet",
        [%{role: "user", content: "Hello!"}]
      )

      # Extract text from response
      text = ReqLLM.Response.text(response)

      # Access usage metadata
      usage = ReqLLM.Response.usage(response)

  ## Telemetry

  This function emits standard AgentObs LLM events:
  - `[:agent_obs, :llm, :start]` - When generation begins
  - `[:agent_obs, :llm, :stop]` - When generation completes (with tokens)
  - `[:agent_obs, :llm, :exception]` - If an error occurs
  """
  @spec trace_generate_text(term(), list() | struct(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def trace_generate_text(model, messages, opts \\ []) do
    model_string = normalize_model_string(model)
    messages_list = normalize_messages(messages)

    result =
      AgentObs.trace_llm(model_string, %{input_messages: messages_list, type: "chat"}, fn ->
        case ReqLLM.generate_text(model, messages, opts) do
          {:ok, response} ->
            # Extract metadata from response
            text = ReqLLM.Response.text(response)
            usage = ReqLLM.Response.usage(response)

            tokens = %{
              prompt: Map.get(usage, :input_tokens, 0) || 0,
              completion: Map.get(usage, :output_tokens, 0) || 0,
              total:
                (Map.get(usage, :input_tokens, 0) || 0) + (Map.get(usage, :output_tokens, 0) || 0)
            }

            output_messages = [%{role: "assistant", content: text}]

            {:ok, response,
             %{
               output_messages: output_messages,
               tokens: tokens,
               finish_reason: Map.get(response, :finish_reason)
             }}

          {:error, error} ->
            {:error, error}
        end
      end)

    case result do
      {:ok, response, _metadata} ->
        {:ok, response}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Wraps `ReqLLM.generate_text!/3` with automatic AgentObs instrumentation.

  Like `trace_generate_text/3` but raises on error and returns only the text content.
  This is a convenience function for simple use cases where you only need the text.

  ## Parameters

  - `model` - Model specification (string like "anthropic:claude-3-5-sonnet" or Model struct)
  - `messages` - List of message maps or Context
  - `opts` - Options passed to `ReqLLM.generate_text!/3` (tools, temperature, etc.)

  ## Returns

  - Text string from the LLM response
  - Raises on error

  ## Examples

      text = AgentObs.ReqLLM.trace_generate_text!(
        "anthropic:claude-3-5-sonnet",
        [%{role: "user", content: "Hello!"}]
      )
      #=> "Hello! How can I assist you today?"

  ## Telemetry

  This function emits standard AgentObs LLM events:
  - `[:agent_obs, :llm, :start]` - When generation begins
  - `[:agent_obs, :llm, :stop]` - When generation completes (with tokens)
  - `[:agent_obs, :llm, :exception]` - If an error occurs
  """
  @spec trace_generate_text!(term(), list() | struct(), keyword()) :: String.t()
  def trace_generate_text!(model, messages, opts \\ []) do
    case trace_generate_text(model, messages, opts) do
      {:ok, response} ->
        ReqLLM.Response.text(response)

      {:error, error} ->
        raise "ReqLLM.generate_text! failed: #{inspect(error)}"
    end
  end

  @doc """
  Wraps `ReqLLM.generate_object/4` with automatic AgentObs instrumentation.

  Instruments structured data generation with schema validation and automatically
  extracts token usage, output object, and other metadata for observability.

  ## Parameters

  - `model` - Model specification (string like "anthropic:claude-3-5-sonnet" or Model struct)
  - `messages` - List of message maps or Context
  - `schema` - Schema definition for structured output (keyword list or map)
  - `opts` - Options passed to `ReqLLM.generate_object/4` (output, mode, etc.)

  ## Returns

  - `{:ok, response}` - ReqLLM.Response with full metadata and structured object
  - `{:error, reason}` - Error from ReqLLM

  ## Examples

      # Basic usage
      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]

      {:ok, response} = AgentObs.ReqLLM.trace_generate_object(
        "anthropic:claude-3-5-sonnet",
        [%{role: "user", content: "Generate a person named Alice, age 30"}],
        schema
      )

      # Extract object from response
      object = ReqLLM.Response.object(response)
      #=> %{name: "Alice", age: 30}

  ## Telemetry

  This function emits standard AgentObs LLM events:
  - `[:agent_obs, :llm, :start]` - When generation begins
  - `[:agent_obs, :llm, :stop]` - When generation completes (with tokens and object)
  - `[:agent_obs, :llm, :exception]` - If an error occurs
  """
  @spec trace_generate_object(term(), list() | struct(), keyword() | map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def trace_generate_object(model, messages, schema, opts \\ []) do
    model_string = normalize_model_string(model)
    messages_list = normalize_messages(messages)

    result =
      AgentObs.trace_llm(
        model_string,
        %{input_messages: messages_list, type: "chat", schema: schema},
        fn ->
          case ReqLLM.generate_object(model, messages, schema, opts) do
            {:ok, response} ->
              # Extract metadata from response
              object = ReqLLM.Response.object(response)
              usage = ReqLLM.Response.usage(response)

              tokens = %{
                prompt: Map.get(usage, :input_tokens, 0) || 0,
                completion: Map.get(usage, :output_tokens, 0) || 0,
                total:
                  (Map.get(usage, :input_tokens, 0) || 0) +
                    (Map.get(usage, :output_tokens, 0) || 0)
              }

              output_messages = [%{role: "assistant", content: object}]

              {:ok, response,
               %{
                 output_messages: output_messages,
                 tokens: tokens,
                 object: object,
                 finish_reason: Map.get(response, :finish_reason)
               }}

            {:error, error} ->
              {:error, error}
          end
        end
      )

    case result do
      {:ok, response, _metadata} ->
        {:ok, response}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Wraps `ReqLLM.generate_object!/4` with automatic AgentObs instrumentation.

  Like `trace_generate_object/4` but raises on error and returns only the object.
  This is a convenience function for simple use cases where you only need the object.

  ## Parameters

  - `model` - Model specification (string like "anthropic:claude-3-5-sonnet" or Model struct)
  - `messages` - List of message maps or Context
  - `schema` - Schema definition for structured output (keyword list or map)
  - `opts` - Options passed to `ReqLLM.generate_object!/4` (output, mode, etc.)

  ## Returns

  - Structured object matching the schema
  - Raises on error

  ## Examples

      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]

      object = AgentObs.ReqLLM.trace_generate_object!(
        "anthropic:claude-3-5-sonnet",
        [%{role: "user", content: "Generate a person"}],
        schema
      )
      #=> %{name: "John Doe", age: 30}

  ## Telemetry

  This function emits standard AgentObs LLM events:
  - `[:agent_obs, :llm, :start]` - When generation begins
  - `[:agent_obs, :llm, :stop]` - When generation completes (with tokens and object)
  - `[:agent_obs, :llm, :exception]` - If an error occurs
  """
  @spec trace_generate_object!(term(), list() | struct(), keyword() | map(), keyword()) :: map()
  def trace_generate_object!(model, messages, schema, opts \\ []) do
    case trace_generate_object(model, messages, schema, opts) do
      {:ok, response} ->
        ReqLLM.Response.object(response)

      {:error, error} ->
        raise "ReqLLM.generate_object! failed: #{inspect(error)}"
    end
  end

  @doc """
  Wraps `ReqLLM.stream_text/3` with automatic AgentObs instrumentation.

  Instruments the LLM streaming call and automatically extracts token usage,
  tool calls, and other metadata for observability.

  ## Parameters

  - `model` - Model specification (string like "anthropic:claude-3-5-sonnet" or Model struct)
  - `messages` - List of message maps or Context
  - `opts` - Options passed to `ReqLLM.stream_text/3` (tools, temperature, etc.)

  ## Returns

  - `{:ok, stream_response}` - ReqLLM.StreamResponse with instrumentation
  - `{:error, reason}` - Error from ReqLLM

  ## Examples

      # Basic usage
      {:ok, response} = AgentObs.ReqLLM.trace_stream_text(
        "anthropic:claude-3-5-sonnet",
        [%{role: "user", content: "Hello!"}]
      )

      # With tools
      {:ok, response} = AgentObs.ReqLLM.trace_stream_text(
        "anthropic:claude-3-5-sonnet",
        messages,
        tools: [calculator_tool, search_tool]
      )

      # Stream the response
      response.stream
      |> Stream.filter(&(&1.type == :content))
      |> Stream.each(&IO.write(&1.text))
      |> Stream.run()

  ## Telemetry

  This function emits standard AgentObs LLM events:
  - `[:agent_obs, :llm, :start]` - When streaming begins
  - `[:agent_obs, :llm, :stop]` - When streaming completes (with tokens)
  - `[:agent_obs, :llm, :exception]` - If an error occurs
  """
  @spec trace_stream_text(term(), list() | struct(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def trace_stream_text(model, messages, opts \\ []) do
    model_string = normalize_model_string(model)

    # Extract messages list for metadata
    messages_list = normalize_messages(messages)

    # Instrument the LLM call
    result =
      AgentObs.trace_llm(model_string, %{input_messages: messages_list, type: "chat"}, fn ->
        case ReqLLM.stream_text(model, messages, opts) do
          {:ok, stream_response} ->
            # Consume stream to collect metadata, but create a new stream for return
            {stream_chunks, replay_stream} = tee_stream(stream_response.stream)

            # Wait for metadata collection
            metadata =
              MetadataHandle.await(stream_response.metadata_handle)

            # Extract token usage from metadata
            tokens = extract_tokens_from_metadata(metadata)

            # Build output messages
            text_content = build_text_from_chunks(stream_chunks)
            tool_calls = extract_tool_calls_from_chunks(stream_chunks)

            output_messages =
              if tool_calls != [] do
                [%{role: "assistant", content: text_content, tool_calls: tool_calls}]
              else
                [%{role: "assistant", content: text_content}]
              end

            # Create a new metadata handle that returns the already-collected metadata
            # This allows collect_stream to work on the returned stream_response
            {:ok, new_metadata_handle} =
              MetadataHandle.start_link(fn -> metadata end)

            # Return stream_response with replayed stream and new metadata handle
            stream_response_with_replay = %{
              stream_response
              | stream: replay_stream,
                metadata_handle: new_metadata_handle
            }

            {:ok, stream_response_with_replay,
             %{
               output_messages: output_messages,
               tokens: tokens,
               finish_reason: Map.get(metadata, :finish_reason)
             }}

          {:error, error} ->
            {:error, error}
        end
      end)

    case result do
      {:ok, stream_response, _metadata} ->
        {:ok, stream_response}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Wraps `ReqLLM.stream_object/4` with automatic AgentObs instrumentation.

  Instruments structured data streaming with schema validation and automatically
  extracts token usage, output object, and other metadata for observability.
  Similar to `trace_stream_text/3` but for structured data generation.

  ## Parameters

  - `model` - Model specification (string like "anthropic:claude-3-5-sonnet" or Model struct)
  - `messages` - List of message maps or Context
  - `schema` - Schema definition for structured output (keyword list or map)
  - `opts` - Options passed to `ReqLLM.stream_object/4` (output, mode, etc.)

  ## Returns

  - `{:ok, stream_response}` - ReqLLM.StreamResponse with instrumentation
  - `{:error, reason}` - Error from ReqLLM

  ## Examples

      # Basic usage
      schema = [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ]

      {:ok, response} = AgentObs.ReqLLM.trace_stream_object(
        "anthropic:claude-3-5-sonnet",
        [%{role: "user", content: "Generate a person"}],
        schema
      )

      # Stream the response
      response.stream
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

      # Collect the final object
      result = AgentObs.ReqLLM.collect_stream_object(response)
      #=> %{object: %{name: "John", age: 30}, tokens: %{...}, ...}

  ## Telemetry

  This function emits standard AgentObs LLM events:
  - `[:agent_obs, :llm, :start]` - When streaming begins
  - `[:agent_obs, :llm, :stop]` - When streaming completes (with tokens and object)
  - `[:agent_obs, :llm, :exception]` - If an error occurs
  """
  @spec trace_stream_object(term(), list() | struct(), keyword() | map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def trace_stream_object(model, messages, schema, opts \\ []) do
    model_string = normalize_model_string(model)
    messages_list = normalize_messages(messages)

    # Instrument the LLM call
    result =
      AgentObs.trace_llm(
        model_string,
        %{input_messages: messages_list, type: "chat", schema: schema},
        fn ->
          case ReqLLM.stream_object(model, messages, schema, opts) do
            {:ok, stream_response} ->
              # Consume stream to collect metadata, but create a new stream for return
              {_stream_chunks, replay_stream} = tee_stream(stream_response.stream)

              # Wait for metadata collection
              metadata =
                MetadataHandle.await(stream_response.metadata_handle)

              # Extract token usage from metadata
              tokens = extract_tokens_from_metadata(metadata)

              # Extract object from metadata or chunks
              object = extract_object_from_metadata(metadata)

              output_messages = [%{role: "assistant", content: object}]

              # Create a new metadata handle that returns the already-collected metadata
              # This allows collect_stream_object to work on the returned stream_response
              {:ok, new_metadata_handle} =
                MetadataHandle.start_link(fn -> metadata end)

              # Return stream_response with replayed stream and new metadata handle
              stream_response_with_replay = %{
                stream_response
                | stream: replay_stream,
                  metadata_handle: new_metadata_handle
              }

              {:ok, stream_response_with_replay,
               %{
                 output_messages: output_messages,
                 tokens: tokens,
                 object: object,
                 finish_reason: Map.get(metadata, :finish_reason)
               }}

            {:error, error} ->
              {:error, error}
          end
        end
      )

    case result do
      {:ok, stream_response, _metadata} ->
        {:ok, stream_response}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Wraps tool execution with automatic AgentObs instrumentation.

  Instruments tool/function execution and captures results for observability.

  ## Parameters

  - `tool` - ReqLLM.Tool struct
  - `tool_call` - Tool call map with `:name` and `:arguments`
  - `opts` - Additional options (currently unused)

  ## Returns

  - `{:ok, result}` - Tool execution result
  - `{:error, reason}` - Tool execution error

  ## Examples

      tool = ReqLLM.Tool.new!(
        name: "calculator",
        description: "Perform calculations",
        parameter_schema: [expression: [type: :string, required: true]],
        callback: &calculator/1
      )

      tool_call = %{
        name: "calculator",
        arguments: %{"expression" => "2 + 2"}
      }

      {:ok, result} = AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)
      #=> {:ok, 4}

  ## Telemetry

  Emits standard AgentObs tool events:
  - `[:agent_obs, :tool, :start]` - When tool execution begins
  - `[:agent_obs, :tool, :stop]` - When execution completes
  - `[:agent_obs, :tool, :exception]` - If tool execution fails
  """
  @spec trace_tool_execution(struct(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  @dialyzer {:nowarn_function, trace_tool_execution: 3}
  def trace_tool_execution(tool, tool_call, opts \\ []) do
    _ = opts

    AgentObs.trace_tool(tool_call.name, %{arguments: tool_call.arguments}, fn ->
      case ReqLLM.Tool.execute(tool, tool_call.arguments) do
        {:ok, result} ->
          {:ok, result, %{result: result}}

        {:error, error} ->
          {:error, error}

        # ReqLLM.Tool.execute can return raw values when the callback doesn't wrap in {:ok, _}
        # Dialyzer thinks this is unreachable, but it happens in practice (see integration tests)
        result ->
          {:ok, result, %{result: result}}
      end
    end)
  end

  @doc """
  Collects the complete stream text with automatic instrumentation metadata.

  This is a convenience function that consumes the entire stream and returns
  both the text and the full instrumentation metadata.

  ## Parameters

  - `stream_response` - ReqLLM.StreamResponse struct

  ## Returns

  A map containing:
  - `:text` - Complete text content
  - `:tokens` - Token usage map
  - `:tool_calls` - List of tool calls (if any)
  - `:finish_reason` - Completion reason

  ## Examples

      {:ok, stream_response} = AgentObs.ReqLLM.trace_stream_text(model, messages)

      %{text: text, tokens: tokens, tool_calls: tool_calls} =
        AgentObs.ReqLLM.collect_stream(stream_response)

  """
  @spec collect_stream(struct()) :: map()
  def collect_stream(stream_response) do
    # Collect all chunks
    chunks = Enum.to_list(stream_response.stream)

    # Get metadata
    metadata = MetadataHandle.await(stream_response.metadata_handle)

    # Extract information
    text = build_text_from_chunks(chunks)
    tokens = extract_tokens_from_metadata(metadata)
    tool_calls = extract_tool_calls_from_chunks(chunks)

    %{
      text: text,
      tokens: tokens,
      tool_calls: tool_calls,
      finish_reason: Map.get(metadata, :finish_reason)
    }
  end

  @doc """
  Collects the complete stream object with automatic instrumentation metadata.

  This is a convenience function for structured data streaming that consumes the
  entire stream and returns both the object and the full instrumentation metadata.

  ## Parameters

  - `stream_response` - ReqLLM.StreamResponse struct from `trace_stream_object/4`

  ## Returns

  A map containing:
  - `:object` - Complete structured object matching the schema
  - `:tokens` - Token usage map
  - `:finish_reason` - Completion reason

  ## Examples

      {:ok, stream_response} = AgentObs.ReqLLM.trace_stream_object(model, messages, schema)

      %{object: object, tokens: tokens} =
        AgentObs.ReqLLM.collect_stream_object(stream_response)

  """
  @spec collect_stream_object(struct()) :: map()
  def collect_stream_object(stream_response) do
    # Collect all chunks (consume the stream)
    _chunks = Enum.to_list(stream_response.stream)

    # Get metadata
    metadata = MetadataHandle.await(stream_response.metadata_handle)

    # Extract information
    tokens = extract_tokens_from_metadata(metadata)
    object = extract_object_from_metadata(metadata)

    %{
      object: object,
      tokens: tokens,
      finish_reason: Map.get(metadata, :finish_reason)
    }
  end

  # Private helper functions

  defp normalize_model_string(model) when is_binary(model), do: model

  defp normalize_model_string(%{provider: provider, model: model})
       when is_atom(provider) and is_binary(model) do
    "#{provider}:#{model}"
  end

  defp normalize_model_string(%{model: model}) when is_binary(model), do: model

  defp normalize_model_string(model), do: inspect(model)

  defp normalize_messages(messages) when is_list(messages), do: messages
  defp normalize_messages(%{messages: messages}) when is_list(messages), do: messages
  defp normalize_messages(_), do: []

  defp tee_stream(stream) do
    # Convert stream to list (consume once)
    chunks = Enum.to_list(stream)

    # Create a replay stream from the collected chunks
    replay_stream = Stream.into(chunks, [])

    {chunks, replay_stream}
  end

  defp build_text_from_chunks(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :content))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_tool_calls_from_chunks(chunks) do
    tool_calls = extract_base_tool_calls(chunks)
    arg_fragments = extract_argument_fragments(chunks)
    merge_tool_call_arguments(tool_calls, arg_fragments)
  end

  defp extract_base_tool_calls(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :tool_call))
    |> Enum.map(fn chunk ->
      %{
        id: get_in(chunk, [Access.key(:metadata), :id]) || "call_#{:erlang.unique_integer()}",
        name: chunk.name,
        arguments: chunk.arguments || %{},
        index: get_in(chunk, [Access.key(:metadata), :index]) || 0
      }
    end)
  end

  defp extract_argument_fragments(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :meta))
    |> Enum.filter(&Map.has_key?(&1.metadata, :tool_call_args))
    |> Enum.group_by(& &1.metadata.tool_call_args.index)
    |> Map.new(fn {index, fragments} ->
      args_json = build_args_json_from_fragments(fragments)
      {index, decode_args_json(args_json)}
    end)
  end

  defp build_args_json_from_fragments(fragments) do
    fragments
    |> Enum.map_join("", fn frag ->
      get_in(frag, [Access.key(:metadata), Access.key(:tool_call_args), :partial_json]) ||
        get_in(frag, [Access.key(:metadata), Access.key(:tool_call_args), :fragment]) ||
        ""
    end)
  end

  defp decode_args_json(""), do: %{}

  defp decode_args_json(args_json) do
    case Jason.decode(args_json) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp merge_tool_call_arguments(tool_calls, arg_fragments) do
    tool_calls
    |> Enum.map(fn tc ->
      arguments = Map.get(arg_fragments, tc.index, tc.arguments)
      %{tc | arguments: arguments}
    end)
    |> Enum.map(&Map.delete(&1, :index))
  end

  defp extract_tokens_from_metadata(metadata) do
    case Map.get(metadata, :usage) do
      usage when is_map(usage) ->
        input = Map.get(usage, :input_tokens, 0) || 0
        output = Map.get(usage, :output_tokens, 0) || 0

        %{
          prompt: input,
          completion: output,
          total: input + output
        }

      _ ->
        %{prompt: 0, completion: 0, total: 0}
    end
  end

  defp extract_object_from_metadata(metadata) do
    # For stream_object, the object is typically in the :object field of metadata
    # If not present, return an empty map
    Map.get(metadata, :object, %{})
  end
end
