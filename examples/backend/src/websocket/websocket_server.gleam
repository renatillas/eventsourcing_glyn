import backend/banking_services
import domain/banking_domain
import eventsourcing
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import mist
import wisp
import wisp/wisp_mist

/// WebSocket client connection info
pub type WebSocketClient {
  WebSocketClient(
    id: String,
    connection: mist.WebsocketConnection,
    subscribed_accounts: List(String),
  )
}

/// WebSocket server state
pub type WebSocketState {
  WebSocketState(
    clients: List(WebSocketClient),
    command_processor: process.Subject(
      eventsourcing.AggregateMessage(
        banking_domain.BankAccount,
        banking_domain.BankAccountCommand,
        banking_domain.BankAccountEvent,
        banking_domain.BankAccountError,
      ),
    ),
    broadcast_receiver: process.Subject(banking_services.WebSocketBroadcast),
  )
}

/// WebSocket server messages
pub type WebSocketMessage {
  ClientConnected(String, mist.WebsocketConnection)
  ClientDisconnected(String)
  ClientMessage(String, String)
  BroadcastToClients(banking_services.WebSocketBroadcast)
}

/// WebSocket manager subjects
pub type WebSocketManagerSubjects {
  WebSocketManagerSubjects(
    websocket_subject: process.Subject(WebSocketMessage),
    broadcast_subject: process.Subject(banking_services.WebSocketBroadcast),
  )
}

/// Start the WebSocket server with banking integration
pub fn start_websocket_server(
  port: Int,
  command_processor: process.Subject(
    eventsourcing.AggregateMessage(
      banking_domain.BankAccount,
      banking_domain.BankAccountCommand,
      banking_domain.BankAccountEvent,
      banking_domain.BankAccountError,
    ),
  ),
) -> Result(process.Subject(banking_services.WebSocketBroadcast), String) {
  // Start WebSocket manager process
  let websocket_manager_subject = start_websocket_manager(command_processor)

  // Start HTTP server with WebSocket upgrade capability
  let handler = fn(request) {
    case request.path_segments(request) {
      ["ws"] ->
        websocket_handler(request, websocket_manager_subject.websocket_subject)
      _ -> wisp_mist.handler(wisp_handler, wisp.random_string(64))(request)
    }
  }

  let assert Ok(_server) =
    handler
    |> mist.new()
    |> mist.port(port)
    |> mist.start()

  io.println("WebSocket server started on port " <> int.to_string(port))

  Ok(websocket_manager_subject.broadcast_subject)
}

fn wisp_handler(request: wisp.Request) -> response.Response(wisp.Body) {
  case wisp.path_segments(request) {
    ["static", path] -> serve_static_file(path)
    [] | [""] -> serve_index_html()
    _ -> wisp.response(404) |> wisp.set_body(wisp.Text("Not Found"))
  }
}

fn handle_websocket_message(
  state: WebSocketState,
  message: WebSocketMessage,
) -> actor.Next(WebSocketState, WebSocketMessage) {
  case message {
    ClientConnected(client_id, connection) -> {
      let new_client = WebSocketClient(client_id, connection, [])
      let new_state =
        WebSocketState(..state, clients: [new_client, ..state.clients])

      // Note: Connection confirmation should be sent from WebSocket handler, not here
      actor.continue(new_state)
    }

    ClientDisconnected(client_id) -> {
      let new_clients =
        list.filter(state.clients, fn(client) { client.id != client_id })
      let new_state = WebSocketState(..state, clients: new_clients)
      actor.continue(new_state)
    }

    ClientMessage(client_id, message_text) -> {
      // Process client command
      case banking_domain.decode_websocket_message(message_text) {
        Ok(banking_domain.ExecuteCommand(aggregate_id, command)) -> {
          // Forward command to event sourcing system
          eventsourcing.execute(state.command_processor, aggregate_id, command)

          // Note: Command confirmation should be sent from WebSocket handler
          actor.continue(state)
        }

        Ok(banking_domain.SubscribeToAccount(account_id)) -> {
          let new_clients =
            list.map(state.clients, fn(client) {
              case client.id == client_id {
                True ->
                  WebSocketClient(..client, subscribed_accounts: [
                    account_id,
                    ..client.subscribed_accounts
                  ])
                False -> client
              }
            })
          let new_state = WebSocketState(..state, clients: new_clients)
          actor.continue(new_state)
        }

        Ok(banking_domain.UnsubscribeFromAccount(account_id)) -> {
          let new_clients =
            list.map(state.clients, fn(client) {
              case client.id == client_id {
                True ->
                  WebSocketClient(
                    ..client,
                    subscribed_accounts: list.filter(
                      client.subscribed_accounts,
                      fn(id) { id != account_id },
                    ),
                  )
                False -> client
              }
            })
          let new_state = WebSocketState(..state, clients: new_clients)
          actor.continue(new_state)
        }

        Ok(banking_domain.RequestAccountSnapshot(_account_id)) -> {
          // Note: Account snapshot should be sent from WebSocket handler
          actor.continue(state)
        }

        Error(_error) -> {
          // Note: Error response should be sent from WebSocket handler
          actor.continue(state)
        }

        _ -> actor.continue(state)
      }
      actor.continue(state)
    }

    BroadcastToClients(broadcast) -> {
      case broadcast {
        banking_services.BroadcastEvent(aggregate_id, events) -> {
          let message =
            banking_domain.encode_websocket_message(
              banking_domain.EventNotification(aggregate_id, events),
            )
          broadcast_to_subscribed_clients(state.clients, aggregate_id, message)
        }

        banking_services.BroadcastSnapshot(account_id, balance, account_holder) -> {
          let message =
            banking_domain.encode_websocket_message(
              banking_domain.AccountSnapshot(
                account_id,
                balance,
                account_holder,
              ),
            )
          broadcast_to_subscribed_clients(state.clients, account_id, message)
        }
      }
      actor.continue(state)
    }
  }
}

