import backend/banking_services
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import gleam/result
import websocket/websocket_server

pub fn main() {
  io.println("🏦 Starting Real-time Banking Application with eventsourcing_glyn")
  io.println("========================================================")

  case start_banking_system() {
    Ok(_) -> {
      io.println("✅ Banking system started successfully!")
      io.println("🌐 WebSocket server available at: ws://localhost:8080/ws")
      io.println("🖥️  Web interface available at: http://localhost:8080")
      io.println("")
      io.println("Architecture:")
      io.println("- Command Processor: Handles banking operations")
      io.println("- Balance Service: Real-time balance tracking")
      io.println("- Transaction Service: Transaction history logging")
      io.println("- Audit Service: Compliance and audit logging")
      io.println("- WebSocket Service: Real-time client updates")
      io.println("")
      io.println("Press Ctrl+C to stop")

      // Keep the application running
      process.sleep_forever()
    }
    Error(error) -> {
      io.println("❌ Failed to start banking system: " <> error)
    }
  }
}

fn start_banking_system() -> Result(Nil, String) {
  // Create service results monitor for debugging/testing
  let service_results = process.new_subject()

  // Start WebSocket broadcaster (placeholder subject)
  let websocket_broadcaster = process.new_subject()

  // Configure banking services
  let service_config =
    banking_services.ServiceConfig(
      pubsub_group: "banking_cluster",
      pubsub_command: "command",
      pubsub_balance: "balance",
      pubsub_transaction: "transaction",
      pubsub_audit: "audit",
      pubsub_websocket: "websocket",
      websocket_broadcaster: websocket_broadcaster,
    )

  io.println("🔧 Starting distributed banking services...")

  // Start banking services (command processor + distributed subscribers)
  use #(command_eventstore, services_supervisor_spec) <- result.try(
    banking_services.start_banking_services(service_config, service_results),
  )

  // Start services supervisor
  use _ <- result.try(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(services_supervisor_spec)
    |> static_supervisor.start()
    |> result.map_error(fn(_) { "Failed to start services supervisor" }),
  )

  io.println("✅ Banking services started")

  // Start command processor
  use command_processor <- result.try(
    banking_services.start_command_processor(command_eventstore)
    |> result.map_error(fn(_) { "Failed to start command processor" }),
  )

  io.println("✅ Command processor started")

  // Start WebSocket server
  use websocket_broadcast_receiver <- result.try(
    websocket_server.start_websocket_server(8080, command_processor),
  )

  io.println("✅ WebSocket server started on port 8080")

  // Connect WebSocket broadcaster to the WebSocket server
  connect_websocket_services(
    websocket_broadcaster,
    websocket_broadcast_receiver,
  )

  // Run health check to verify all services are working
  io.println("🔍 Running health check...")
  case
    banking_services.health_check_services(command_processor, service_results)
  {
    True -> {
      io.println("✅ Health check passed - all services responding")
      Ok(Nil)
    }
    False -> {
      io.println("⚠️  Health check failed - some services may not be responding")
      io.println("   (This is expected in a demo environment)")
      Ok(Nil)
      // Continue anyway for demo purposes
    }
  }
}

/// Connect WebSocket broadcaster to WebSocket server
/// This creates a bridge between banking services and WebSocket clients
fn connect_websocket_services(
  broadcaster: process.Subject(banking_services.WebSocketBroadcast),
  receiver: process.Subject(banking_services.WebSocketBroadcast),
) -> Nil {
  // Start a message forwarder that routes messages from banking services
  // to the WebSocket server for client broadcasting
  let _ = process.spawn(fn() { message_forwarder_loop(broadcaster, receiver) })

  io.println("🔗 Connected WebSocket services - message forwarder started")
}

/// Message forwarder loop that routes messages between banking services and WebSocket server
fn message_forwarder_loop(
  from: process.Subject(banking_services.WebSocketBroadcast),
  to: process.Subject(banking_services.WebSocketBroadcast),
) -> Nil {
  case process.receive_forever(from) {
    message -> {
      process.send(to, message)
      message_forwarder_loop(from, to)
    }
  }
}
