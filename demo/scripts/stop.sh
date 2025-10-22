#!/bin/bash
set -e

# Change to demo directory (script can be run from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEMO_DIR"

echo "🛑 Stopping AgentObs Demo Environment"
echo "====================================="
echo ""

docker-compose down

echo ""
echo "✅ All services stopped"
echo ""
echo "💡 Data in observability platforms is lost (in-memory storage)"
echo "   Restart with: ./scripts/start.sh"
echo ""