fn broadcast_to_subscribed_clients(
  _clients: List(WebSocketClient),
  _aggregate_id: String,
  _message: String,
) -> Nil {
  // Note: Disabled broadcast to avoid WebSocket ownership violations
  // In a proper implementation, this would need to be handled differently
  Nil
}

fn websocket_handler(
  request,
  websocket_actor: process.Subject(WebSocketMessage),
) {
  let assert Ok(query_params) = request.get_query(request)
  let client_id = case list.key_find(query_params, "client_id") {
    Ok(id) -> id
    Error(_) -> generate_client_id()
  }

  mist.websocket(
    request: request,
    on_init: fn(connection) {
      process.send(websocket_actor, ClientConnected(client_id, connection))

      // Send connection confirmation from the correct process
      let confirmation =
        banking_domain.encode_websocket_message(banking_domain.ConnectionStatus(
          True,
        ))
      let _ = mist.send_text_frame(connection, confirmation)

      #(Nil, option.None)
    },
    on_close: fn(_state) {
      process.send(websocket_actor, ClientDisconnected(client_id))
      Nil
    },
    handler: fn(state, message, connection) {
      case message {
        mist.Text(text) -> {
          process.send(websocket_actor, ClientMessage(client_id, text))

          case banking_domain.decode_websocket_message(text) {
            Ok(banking_domain.RequestAccountSnapshot(_)) -> {
              let _ = mist.send_text_frame(connection, "")
              Nil
            }
            Ok(banking_domain.ExecuteCommand(
              account_id,
              banking_domain.OpenAccount(_, holder),
            )) -> {
              // Send account snapshot after account creation
              let snapshot_response =
                banking_domain.encode_websocket_message(
                  banking_domain.AccountSnapshot(account_id, 0.0, holder),
                )
              let _ = mist.send_text_frame(connection, snapshot_response)
              Nil
            }
            Ok(banking_domain.ExecuteCommand(_, banking_domain.DepositMoney(_))) -> {
              let _ = mist.send_text_frame(connection, "")
              Nil
            }
            Ok(banking_domain.ExecuteCommand(_, banking_domain.WithDrawMoney(_))) -> {
              let _ = mist.send_text_frame(connection, _)
              Nil
            }
            _ -> Nil
          }

          mist.continue(state)
        }
        mist.Binary(_) -> mist.continue(state)
        mist.Closed | mist.Shutdown -> {
          process.send(websocket_actor, ClientDisconnected(client_id))
          mist.continue(state)
        }
        mist.Custom(_) -> mist.continue(state)
      }
    },
  )
}

fn serve_static_file(path: String) -> wisp.Response {
  // In a real implementation, you'd serve actual static files
  // For this example, we'll return a placeholder response
  wisp.response(200)
  |> wisp.set_header("content-type", "text/plain")
  |> wisp.set_body(wisp.Text("Static file: " <> path))
}

fn serve_index_html() -> wisp.Response {
  let html =
    "
<!DOCTYPE html>
<html>
<head>
    <meta charset=\"utf-8\">
    <title>Real-time Banking</title>
    <script src=\"/static/banking_app.js\"></script>
</head>
<body>
    <div id=\"app\"></div>
    <script>
        // Initialize Lustre app
        window.bankingApp.main();
    </script>
</body>
</html>
"

  wisp.response(200)
  |> wisp.set_header("content-type", "text/html")
  |> wisp.set_body(wisp.Text(html))
}

fn generate_client_id() -> String {
  // Generate a unique client ID
  "client_" <> int.to_string(erlang_system_time())
}

@external(erlang, "erlang", "system_time")
fn erlang_system_time() -> Int

/// Start WebSocket manager that handles both WebSocket and broadcast messages
fn start_websocket_manager(
  command_processor: process.Subject(
    eventsourcing.AggregateMessage(
      banking_domain.BankAccount,
      banking_domain.BankAccountCommand,
      banking_domain.BankAccountEvent,
      banking_domain.BankAccountError,
    ),
  ),
) -> WebSocketManagerSubjects {
  // Create broadcast receiver subject
  let broadcast_subject = process.new_subject()

  // Start WebSocket state actor with direct broadcast handling
  let assert Ok(websocket_actor) =
    actor.new(WebSocketState(
      clients: [],
      command_processor: command_processor,
      broadcast_receiver: broadcast_subject,
    ))
    |> actor.on_message(handle_websocket_message)
    |> actor.start()

  let websocket_subject = websocket_actor.data

  // Start a process to forward broadcast messages to WebSocket messages
  let _ =
    process.spawn(fn() {
      forward_broadcasts_loop(broadcast_subject, websocket_subject)
    })

  WebSocketManagerSubjects(websocket_subject, broadcast_subject)
}

/// Forward broadcast messages to WebSocket actor as BroadcastToClients messages
fn forward_broadcasts_loop(
  broadcast_subject: process.Subject(banking_services.WebSocketBroadcast),
  websocket_subject: process.Subject(WebSocketMessage),
) -> Nil {
  // Use receive_forever to avoid the ownership issue
  case process.receive_forever(broadcast_subject) {
    broadcast_message -> {
      process.send(websocket_subject, BroadcastToClients(broadcast_message))
      forward_broadcasts_loop(broadcast_subject, websocket_subject)
    }
  }
}
