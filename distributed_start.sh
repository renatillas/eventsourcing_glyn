#!/bin/bash

# Script to start distributed services as connected Erlang nodes
# This enables proper distributed communication via Glyn/syn

echo "🚀 Starting Distributed EventSourcing Services"
echo "==============================================="

# Check if cookie is provided as argument
COOKIE=${1:-"eventsourcing_cluster"}

echo "🍪 Using Erlang cookie: $COOKIE"
echo ""

# Start coordinator service as primary node
echo "1️⃣ Starting Coordinator Service..."
cd examples/distributed_nodes/coordinator
gleam run --target erlang -- --name coordinator@localhost --cookie "$COOKIE" &
COORDINATOR_PID=$!
echo "   ✅ Coordinator started with PID: $COORDINATOR_PID"

# Wait a moment for coordinator to start
sleep 2

# Start inventory service connected to coordinator
echo "2️⃣ Starting Inventory Service..."
cd ../inventory_service
gleam run --target erlang -- --name inventory@localhost --cookie "$COOKIE" &
INVENTORY_PID=$!
echo "   ✅ Inventory started with PID: $INVENTORY_PID"

# Wait a moment
sleep 2

# Start order service connected to cluster
echo "3️⃣ Starting Order Service..."
cd ../order_service  
gleam run --target erlang -- --name order@localhost --cookie "$COOKIE" &
ORDER_PID=$!
echo "   ✅ Order started with PID: $ORDER_PID"

echo ""
echo "🌐 All services started as distributed Erlang nodes!"
echo "📊 Cluster nodes:"
echo "   • coordinator@localhost (PID: $COORDINATOR_PID)"
echo "   • inventory@localhost   (PID: $INVENTORY_PID)"  
echo "   • order@localhost       (PID: $ORDER_PID)"
echo ""
echo "🔗 Services should now be able to discover each other via Glyn/syn"
echo "💡 Press Ctrl+C to stop all services"

# Wait for any service to exit
wait

# Clean up any remaining processes
echo ""
echo "🛑 Stopping all services..."
kill $COORDINATOR_PID $INVENTORY_PID $ORDER_PID 2>/dev/null
echo "✅ All services stopped"