#!/bin/bash
set -e

# Change to demo directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEMO_DIR"

echo "🎯 Running AgentObs Demo with Phoenix Backend"
echo "=============================================="
echo ""

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Check if Phoenix is running
if ! curl -sf http://localhost:6006 > /dev/null 2>&1; then
    echo "❌ Arize Phoenix is not running!"
    echo "   Start services with: ./scripts/start.sh"
    exit 1
fi

echo "📡 Arize Phoenix is running..."
echo "📤 Traces will be sent to: http://localhost:6006/v1/traces"
echo ""

# Set backend to Phoenix (default, but explicit)
export OTLP_BACKEND=phoenix

# Run the demo
if [ -n "$1" ]; then
    # Run specific scenario
    echo "Running scenario: $1"
    mix run -e "Demo.Scenarios.$1()"
else
    # Run all scenarios
    echo "Running all scenarios..."
    mix run -e "Demo.Scenarios.run_all()"
fi

echo ""
echo "🎉 Demo completed!"
echo ""
echo "📊 View traces at:"
echo "  • Arize Phoenix: http://localhost:6006"
echo "    (Look for service: agent_obs_demo)"
echo ""
echo "💡 The Phoenix handler creates OpenInference-formatted spans"
echo "   with rich semantic conventions for LLM observability."
echo ""
