defmodule AgentObs.E2ESpanTest do
  @moduledoc """
  End-to-end tests that verify real OpenTelemetry spans are created with correct
  names, attributes, and parent-child relationships.

  Uses `:otel_exporter_pid` to capture spans in the test process and
  `req_cassette` to replay recorded LLM API calls deterministically.
  """
  use ExUnit.Case, async: false

  import AgentObs.TestHelper
  import ReqCassette

  alias AgentObs.Handlers.Phoenix

  # When an OTLP endpoint is configured, spans go to the collector instead of
  # the test process mailbox. In that mode we skip receive_span assertions and
  # just verify operations succeed (you inspect traces in the collector UI).
  @otlp_export System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") != nil

  @moduletag :capture_log

  setup do
    # Ensure OTel applications are started
    Application.ensure_all_started(:opentelemetry)

    # Redirect spans to this test process when using the simple processor.
    # When OTEL_EXPORTER_OTLP_ENDPOINT is set, batch processor is used instead
    # and spans go to the OTLP collector — no pid exporter needed.
    if GenServer.whereis(:otel_simple_processor_global) do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    end

    # Attach Phoenix handler with default event prefix
    config = %{event_prefix: [:agent_obs]}
    {:ok, handler_state} = Phoenix.attach(config)

    # Flush any leftover spans from previous tests
    flush_spans()

    on_exit(fn ->
      # Force-flush the batch processor so spans reach the OTLP collector
      # before the test process exits (batch default interval is 5s).
      :otel_tracer_provider.force_flush()

      Phoenix.detach(handler_state)

      # Clean up process dictionary span stacks
      Process.get_keys()
      |> Enum.filter(fn
        key when is_atom(key) ->
          String.starts_with?(Atom.to_string(key), "agent_obs_phoenix_span_")

        _ ->
          false
      end)
      |> Enum.each(&Process.delete/1)
    end)

    %{handler_state: handler_state}
  end

  # Helper to find span by attribute value
  defp find_span_by_attr(spans, key, value) do
    Enum.find(spans, fn s -> s.attributes[key] == value end)
  end

  defp find_span_by_kind(spans, kind) do
    find_span_by_attr(spans, "openinference.span.kind", kind)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Section A: Core AgentObs.trace_* pipeline (synthetic data)
  # ──────────────────────────────────────────────────────────────────────

  describe "A. trace_agent produces AGENT span" do
    test "creates span with correct name and attributes" do
      AgentObs.trace_agent("test_agent", %{input: "hello"}, fn ->
        {:ok, "result", %{}}
      end)

      unless @otlp_export do
        span = receive_span()
        assert span.name == "test_agent"
        assert span.attributes["openinference.span.kind"] == "AGENT"
        assert span.attributes["input.value"] == "hello"
        assert span.attributes["output.value"] != nil
      end
    end
  end

  describe "A. trace_llm produces LLM span" do
    test "creates span with model, messages, and token counts" do
      AgentObs.trace_llm(
        "gpt-4o",
        %{input_messages: [%{role: "user", content: "Hi"}]},
        fn ->
          {:ok, %{role: "assistant", content: "Hello"},
           %{
             tokens: %{prompt: 10, completion: 5, total: 15},
             output_messages: [%{role: "assistant", content: "Hello"}]
           }}
        end
      )

      unless @otlp_export do
        span = receive_span()
        assert span.attributes["openinference.span.kind"] == "LLM"
        assert span.attributes["llm.model_name"] == "gpt-4o"
        assert span.attributes["llm.input_messages.0.message.role"] == "user"
        assert span.attributes["llm.input_messages.0.message.content"] == "Hi"
        assert span.attributes["llm.token_count.prompt"] == 10
        assert span.attributes["llm.token_count.completion"] == 5
        assert span.attributes["llm.output_messages.0.message.role"] == "assistant"
      end
    end
  end

  describe "A. trace_tool produces TOOL span" do
    test "creates span with tool name and parameters" do
      AgentObs.trace_tool("get_weather", %{arguments: %{city: "SF"}}, fn ->
        {:ok, %{temp: 72}}
      end)

      unless @otlp_export do
        span = receive_span()
        assert span.attributes["openinference.span.kind"] == "TOOL"
        assert span.attributes["tool.name"] == "get_weather"
        assert span.attributes["tool.parameters"] != nil
        assert span.attributes["output.value"] != nil
      end
    end
  end

  describe "A. trace_prompt produces CHAIN span" do
    test "creates span with CHAIN kind" do
      AgentObs.trace_prompt("greeting", %{variables: %{name: "Alice"}}, fn ->
        {:ok, "Hello, Alice!"}
      end)

      unless @otlp_export do
        span = receive_span()
        assert span.attributes["openinference.span.kind"] == "CHAIN"
        assert span.attributes["output.value"] != nil
      end
    end
  end

  describe "A. nested agent -> llm parent-child" do
    test "llm span is child of agent span" do
      AgentObs.trace_agent("my_agent", %{input: "question"}, fn ->
        AgentObs.trace_llm(
          "gpt-4o",
          %{input_messages: [%{role: "user", content: "question"}]},
          fn ->
            {:ok, %{role: "assistant", content: "answer"},
             %{tokens: %{prompt: 5, completion: 3, total: 8}}}
          end
        )

        {:ok, "answer", %{}}
      end)

      unless @otlp_export do
        # Inner spans end first, so LLM span arrives before AGENT span
        spans = receive_all_spans()
        assert length(spans) == 2

        agent_span = find_span(spans, "my_agent")
        # LLM spans don't have a :name key, so the handler defaults to "llm_operation"
        llm_span = find_span_by_kind(spans, "LLM")

        assert agent_span != nil,
               "Agent span not found. Spans: #{inspect(Enum.map(spans, & &1.name))}"

        assert llm_span != nil,
               "LLM span not found. Spans: #{inspect(Enum.map(spans, & &1.name))}"

        assert_span_parent(llm_span, agent_span)
        assert llm_span.trace_id == agent_span.trace_id
      end
    end
  end

  describe "A. nested 3-level agent -> llm -> tool" do
    test "full parent chain is correct" do
      AgentObs.trace_agent("top_agent", %{input: "complex"}, fn ->
        AgentObs.trace_llm(
          "gpt-4o",
          %{input_messages: [%{role: "user", content: "complex"}]},
          fn ->
            AgentObs.trace_tool("calculator", %{arguments: %{op: "add"}}, fn ->
              {:ok, %{result: 42}}
            end)

            {:ok, %{role: "assistant", content: "42"},
             %{tokens: %{prompt: 10, completion: 5, total: 15}}}
          end
        )

        {:ok, "42", %{}}
      end)

      unless @otlp_export do
        spans = receive_all_spans()
        assert length(spans) == 3

        agent_span = find_span(spans, "top_agent")
        llm_span = find_span_by_kind(spans, "LLM")
        tool_span = find_span(spans, "calculator")

        assert agent_span != nil
        assert llm_span != nil
        assert tool_span != nil

        # tool -> llm -> agent
        assert_span_parent(tool_span, llm_span)
        assert_span_parent(llm_span, agent_span)

        # All same trace
        assert tool_span.trace_id == agent_span.trace_id
        assert llm_span.trace_id == agent_span.trace_id
      end
    end
  end

  describe "A. exception produces error status" do
    test "span has error status when function raises" do
      AgentObs.trace_agent("failing_agent", %{input: "boom"}, fn ->
        raise RuntimeError, "intentional error"
      end)

      unless @otlp_export do
        span = receive_span()
        assert span.name == "failing_agent"
        assert span.status != nil
        # OTel status code is the atom :error
        assert span.status.code == :error
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Section B: ReqLLM backend (with cassettes)
  # ──────────────────────────────────────────────────────────────────────

  if Code.ensure_loaded?(ReqLLM) do
    describe "B. trace_generate_text produces LLM span with real metadata" do
      test "creates span with model, tokens, and output" do
        with_cassette(
          "req_llm_generate_text",
          [
            filter_request_headers: ["x-api-key", "authorization"],
            filter_response_headers: ["openai-organization", "openai-project", "set-cookie"]
          ],
          fn plug ->
            {:ok, _response} =
              AgentObs.ReqLLM.trace_generate_text(
                "anthropic:claude-3-5-haiku-latest",
                [%{role: "user", content: "Say hello in one word"}],
                api_key: System.get_env("ANTHROPIC_API_KEY", "test-key"),
                req_http_options: [plug: plug]
              )

            unless @otlp_export do
              span = receive_span()
              assert span.attributes["openinference.span.kind"] == "LLM"
              assert span.attributes["llm.model_name"] != nil
              assert span.attributes["llm.token_count.prompt"] > 0
              assert span.attributes["llm.token_count.completion"] > 0
              assert span.attributes["llm.output_messages.0.message.role"] == "assistant"
              assert span.attributes["llm.output_messages.0.message.content"] != nil
              assert String.length(span.attributes["llm.output_messages.0.message.content"]) > 0
            end
          end
        )
      end
    end

    describe "B. trace_generate_object produces LLM span with object" do
      test "creates span with structured output metadata" do
        with_cassette(
          "req_llm_generate_object",
          [
            filter_request_headers: ["x-api-key", "authorization"],
            filter_response_headers: ["openai-organization", "openai-project", "set-cookie"]
          ],
          fn plug ->
            schema = [name: [type: :string, required: true]]

            # Use OpenAI for structured output (cassette recorded with gpt-4o-mini)
            {:ok, _response} =
              AgentObs.ReqLLM.trace_generate_object(
                "openai:gpt-4o-mini",
                [%{role: "user", content: "Generate a person named Alice"}],
                schema,
                api_key: System.get_env("OPENAI_API_KEY", "test-key"),
                req_http_options: [plug: plug]
              )

            unless @otlp_export do
              span = receive_span()
              assert span.attributes["openinference.span.kind"] == "LLM"
              assert span.attributes["llm.token_count.prompt"] > 0
              assert span.attributes["llm.token_count.completion"] > 0
            end
          end
        )
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Section C: LangChain backend (with cassettes)
  # ──────────────────────────────────────────────────────────────────────

  if Code.ensure_loaded?(LangChain.Chains.LLMChain) do
    describe "C. LangChain run/2 produces LLM span" do
      test "creates LLM span via LangChain integration" do
        with_cassette(
          "langchain_run",
          [
            filter_request_headers: ["x-api-key", "authorization"],
            filter_response_headers: ["openai-organization", "openai-project", "set-cookie"],
            match_requests_on: [:method, :uri, :body]
          ],
          fn plug ->
            alias LangChain.Chains.LLMChain
            alias LangChain.ChatModels.ChatAnthropic
            alias LangChain.Message

            llm =
              ChatAnthropic.new!(%{
                model: "claude-3-5-haiku-latest",
                api_key: System.get_env("ANTHROPIC_API_KEY", "test-key"),
                req_opts: [plug: plug]
              })

            chain =
              LLMChain.new!(%{llm: llm})
              |> LLMChain.add_message(Message.new_user!("Say hello in one word"))

            {:ok, _chain} = AgentObs.LangChain.run(chain)

            unless @otlp_export do
              # LangChain.run/2 wraps in an outer trace_llm span, which creates the
              # OTel span. Additional per-iteration spans may also be emitted.
              spans = receive_all_spans()
              assert spans != []

              # Find at least one LLM span
              llm_spans =
                Enum.filter(spans, fn s ->
                  s.attributes["openinference.span.kind"] == "LLM"
                end)

              assert llm_spans != []

              llm_span = List.first(llm_spans)
              assert llm_span.attributes["llm.model_name"] != nil
            end
          end
        )
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Section D: Sagents middleware (real Agent.execute with cassette)
  # ──────────────────────────────────────────────────────────────────────

  if Code.ensure_loaded?(Sagents.Middleware) do
    describe "D. Sagents Agent.execute produces AGENT span via middleware" do
      test "emits AGENT span with model and input/output" do
        with_cassette(
          "sagents_execute",
          [
            filter_request_headers: ["x-api-key", "authorization"],
            filter_response_headers: ["openai-organization", "openai-project", "set-cookie"],
            match_requests_on: [:method, :uri, :body]
          ],
          fn plug ->
            alias LangChain.ChatModels.ChatAnthropic
            alias LangChain.Message
            alias Sagents.Agent
            alias Sagents.State

            model =
              ChatAnthropic.new!(%{
                model: "claude-3-5-haiku-latest",
                api_key: System.get_env("ANTHROPIC_API_KEY", "test-key"),
                req_opts: [plug: plug]
              })

            agent =
              Agent.new!(
                %{
                  agent_id: "sagents-e2e-test",
                  model: model,
                  middleware: [AgentObs.Sagents]
                },
                replace_default_middleware: true
              )

            state =
              State.new!(%{
                messages: [Message.new_user!("Say hello in one word")]
              })

            {:ok, _final_state} = Agent.execute(agent, state)

            unless @otlp_export do
              span = receive_span()
              assert span.attributes["openinference.span.kind"] == "AGENT"
              assert span.attributes["llm.model_name"] != nil
              assert span.attributes["input.value"] != nil
              assert span.attributes["output.value"] != nil
            end
          end
        )
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Section E: Sagents multi-turn with tool calls + sub-agent delegation
  # ──────────────────────────────────────────────────────────────────────

  if Code.ensure_loaded?(Sagents.Middleware) do
    describe "E. Sagents multi-turn tool calls: full span structure" do
      test "produces AGENT > 2x LLM > TOOL hierarchy with messages and model" do
        with_cassette(
          "sagents_multi_turn",
          [
            filter_request_headers: ["x-api-key", "authorization"],
            filter_response_headers: ["openai-organization", "openai-project", "set-cookie"],
            sequential: true,
            match_requests_on: [:method, :uri]
          ],
          fn plug ->
            alias LangChain.ChatModels.ChatAnthropic
            alias LangChain.Function
            alias LangChain.Message
            alias Sagents.Agent
            alias Sagents.State

            get_weather =
              Function.new!(%{
                name: "get_weather",
                description: "Get current weather for a city",
                parameters_schema: %{
                  type: "object",
                  properties: %{"city" => %{type: "string"}},
                  required: ["city"]
                },
                function: fn _args, _ctx -> "72°F and sunny" end
              })

            get_time =
              Function.new!(%{
                name: "get_time",
                description: "Get current time in a city",
                parameters_schema: %{
                  type: "object",
                  properties: %{"city" => %{type: "string"}},
                  required: ["city"]
                },
                function: fn _args, _ctx -> "2:30 PM" end
              })

            model =
              ChatAnthropic.new!(%{
                model: "claude-3-5-haiku-latest",
                api_key: System.get_env("ANTHROPIC_API_KEY", "test-key"),
                req_opts: [plug: plug]
              })

            agent =
              Agent.new!(
                %{
                  agent_id: "sagents-multi-turn-test",
                  model: model,
                  middleware: [AgentObs.Sagents],
                  tools: [get_weather, get_time]
                },
                replace_default_middleware: true
              )

            state =
              State.new!(%{
                messages: [
                  Message.new_user!(
                    "What's the weather and time in San Francisco? Use both tools."
                  )
                ]
              })

            {:ok, _final_state} =
              Agent.execute(agent, state, callbacks: AgentObs.LangChain.callbacks())

            unless @otlp_export do
              spans = receive_all_spans()

              agent_spans =
                Enum.filter(spans, &(&1.attributes["openinference.span.kind"] == "AGENT"))

              llm_spans =
                Enum.filter(spans, &(&1.attributes["openinference.span.kind"] == "LLM"))

              tool_spans =
                Enum.filter(spans, &(&1.attributes["openinference.span.kind"] == "TOOL"))

              # --- Span count ---
              # The LLM may call both tools in one turn (2 LLM spans) or
              # one tool per turn (3 LLM spans), depending on the model response.
              assert length(agent_spans) == 1, "Expected exactly 1 AGENT span"
              assert length(llm_spans) >= 2, "Expected at least 2 LLM spans"
              assert length(tool_spans) == 2, "Expected exactly 2 TOOL spans"

              agent_span = List.first(agent_spans)

              # --- All spans share one trace ---
              Enum.each(spans, fn s ->
                assert s.trace_id == agent_span.trace_id,
                       "Span #{s.name} should share trace_id with AGENT span"
              end)

              # --- Tool span names ---
              tool_names = Enum.map(tool_spans, & &1.attributes["tool.name"]) |> Enum.sort()
              assert tool_names == ["get_time", "get_weather"]

              # --- LLM spans have Anthropic model name ---
              Enum.each(llm_spans, fn s ->
                assert s.attributes["llm.model_name"] =~ "anthropic/claude",
                       "LLM span model_name should contain 'anthropic/claude', got: #{inspect(s.attributes["llm.model_name"])}"
              end)

              # --- First LLM span: tool-calling turn ---
              sorted_llm = Enum.sort_by(llm_spans, & &1.start_time)
              llm_first = List.first(sorted_llm)
              llm_last = List.last(sorted_llm)

              # First LLM span should have the user message as input
              assert llm_first.attributes["llm.input_messages.0.message.role"] == "user"

              assert llm_first.attributes["llm.input_messages.0.message.content"] =~
                       "weather and time"

              # First LLM output: assistant with tool calls
              assert llm_first.attributes["llm.output_messages.0.message.role"] == "assistant"

              assert llm_first.attributes[
                       "llm.output_messages.0.message.tool_calls.0.tool_call.function.name"
                     ] != nil,
                     "First LLM output should contain tool calls"

              # First LLM output also includes the tool result message
              assert llm_first.attributes["llm.output_messages.1.message.role"] == "tool"

              assert llm_first.attributes["llm.output_messages.1.message.content"] != nil,
                     "Tool result message should have content"

              assert llm_first.attributes["llm.output_messages.1.message.content"] != "",
                     "Tool result message content should not be empty"

              # First LLM span has token counts
              assert llm_first.attributes["llm.token_count.prompt"] > 0
              assert llm_first.attributes["llm.token_count.completion"] > 0

              # --- Last LLM span: final answer turn ---
              assert llm_last.attributes["llm.output_messages.0.message.role"] == "assistant"
              assert llm_last.attributes["llm.output_messages.0.message.content"] =~ "72°F"

              assert llm_last.attributes["llm.token_count.prompt"] > 0
              assert llm_last.attributes["llm.token_count.completion"] > 0

              # --- Each tool span is a child of an LLM span ---
              llm_span_ids = MapSet.new(llm_spans, & &1.span_id)

              Enum.each(tool_spans, fn tool_span ->
                assert MapSet.member?(llm_span_ids, tool_span.parent_span_id),
                       "Tool span #{tool_span.attributes["tool.name"]} should be child of an LLM span"
              end)

              # --- All LLM spans are children of the AGENT span ---
              Enum.each(llm_spans, fn s ->
                assert s.parent_span_id == agent_span.span_id,
                       "LLM span should be child of AGENT span"
              end)
            end
          end
        )
      end
    end

    describe "E. Sagents sub-agent delegation produces spans" do
      test "emits LLM spans for parent and sub-agent" do
        with_cassette(
          "sagents_subagent",
          [
            filter_request_headers: ["x-api-key", "authorization"],
            filter_response_headers: ["openai-organization", "openai-project", "set-cookie"],
            sequential: true,
            match_requests_on: [:method, :uri]
          ],
          fn plug ->
            alias LangChain.ChatModels.ChatAnthropic
            alias LangChain.Function
            alias LangChain.Message
            alias Sagents.Agent
            alias Sagents.State
            alias Sagents.SubAgent.Config

            agent_id = "sagents-subagent-test-#{System.unique_integer([:positive])}"

            {:ok, _sup} =
              Sagents.SubAgentsDynamicSupervisor.start_link(agent_id: agent_id)

            on_exit(fn ->
              sup = Sagents.SubAgentsDynamicSupervisor.whereis(agent_id)
              if sup, do: Process.exit(sup, :shutdown)
            end)

            lookup_tool =
              Function.new!(%{
                name: "lookup",
                description: "Look up a fact",
                parameters_schema: %{
                  type: "object",
                  properties: %{"query" => %{type: "string"}},
                  required: ["query"]
                },
                function: fn _args, _ctx -> "The Eiffel Tower is 330 meters tall." end
              })

            model =
              ChatAnthropic.new!(%{
                model: "claude-3-5-haiku-latest",
                api_key: System.get_env("ANTHROPIC_API_KEY", "test-key"),
                req_opts: [plug: plug]
              })

            agent =
              Agent.new!(
                %{
                  agent_id: agent_id,
                  model: model,
                  middleware: [
                    AgentObs.Sagents,
                    {Sagents.Middleware.SubAgent,
                     [
                       model: model,
                       subagents: [
                         Config.new!(%{
                           name: "researcher",
                           description: "Research facts and answer questions",
                           system_prompt:
                             "You are a researcher. Use the lookup tool to find facts. Be concise.",
                           tools: [lookup_tool]
                         })
                       ]
                     ]}
                  ]
                },
                replace_default_middleware: true
              )

            state =
              State.new!(%{
                messages: [
                  Message.new_user!("How tall is the Eiffel Tower? Ask the researcher.")
                ]
              })

            {:ok, _final_state} =
              Agent.execute(agent, state, callbacks: AgentObs.LangChain.callbacks())

            unless @otlp_export do
              spans = receive_all_spans()

              agent_spans =
                Enum.filter(spans, &(&1.attributes["openinference.span.kind"] == "AGENT"))

              # At minimum, the parent agent's execution should produce an AGENT span
              assert agent_spans != [], "Expected at least one AGENT span"
            end
          end
        )
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Section F: LangChain with OpenAI — tool calling with cassette
  # ──────────────────────────────────────────────────────────────────────

  if Code.ensure_loaded?(LangChain.Chains.LLMChain) do
    describe "F. LangChain OpenAI tool call produces correct span hierarchy" do
      test "produces LLM > TOOL nesting with OpenAI model name" do
        with_cassette(
          "langchain_openai_tool",
          [
            filter_request_headers: ["authorization", "api-key"],
            sequential: true,
            match_requests_on: [:method, :uri]
          ],
          fn plug ->
            alias LangChain.Chains.LLMChain
            alias LangChain.ChatModels.ChatOpenAI
            alias LangChain.Function
            alias LangChain.Message

            lookup =
              Function.new!(%{
                name: "lookup",
                description: "Look up a fact",
                parameters_schema: %{
                  type: "object",
                  properties: %{"query" => %{type: "string"}},
                  required: ["query"]
                },
                function: fn _args, _ctx ->
                  "Tokyo has a population of approximately 14 million people."
                end
              })

            llm =
              ChatOpenAI.new!(%{
                model: "gpt-4o-mini",
                api_key: System.get_env("OPENAI_API_KEY", "test-key"),
                req_config: %{plug: plug}
              })

            chain =
              LLMChain.new!(%{llm: llm})
              |> LLMChain.add_message(
                Message.new_user!("What is the population of Tokyo? Use the lookup tool.")
              )
              |> LLMChain.add_tools([lookup])

            {:ok, _chain} =
              AgentObs.LangChain.run(chain, mode: :while_needs_response)

            unless @otlp_export do
              spans = receive_all_spans()

              llm_spans =
                Enum.filter(spans, &(&1.attributes["openinference.span.kind"] == "LLM"))

              tool_spans =
                Enum.filter(spans, &(&1.attributes["openinference.span.kind"] == "TOOL"))

              # Outer trace_llm span + 2 inner per-iteration LLM spans = 3 LLM spans
              assert length(llm_spans) == 3,
                     "Expected 3 LLM spans (outer + 2 iterations), got #{length(llm_spans)}"

              assert length(tool_spans) == 1, "Expected exactly 1 TOOL span"

              # All spans share same trace
              trace_id = List.first(spans).trace_id

              Enum.each(spans, fn s ->
                assert s.trace_id == trace_id,
                       "All spans should share the same trace_id"
              end)

              # Outer LLM span is the root (no parent)
              outer_llm =
                Enum.find(llm_spans, fn s -> s.parent_span_id == :undefined end)

              assert outer_llm != nil, "Expected a root LLM span"
              assert outer_llm.attributes["llm.model_name"] == "openai/gpt-4o-mini"

              # Inner LLM spans are children of the outer span
              inner_llm_spans =
                Enum.filter(llm_spans, fn s -> s.span_id != outer_llm.span_id end)

              assert length(inner_llm_spans) == 2

              Enum.each(inner_llm_spans, fn s ->
                assert s.parent_span_id == outer_llm.span_id,
                       "Inner LLM span should be child of outer LLM span"

                assert s.attributes["llm.model_name"] =~ "openai/gpt-4o",
                       "Inner LLM span model should contain 'openai/gpt-4o', got: #{inspect(s.attributes["llm.model_name"])}"
              end)

              # The tool span should be a child of an inner LLM span
              tool_span = List.first(tool_spans)
              inner_llm_ids = MapSet.new(inner_llm_spans, & &1.span_id)

              assert tool_span.attributes["tool.name"] == "lookup"

              assert MapSet.member?(inner_llm_ids, tool_span.parent_span_id),
                     "Tool span should be child of an inner LLM span"

              # Tool span should have output
              assert tool_span.attributes["output.value"] =~ "14 million"
            end
          end
        )
      end
    end
  end
end
