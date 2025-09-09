import eventsourcing
import eventsourcing/memory_store
import eventsourcing_glyn
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import inventory_service/inventory

// Query function to listen for order events and react
pub fn order_events_query(
  _: String,
  events: List(eventsourcing.EventEnvelop(inventory.InventoryEvent)),
) -> Nil {
  list.each(events, fn(event) {
    case event.payload {
      inventory.OrderCreated(order_id, items, total) -> {
        io.println("🛒 New order created: " <> order_id)
        list.each(items, fn(item) {
          io.println(
            "   - "
            <> item.product.name
            <> " (qty: "
            <> int.to_string(item.quantity)
            <> ")"
            <> " | Total: "
            <> int.to_string(total),
          )
        })
      }
      inventory.InventoryInitialized(items) -> {
        io.println("📦 Inventory initialized with items:")
        list.each(items, fn(item) {
          io.println(
            "   - "
            <> item.name
            <> " (qty: "
            <> int.to_string(item.stock_level)
            <> ")",
          )
        })
      }
      _ -> Nil
    }
  })
}

pub fn main() {
  io.println("🏪 Starting Inventory Service...")

  // Set up memory-based event store
  let events_name = process.new_name("inventory_events")
  let snapshot_name = process.new_name("inventory_snapshots")
  let #(memory_store, memory_spec) =
    memory_store.supervised(
      events_name,
      snapshot_name,
      static_supervisor.OneForOne,
    )

  // Configure Glyn for distributed capabilities with built-in distributed service discovery
  let glyn_config =
    eventsourcing_glyn.GlynConfig(
      pubsub_scope: "example",
      pubsub_group: "inventory",
    )

  // Define query actors for cross-service coordination
  let order_coordination_name = process.new_name("order_coordination")
  let queries = [
    #(order_coordination_name, order_events_query),
  ]

  // Create distributed event store with Glyn
  let assert Ok(#(distributed_store, glyn_spec)) =
    eventsourcing_glyn.supervised(
      glyn_config,
      memory_store,
      queries,
      inventory.decode_inventory_event(),
    )

  // Create main inventory service with event sourcing
  let inventory_service_name = process.new_name("inventory_service")
  let assert Ok(inventory_spec) =
    eventsourcing.supervised(
      name: inventory_service_name,
      eventstore: distributed_store,
      handle: inventory.handle_inventory_command,
      apply: inventory.apply_inventory_event,
      empty_state: inventory.InventoryNotFound,
      queries: [],
      snapshot_config: None,
    )

  // Start supervision tree
  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_spec)
    |> static_supervisor.add(glyn_spec)
    |> static_supervisor.add(inventory_spec)
    |> static_supervisor.start()

  // Demo: Initialize inventory with sample data
  initialize_demo_inventory(inventory_service_name)

  // Keep the service running
  process.sleep_forever()
}

fn initialize_demo_inventory(
  inventory_service: process.Name(
    eventsourcing.AggregateMessage(a, inventory.InventoryCommand, b, c),
  ),
) -> Nil {
  let inventory_items = [
    inventory.Item("laptop", "Gaming Laptop", 10, 0),
    inventory.Item("mouse", "Gaming Mouse", 50, 0),
    inventory.Item("keyboard", "Gaming Keyboard", 30, 0),
  ]

  let command = inventory.InitializeInventory(inventory_items)

  eventsourcing.execute(
    process.named_subject(inventory_service),
    "inventory_001",
    command,
  )
  io.println("📦 Demo inventory initialized with laptops, mice, and keyboards")
}
