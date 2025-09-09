import eventsourcing
import eventsourcing/memory_store
import eventsourcing_glyn
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import order_service/order

pub type InventoryCommand {
  ReserveStock(product_id: String, quantity: Int, order_id: String)
}

pub fn inventory_coordination_query(
  pubsub,
) -> fn(String, List(eventsourcing.EventEnvelop(order.Event))) -> Nil {
  fn(_: String, events: List(eventsourcing.EventEnvelop(order.Event))) -> Nil {
    list.each(events, fn(event) {
      case event.payload {
        order.OrderCreated(order_id, _, _) -> {
          io.println(
            "🛒 Order created: "
            <> order_id
            <> ", requesting inventory reservation",
          )
          let assert Ok(1) =
            eventsourcing_glyn.publish(
              pubsub,
              "inventory",
              eventsourcing.ProcessEvents(event.aggregate_id, events: [
                event,
              ]),
            )
          Nil
        }
        order.OrderConfirmed(order_id) -> {
          io.println("✅ Order confirmed: " <> order_id)
        }
        order.OrderCancelled(order_id, reason) -> {
          io.println("❌ Order cancelled: " <> order_id <> " - " <> reason)
        }
      }
    })
  }
}

pub fn main() {
  io.println("🚀 Starting Order Service...")

  // Set up memory-based event store
  let events_name = process.new_name("order_events")
  let snapshot_name = process.new_name("order_snapshots")
  let #(memory_store, memory_spec) =
    memory_store.supervised(
      events_name,
      snapshot_name,
      static_supervisor.OneForOne,
    )

  let glyn_config =
    eventsourcing_glyn.GlynConfig(
      pubsub_scope: "example",
      pubsub_group: "registry",
    )

  // Define query actors for cross-service coordination
  let inventory_query_name = process.new_name("inventory_coordination")

  // Create distributed event store with Glyn
  let assert Ok(#(distributed_store, glyn_spec)) =
    eventsourcing_glyn.supervised(
      glyn_config,
      memory_store,
      [],
      order.decode_order_event(),
    )
  let queries = [
    #(
      inventory_query_name,
      inventory_coordination_query(distributed_store.eventstore),
    ),
  ]

  // Create main order service with event sourcing
  let order_service_name = process.new_name("order_service")
  let assert Ok(order_spec) =
    eventsourcing.supervised(
      name: order_service_name,
      eventstore: distributed_store,
      handle: order.handle_order_command,
      apply: order.apply_order_event,
      empty_state: order.NotFound,
      queries: queries,
      snapshot_config: None,
    )

  // Start supervision tree
  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_spec)
    |> static_supervisor.add(glyn_spec)
    |> static_supervisor.add(order_spec)
    |> static_supervisor.start()

  // Connect to inventory service node
  case node.connect(atom.create("inventory@localhost")) {
    Ok(_) -> io.println("🔗 Connected to inventory service")
    Error(_) -> io.println("⚠️  Could not connect to inventory service")
  }

  // Give some time for syn to discover the cluster
  process.sleep(1000)

  // Demo: Create a sample order
  create_demo_order(order_service_name)

  eventsourcing_glyn.subscribers(distributed_store.eventstore)
  // Keep the service running
  process.sleep_forever()
}

fn create_demo_order(
  order_service: process.Name(
    eventsourcing.AggregateMessage(
      order.State,
      order.Command,
      order.Event,
      String,
    ),
  ),
) {
  let order_items = [
    order.Item(order.Product("laptop", "Gaming Laptop", 20), 1),
    order.Item(order.Product("mouse", "Gaming Mouse", 10), 2),
  ]

  let command = order.CreateOrder("order_001", order_items)

  eventsourcing.execute(
    process.named_subject(order_service),
    "order_001",
    command,
  )

  io.println("📦 Demo order created: order_001 with laptop and mouse")
}
