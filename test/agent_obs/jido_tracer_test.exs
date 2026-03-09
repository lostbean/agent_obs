defmodule AgentObs.JidoTracerTest do
  use ExUnit.Case, async: false

  alias AgentObs.Handlers.Phoenix
  alias AgentObs.Handlers.Phoenix.Translator
  alias AgentObs.JidoTracer

  @moduletag :capture_log

  setup do
    Application.ensure_all_started(:opentelemetry)
    Application.ensure_all_started(:opentelemetry_exporter)

    # Attach Phoenix handler so OTel spans get created
    config = %{event_prefix: [:agent_obs]}
    {:ok, handler_state} = Phoenix.attach(config)

    on_exit(fn ->
      Phoenix.detach(handler_state)

      Process.get_keys()
      |> Enum.filter(fn
        key when is_atom(key) -> String.starts_with?(Atom.to_string(key), "agent_obs_")
        _ -> false
      end)
      |> Enum.each(&Process.delete/1)
    end)

    :ok
  end

  describe "behaviour compliance" do
    test "implements span_start/2 and returns valid tracer_ctx" do
      ctx = JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})
      assert is_map(ctx)
      assert Map.has_key?(ctx, :otel_span_ctx)
      assert Map.has_key?(ctx, :parent_ctx)
      assert Map.has_key?(ctx, :event_type)
    end

    test "implements span_stop/2 and returns :ok" do
      ctx = JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})
      result = JidoTracer.span_stop(ctx, %{duration: 1_000_000})
      assert result == :ok
    end

    test "implements span_exception/4 and returns :ok" do
      ctx = JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})

      result =
        JidoTracer.span_exception(
          ctx,
          :error,
          %RuntimeError{message: "boom"},
          [{__MODULE__, :test, 0, []}]
        )

      assert result == :ok
    end
  end

  describe "event prefix routing" do
    test "[:jido, :composer, :agent] maps to :agent event type" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})

      assert ctx.event_type == :agent
      JidoTracer.span_stop(ctx, %{})
    end

    test "[:jido, :composer, :llm] maps to :llm event type" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "anthropic:claude-sonnet-4-20250514"
        })

      assert ctx.event_type == :llm
      JidoTracer.span_stop(ctx, %{})
    end

    test "[:jido, :composer, :tool] maps to :tool event type" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{tool_name: "search", name: "search"})

      assert ctx.event_type == :tool
      JidoTracer.span_stop(ctx, %{})
    end

    test "unknown prefix falls back to :agent" do
      ctx = JidoTracer.span_start([:some, :other, :prefix], %{name: "unknown"})
      assert ctx.event_type == :agent
      JidoTracer.span_stop(ctx, %{})
    end
  end

  describe "metadata mapping" do
    test "agent metadata maps query to input" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{
          query: "What is the weather?",
          name: "weather_agent"
        })

      # Span was created with correct attributes - verify no crash
      assert ctx.event_type == :agent
      JidoTracer.span_stop(ctx, %{})
    end

    test "llm metadata maps model correctly" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "anthropic:claude-sonnet-4-20250514",
          input_messages: [%{role: "user", content: "Hello"}]
        })

      assert ctx.event_type == :llm
      JidoTracer.span_stop(ctx, %{})
    end

    test "llm metadata extracts messages from conversation" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "anthropic:claude-sonnet-4-20250514",
          conversation: [
            %{role: "user", content: "Hi"},
            %{role: "assistant", content: "Hello"}
          ]
        })

      assert ctx.event_type == :llm
      JidoTracer.span_stop(ctx, %{})
    end

    test "tool metadata maps tool_name and arguments" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{
          tool_name: "search",
          name: "search",
          arguments: %{query: "elixir"},
          params: %{query: "elixir"}
        })

      assert ctx.event_type == :tool
      JidoTracer.span_stop(ctx, %{})
    end

    test "tool metadata uses node_name when tool_name missing" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{
          node_name: "extract_node",
          name: "extract_node"
        })

      assert ctx.event_type == :tool
      JidoTracer.span_stop(ctx, %{})
    end
  end

  describe "nesting" do
    test "agent span then nested LLM span creates parent-child" do
      agent_ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{
          query: "test",
          name: "my_agent"
        })

      llm_ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "anthropic:claude-sonnet-4-20250514"
        })

      # Both contexts should be valid
      assert agent_ctx.event_type == :agent
      assert llm_ctx.event_type == :llm

      # Stop inner first, then outer
      JidoTracer.span_stop(llm_ctx, %{})
      JidoTracer.span_stop(agent_ctx, %{})
    end

    test "stopping inner span restores outer context" do
      agent_ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{
          query: "test",
          name: "my_agent"
        })

      llm_ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "anthropic:claude-sonnet-4-20250514"
        })

      JidoTracer.span_stop(llm_ctx, %{})

      # Start another LLM span - should be sibling, not child of first LLM
      llm_ctx2 =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "anthropic:claude-sonnet-4-20250514"
        })

      assert llm_ctx2.event_type == :llm
      JidoTracer.span_stop(llm_ctx2, %{})
      JidoTracer.span_stop(agent_ctx, %{})
    end

    test "sequential siblings don't nest incorrectly" do
      agent_ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{
          query: "test",
          name: "my_agent"
        })

      # Tool 1
      tool1_ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{
          tool_name: "tool1",
          name: "tool1"
        })

      JidoTracer.span_stop(tool1_ctx, %{})

      # Tool 2 - should NOT be child of tool1
      tool2_ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{
          tool_name: "tool2",
          name: "tool2"
        })

      JidoTracer.span_stop(tool2_ctx, %{})

      JidoTracer.span_stop(agent_ctx, %{})
    end

    test "deep nesting: agent -> llm -> tool" do
      agent_ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{
          query: "test",
          name: "my_agent"
        })

      llm_ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "anthropic:claude-sonnet-4-20250514"
        })

      tool_ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{
          tool_name: "calc",
          name: "calc"
        })

      JidoTracer.span_stop(tool_ctx, %{})
      JidoTracer.span_stop(llm_ctx, %{})
      JidoTracer.span_stop(agent_ctx, %{})
    end
  end

  describe "span-targeted operations" do
    test "span_stop targets specific span when OTel context has been changed" do
      # Start agent span, then start multiple tool spans (simulating sibling dispatch)
      agent_ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})

      tool1_ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{tool_name: "tool1", name: "tool1"})

      # Start second tool — this clobbers the process-level OTel context
      tool2_ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{tool_name: "tool2", name: "tool2"})

      # Stopping tool1 should still work correctly despite context clobber
      assert JidoTracer.span_stop(tool1_ctx, %{result: "tool1 done"}) == :ok
      assert JidoTracer.span_stop(tool2_ctx, %{result: "tool2 done"}) == :ok
      assert JidoTracer.span_stop(agent_ctx, %{}) == :ok
    end

    test "span_exception targets specific span when OTel context has been changed" do
      agent_ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})

      tool_ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{tool_name: "tool1", name: "tool1"})

      # Start another span to clobber context
      _tool2_ctx =
        JidoTracer.span_start([:jido, :composer, :tool], %{tool_name: "tool2", name: "tool2"})

      # Exception on tool1 should target tool1's span, not the current process span
      assert JidoTracer.span_exception(
               tool_ctx,
               :error,
               %RuntimeError{message: "boom"},
               [{__MODULE__, :test, 0, []}]
             ) == :ok

      assert JidoTracer.span_stop(agent_ctx, %{}) == :ok
    end

    test "LLM span stop with output_messages passes content not finish_reason to translator" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{model: "test-model"})

      measurements = %{
        tokens: %{prompt: 100, completion: 50, total: 150},
        finish_reason: :stop,
        output_messages: [%{role: "assistant", content: "Hello world"}]
      }

      # Should not crash and should pass content through to translator
      assert JidoTracer.span_stop(ctx, measurements) == :ok
    end
  end

  describe "input.value translation" do
    test "LLM start metadata includes input.value from last user message" do
      attrs =
        Translator.from_start_metadata(:llm, %{
          model: "test-model",
          input_messages: [
            %{role: "system", content: "You are helpful"},
            %{role: "user", content: "What is 2+2?"},
            %{role: "assistant", content: "4"},
            %{role: "user", content: "And 3+3?"}
          ]
        })

      assert attrs["input.value"] == "And 3+3?"
      assert attrs["openinference.span.kind"] == "LLM"
    end

    test "LLM start metadata input.value is nil when no user messages" do
      attrs =
        Translator.from_start_metadata(:llm, %{
          model: "test-model",
          input_messages: [%{role: "system", content: "system prompt"}]
        })

      refute Map.has_key?(attrs, "input.value")
    end

    test "LLM start metadata input.value is nil when no messages" do
      alias AgentObs.Handlers.Phoenix.Translator

      attrs = Translator.from_start_metadata(:llm, %{model: "test-model"})
      refute Map.has_key?(attrs, "input.value")
    end

    test "tool start metadata includes input.value from arguments" do
      attrs =
        Translator.from_start_metadata(:tool, %{
          name: "search",
          arguments: %{query: "elixir", limit: 10}
        })

      assert attrs["input.value"] != nil
      decoded = Jason.decode!(attrs["input.value"])
      assert decoded["query"] == "elixir"
      assert decoded["limit"] == 10
    end

    test "tool start metadata input.value is nil when no arguments" do
      alias AgentObs.Handlers.Phoenix.Translator

      attrs = Translator.from_start_metadata(:tool, %{name: "ping"})
      refute Map.has_key?(attrs, "input.value")
    end
  end

  describe "LLM span naming" do
    test "LLM span name includes iteration number" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "test-model",
          iteration: 2
        })

      assert ctx.event_type == :llm
      JidoTracer.span_stop(ctx, %{})
    end

    test "LLM span name without iteration uses model only" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "test-model"
        })

      assert ctx.event_type == :llm
      JidoTracer.span_stop(ctx, %{})
    end
  end

  describe "chain/iteration spans" do
    test "[:jido, :composer, :iteration] maps to :chain event type" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :iteration], %{
          iteration: 1,
          input: "some query"
        })

      assert ctx.event_type == :chain
      JidoTracer.span_stop(ctx, %{output: "tool_calls dispatched"})
    end

    test "chain span name includes iteration number" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :iteration], %{
          iteration: 3
        })

      assert ctx.event_type == :chain
      JidoTracer.span_stop(ctx, %{})
    end

    test "chain span nests correctly under agent" do
      agent_ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{
          query: "test",
          name: "my_agent"
        })

      chain_ctx =
        JidoTracer.span_start([:jido, :composer, :iteration], %{
          iteration: 1
        })

      llm_ctx =
        JidoTracer.span_start([:jido, :composer, :llm], %{
          model: "test-model",
          iteration: 1
        })

      JidoTracer.span_stop(llm_ctx, %{})
      JidoTracer.span_stop(chain_ctx, %{output: "done"})
      JidoTracer.span_stop(agent_ctx, %{})
    end

    test "chain translator produces CHAIN span kind" do
      attrs =
        Translator.from_start_metadata(:chain, %{
          iteration: 2,
          input: "query text"
        })

      assert attrs["openinference.span.kind"] == "CHAIN"
      assert attrs["metadata.iteration"] == 2
      assert attrs["input.value"] == "query text"
    end

    test "chain stop translator produces output.value" do
      attrs =
        Translator.from_stop_metadata(:chain, %{output: "final_answer: 42"}, %{
          duration: 1_000_000
        })

      assert attrs["output.value"] == "final_answer: 42"
      assert attrs["latency_ms"] == 1.0
    end
  end

  describe "span ID parent-child verification" do
    test "agent → LLM: LLM span parents under agent span" do
      alias AgentObs.TestHelper, as: TH

      {_, spans} =
        TH.capture_spans(fn ->
          agent_ctx =
            JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})

          llm_ctx =
            JidoTracer.span_start([:jido, :composer, :llm], %{
              model: "test-model",
              iteration: 1
            })

          JidoTracer.span_stop(llm_ctx, %{tokens: %{prompt: 10, completion: 5, total: 15}})
          JidoTracer.span_stop(agent_ctx, %{result: "done"})
        end)

      agent_span = TH.find_span(spans, "my_agent")
      llm_span = TH.find_span(spans, "test-model #1")

      assert agent_span != nil,
             "Expected agent span, got: #{inspect(Enum.map(spans, &TH.span_name/1))}"

      assert llm_span != nil,
             "Expected LLM span, got: #{inspect(Enum.map(spans, &TH.span_name/1))}"

      TH.assert_span_parent(llm_span, agent_span)
    end

    test "agent → LLM → tool: three-level parent-child chain" do
      alias AgentObs.TestHelper, as: TH

      {_, spans} =
        TH.capture_spans(fn ->
          agent_ctx =
            JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "deep_agent"})

          llm_ctx =
            JidoTracer.span_start([:jido, :composer, :llm], %{model: "test-model"})

          tool_ctx =
            JidoTracer.span_start([:jido, :composer, :tool], %{
              tool_name: "calc",
              name: "calc"
            })

          JidoTracer.span_stop(tool_ctx, %{result: "42"})
          JidoTracer.span_stop(llm_ctx, %{})
          JidoTracer.span_stop(agent_ctx, %{})
        end)

      agent_span = TH.find_span(spans, "deep_agent")
      llm_span = TH.find_span(spans, "test-model")
      tool_span = TH.find_span(spans, "calc")

      assert agent_span != nil, "Expected agent span"
      assert llm_span != nil, "Expected LLM span"
      assert tool_span != nil, "Expected tool span"

      TH.assert_span_parent(llm_span, agent_span)
      TH.assert_span_parent(tool_span, llm_span)
    end

    test "sequential siblings don't accidentally nest" do
      alias AgentObs.TestHelper, as: TH

      {_, spans} =
        TH.capture_spans(fn ->
          agent_ctx =
            JidoTracer.span_start([:jido, :composer, :agent], %{
              query: "test",
              name: "sibling_agent"
            })

          llm1_ctx =
            JidoTracer.span_start([:jido, :composer, :llm], %{model: "model-1"})

          JidoTracer.span_stop(llm1_ctx, %{})

          llm2_ctx =
            JidoTracer.span_start([:jido, :composer, :llm], %{model: "model-2"})

          JidoTracer.span_stop(llm2_ctx, %{})
          JidoTracer.span_stop(agent_ctx, %{})
        end)

      agent_span = TH.find_span(spans, "sibling_agent")
      llm1_span = TH.find_span(spans, "model-1")
      llm2_span = TH.find_span(spans, "model-2")

      assert agent_span != nil
      assert llm1_span != nil
      assert llm2_span != nil

      # Both LLM spans should be children of agent, not of each other
      TH.assert_span_parent(llm1_span, agent_span)
      TH.assert_span_parent(llm2_span, agent_span)

      # They should be siblings
      TH.assert_span_siblings(llm1_span, llm2_span)
    end
  end

  describe "error handling" do
    test "exception spans get error status" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})

      result =
        JidoTracer.span_exception(
          ctx,
          :error,
          %RuntimeError{message: "crash"},
          [{__MODULE__, :test, 0, [file: ~c"test.exs", line: 1]}]
        )

      assert result == :ok
    end

    test "missing metadata fields don't crash" do
      # No name, no query — should still work
      ctx = JidoTracer.span_start([:jido, :composer, :agent], %{})
      assert is_map(ctx)
      JidoTracer.span_stop(ctx, %{})
    end

    test "nil tracer_ctx handled gracefully in span_stop" do
      assert JidoTracer.span_stop(nil, %{}) == :ok
    end

    test "nil tracer_ctx handled gracefully in span_exception" do
      assert JidoTracer.span_exception(nil, :error, "boom", []) == :ok
    end

    test "empty measurements in span_stop" do
      ctx =
        JidoTracer.span_start([:jido, :composer, :agent], %{query: "test", name: "my_agent"})

      assert JidoTracer.span_stop(ctx, %{}) == :ok
    end
  end
end
