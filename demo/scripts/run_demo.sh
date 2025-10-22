#!/bin/bash
set -e

# Change to demo directory (script can be run from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEMO_DIR"

echo "🎯 Running AgentObs Demo Scenarios"
echo "=================================="
echo ""

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Check if services are running
if ! curl -sf http://localhost:6006 > /dev/null 2>&1; then
    echo "❌ Arize Phoenix is not running!"
    echo "   Start services with: ./scripts/start.sh"
    exit 1
fi

if ! curl -sf http://localhost:16686 > /dev/null 2>&1; then
    echo "❌ Jaeger is not running!"
    echo "   Start services with: ./scripts/start.sh"
    exit 1
fi

echo "📡 Services are running..."
echo ""

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
echo "  • Jaeger:        http://localhost:16686"
echo "    (Look for service: agent_obs_demo)"
echo ""
echo "💡 Tip: Compare how the same traces appear in both UIs!"
echo "    Phoenix shows OpenInference-formatted data with rich LLM context"
echo "    Jaeger shows generic OpenTelemetry spans"
echo ""
