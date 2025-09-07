# eventsourcing_glyn

<div align="center">
  ✨ <strong>Distributed Event Sourcing with Glyn PubSub/Registry</strong> ✨
</div>

<div align="center">
  A Gleam library that enhances event sourcing systems with distributed capabilities using Glyn's type-safe PubSub and Registry features.
</div>

<br />

[![Package Version](https://img.shields.io/hexpm/v/eventsourcing_glyn)](https://hex.pm/packages/eventsourcing_glyn)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/eventsourcing_glyn/)

## Overview

`eventsourcing_glyn` is an integration package that wraps existing event stores with [Glyn](https://github.com/mbuhot/glyn)'s distributed messaging capabilities. It enables:

- **Distributed Query Processing**: Query actors can run on different nodes in a cluster
- **Event Broadcasting**: Events are automatically distributed to all subscribers via PubSub
- **Command Routing**: Aggregate commands can be routed to specific nodes via Registry  
- **Fault Tolerance**: Node failures don't affect the entire query processing pipeline

## Installation

```sh
gleam add eventsourcing_glyn
```

You'll also need the core `eventsourcing` package and an underlying event store:

```sh
gleam add eventsourcing
gleam add eventsourcing_postgres  # or eventsourcing_inmemory, etc.
```

## Quick Start

```gleam
import eventsourcing
import eventsourcing/postgres_store
import eventsourcing/glyn_store
import gleam/otp/static_supervisor
import gleam/erlang/process

pub fn main() {
  // 1. Set up underlying event store (PostgreSQL in this example)
  let assert Ok(#(postgres_store, postgres_spec)) = postgres_store.supervised(
    host: "localhost",
    database: "eventstore",
    // ... other postgres config
  )

  // 2. Configure Glyn for distributed capabilities
  let config = glyn_store.GlynConfig(
    pubsub_topic: "bank_events",
    registry_scope: "bank_aggregates"
  )

  // 3. Define query actors
  let balance_query_name = process.new_name("balance_query")
  let queries = [
    #(balance_query_name, balance_query_function),
  ]

  // 4. Wrap PostgreSQL store with Glyn distributed capabilities
  let assert Ok(#(distributed_store, glyn_spec)) = glyn_store.supervised(
    config,
    postgres_store,
    queries
  )

  // 5. Create main event sourcing system
  let eventsourcing_name = process.new_name("eventsourcing_actor")
  let assert Ok(eventsourcing_spec) = eventsourcing.supervised(
    name: eventsourcing_name,
    eventstore: distributed_store,
    handle: handle_commands,
    apply: apply_events,
    empty_state: UnopenedBankAccount,
    queries: [],  // Queries handled by Glyn
    snapshot_config: None
  )

  // 6. Start supervision tree
  let assert Ok(_supervisor) = static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(postgres_spec)      // PostgreSQL storage
    |> static_supervisor.add(glyn_spec)          // Glyn query actors
    |> static_supervisor.add(eventsourcing_spec) // Event sourcing system
    |> static_supervisor.start()
}
```

## Features

### 🌐 **Distributed Query Processing**
- Query actors automatically subscribe to Glyn PubSub topics
- Events are broadcast to all subscribers across cluster nodes
- Each query actor processes events independently

### 🎯 **Command Routing** 
- Commands can be routed to specific aggregates using Glyn Registry
- Load balancing across nodes for better performance
- Automatic failover if aggregate actors become unavailable

### 🔧 **Event Store Agnostic**
- Works with any existing `eventsourcing.EventStore` implementation
- No changes needed to your existing event sourcing logic
- Composable with memory, PostgreSQL, SQLite, or custom stores

### 🛡️ **Fault Tolerance**
- Node failures don't crash the entire system
- Query processing continues on remaining nodes
- Automatic reconnection and rebalancing

## Configuration

The `GlynConfig` type configures the distributed messaging:

```gleam
pub type GlynConfig {
  GlynConfig(
    pubsub_topic: String,    // PubSub topic for event broadcasting
    registry_scope: String,  // Registry scope for command routing
  )
}
```

## Query Functions

Query functions have the same signature as in core `eventsourcing`:

```gleam
pub type Query(event) = fn(AggregateId, List(EventEnvelop(event))) -> Nil

// Example query function
fn balance_query_function(
  aggregate_id: String, 
  events: List(EventEnvelop(BankAccountEvent))
) -> Nil {
  // Update read models, send notifications, etc.
  events
  |> list.each(fn(event) {
    case event.payload {
      CustomerDepositedCash(amount, new_balance) -> {
        update_balance_view(aggregate_id, new_balance)
      }
      // ... handle other events
    }
  })
}
```

## Examples

### Basic Usage with Memory Store

```gleam
import eventsourcing/memory_store
import eventsourcing/glyn_store

// Set up in-memory store
let events_name = process.new_name("events_actor")
let snapshot_name = process.new_name("snapshot_actor")
let #(memory_store, memory_spec) = memory_store.supervised(
  events_name,
  snapshot_name,
  static_supervisor.OneForOne
)

// Add distributed capabilities
let config = glyn_store.GlynConfig("events", "aggregates")
let queries = [#(process.new_name("query"), my_query)]
let #(distributed_store, glyn_spec) = glyn_store.supervised(
  config,
  memory_store,
  queries
)
```

## Requirements

- **Gleam**: >= 0.52.0
- **eventsourcing**: >= 9.0.0
- **glyn**: >= 2.0.0
- **OTP**: Erlang/OTP 25+

## Testing

This library includes comprehensive test coverage with 20+ test cases covering:

- Core functionality and configuration
- Decoder functions with error handling
- Proxy function delegation
- PubSub event distribution
- Query actor lifecycle management
- Transaction handling
- Integration testing with example domain

```sh
gleam test  # Run the full test suite
gleam build # Build the project
```

## License

This project is licensed under the MIT License.

## Related Packages

- [eventsourcing](https://hex.pm/packages/eventsourcing) - Core event sourcing library
- [glyn](https://hex.pm/packages/glyn) - Type-safe PubSub and Registry for Gleam
