#!/bin/bash
set -e

# Change to demo directory (script can be run from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEMO_DIR"

echo "🚀 Starting AgentObs Demo Environment"
echo "======================================"
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "⚠️  No .env file found. Creating from .env.example..."
    cp .env.example .env
    echo "📝 Please edit .env and add your API keys:"
    echo "   - ANTHROPIC_API_KEY"
    echo "   - OPENAI_API_KEY (optional)"
    echo ""
    echo "Then run this script again."
    exit 1
fi

# Load environment variables
export $(cat .env | grep -v '^#' | xargs)

# Check for required API keys
if [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$OPENAI_API_KEY" ]; then
    echo "❌ Error: No API keys found in .env"
    echo "Please set at least one of:"
    echo "  - ANTHROPIC_API_KEY"
    echo "  - OPENAI_API_KEY"
    exit 1
fi

echo "1️⃣  Starting Docker services..."
docker-compose up -d

echo ""
echo "2️⃣  Waiting for services to be healthy..."
echo -n "   Phoenix: "
until curl -sf http://localhost:6006 > /dev/null 2>&1; do
    echo -n "."
    sleep 1
done
echo " ✓"

echo -n "   Jaeger:  "
until curl -sf http://localhost:16686 > /dev/null 2>&1; do
    echo -n "."
    sleep 1
done
echo " ✓"

echo ""
echo "3️⃣  Installing demo dependencies..."
mix deps.get

echo ""
echo "✅ Demo environment is ready!"
echo ""
echo "📊 Observability UIs:"
echo "  • Arize Phoenix: http://localhost:6006"
echo "  • Jaeger:        http://localhost:16686"
echo ""
echo "▶️  Run demos with:"
echo "   ./scripts/run_demo.sh"
echo ""
echo "🛑 Stop services with:"
echo "   ./scripts/stop.sh"
echo ""
