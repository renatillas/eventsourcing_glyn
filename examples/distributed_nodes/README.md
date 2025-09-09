# Distributed EventSourcing Nodes Example

This example demonstrates how to run multiple EventSourcing services as distributed Erlang nodes using `eventsourcing_glyn`. The services can discover and communicate with each other through Glyn's distributed pub/sub system.

## Architecture

The example consists of three services:

- **Inventory Service** (`inventory@localhost`) - Manages product inventory
- **Order Service** (`order@localhost`) - Handles order processing

## Prerequisites

- Gleam installed
- Erlang/OTP installed
- All dependencies resolved (`gleam deps download` in each service directory)

## Running the Services

### Method 1: Individual Services (Manual)

To run each service individually, you need to set the proper Erlang flags for distributed communication:

```bash
# Terminal 1 - Start Inventory Service  
cd examples/distributed_nodes/inventory_service
ERL_FLAGS="-sname inventory@localhost -setcookie eventsourcing" gleam run

# Terminal 2 - Start Order Service
cd examples/distributed_nodes/order_service
ERL_FLAGS="-sname order@localhost -setcookie eventsourcing" gleam run
```

## ERL_FLAGS Explanation

The ERL_FLAGS environment variable configures the Erlang runtime for distributed operation:

- `-sname <name>@localhost` - Sets the short name for this Erlang node
- `-setcookie <cookie>` - Sets the magic cookie for node authentication

**Important**: All nodes in the cluster must use the same cookie to communicate with each other.

## Service Communication

Once all services are running, they will:

1. **Auto-discover** each other through Erlang's distributed node system
2. **Publish/Subscribe** to events across the cluster using Glyn
3. **Coordinate** business operations (e.g., order processing with inventory checks)

