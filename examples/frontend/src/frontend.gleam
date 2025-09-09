import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import gleam/time/timestamp
import lustre
import lustre/attribute
import lustre/effect
import lustre/element
import lustre/element/html
import lustre/event
import lustre_websocket as ws

/// Application model - represents the entire app state
pub type Model {
  Model(
    // WebSocket connection
    websocket: Option(ws.WebSocket),
    connection_status: ConnectionStatus,
    // Account data
    accounts: dict.Dict(String, AccountData),
    current_account: Option(String),
    // UI state
    deposit_amount: String,
    withdraw_amount: String,
    new_account_id: String,
    new_account_holder: String,
    // Transaction history
    recent_transactions: List(TransactionRecord),
    // Error handling
    last_error: Option(String),
  )
}

pub type ConnectionStatus {
  Disconnected
  Connecting
  Connected
  Reconnecting
}

pub type AccountData {
  AccountData(
    account_id: String,
    account_holder: String,
    balance: Float,
    last_updated: Int,
  )
}

pub type TransactionRecord {
  TransactionRecord(
    account_id: String,
    transaction_type: String,
    amount: Float,
    new_balance: Float,
    timestamp: Int,
  )
}

/// Application messages
pub type Msg {
  // WebSocket events
  WebSocketMsg(ws.WebSocketEvent)

  // User interactions
  ConnectWebSocket
  SetCurrentAccount(String)
  SetDepositAmount(String)
  SetWithdrawAmount(String)
  SetNewAccountId(String)
  SetNewAccountHolder(String)

  // Banking operations
  CreateAccount
  DepositMoney
  WithdrawMoney
  SubscribeToAccount(String)
  UnsubscribeFromAccount(String)
  RequestSnapshot(String)

  // System events
  UpdateAccountBalance(String, Float, String)
  AddTransaction(TransactionRecord)
  ClearError
  SystemTime(Int)
}

/// Initialize the application
pub fn init(_flags) -> #(Model, effect.Effect(Msg)) {
  let initial_model =
    Model(
      websocket: None,
      connection_status: Disconnected,
      accounts: dict.new(),
      current_account: None,
      deposit_amount: "",
      withdraw_amount: "",
      new_account_id: "",
      new_account_holder: "",
      recent_transactions: [],
      last_error: None,
    )

  #(initial_model, effect.none())
}

/// Update function - handles all application messages
pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    ConnectWebSocket -> {
      let new_model = Model(..model, connection_status: Connecting)
      let connect_effect = ws.init("ws://localhost:8080/ws", WebSocketMsg)
      #(new_model, connect_effect)
    }

    WebSocketMsg(ws_event) -> {
      case ws_event {
        ws.OnOpen(socket) -> {
          let new_model =
            Model(
              ..model,
              websocket: Some(socket),
              connection_status: Connected,
              last_error: Some("DEBUG: WebSocket connected successfully"),
            )
          #(new_model, effect.none())
        }

        ws.OnClose(_reason) -> {
          let new_model =
            Model(..model, websocket: None, connection_status: Disconnected)
          #(new_model, effect.none())
        }

        ws.OnTextMessage(message) -> {
          handle_websocket_message(model, message)
        }

        ws.OnBinaryMessage(_data) -> {
          #(model, effect.none())
        }

        ws.InvalidUrl -> {
          let new_model =
            Model(
              ..model,
              connection_status: Disconnected,
              last_error: Some("Invalid WebSocket URL"),
            )
          #(new_model, effect.none())
        }
      }
    }

    SetCurrentAccount(account_id) -> {
      let new_model =
        Model(
          ..model,
          current_account: Some(account_id),
          last_error: Some("DEBUG: Selected account: " <> account_id),
        )
      let subscribe_effect = case model.websocket {
        Some(socket) ->
          send_websocket_message_effect(
            socket,
            json.object([
              #("type", json.string("subscribe_account")),
              #("account_id", json.string(account_id)),
            ]),
          )
        None -> effect.none()
      }
      #(new_model, subscribe_effect)
    }

    SetDepositAmount(amount) -> {
      #(Model(..model, deposit_amount: amount), effect.none())
    }

    SetWithdrawAmount(amount) -> {
      #(Model(..model, withdraw_amount: amount), effect.none())
    }

    SetNewAccountId(id) -> {
      #(Model(..model, new_account_id: id), effect.none())
    }

    SetNewAccountHolder(holder) -> {
      #(Model(..model, new_account_holder: holder), effect.none())
    }

    CreateAccount -> {
      case model.websocket {
        None -> {
          let error = "WebSocket not connected - please connect first"
          #(Model(..model, last_error: Some(error)), effect.none())
        }
        Some(socket) -> {
          case
            string.length(model.new_account_id) > 0,
            string.length(model.new_account_holder) > 0
          {
            True, True -> {
              let command =
                json.object([
                  #("type", json.string("execute_command")),
                  #("aggregate_id", json.string(model.new_account_id)),
                  #(
                    "command",
                    json.object([
                      #("type", json.string("open_account")),
                      #("account_id", json.string(model.new_account_id)),
                      #("account_holder", json.string(model.new_account_holder)),
                    ]),
                  ),
                ])

              let new_model =
                Model(..model, new_account_id: "", new_account_holder: "")

              // Send create account command and then request snapshot
              let create_effect = send_websocket_message_effect(socket, command)
              let snapshot_request =
                json.object([
                  #("type", json.string("request_snapshot")),
                  #("account_id", json.string(model.new_account_id)),
                ])
              let snapshot_effect =
                send_websocket_message_effect(socket, snapshot_request)

              #(new_model, effect.batch([create_effect, snapshot_effect]))
            }
            False, True -> {
              let error =
                "Please fill in the account ID field (current: '"
                <> model.new_account_id
                <> "')"
              #(Model(..model, last_error: Some(error)), effect.none())
            }
            True, False -> {
              let error =
                "Please fill in the account holder name field (current: '"
                <> model.new_account_holder
                <> "')"
              #(Model(..model, last_error: Some(error)), effect.none())
            }
            False, False -> {
              let error =
                "Please fill in both account ID ('"
                <> model.new_account_id
                <> "') and account holder name ('"
                <> model.new_account_holder
                <> "')"
              #(Model(..model, last_error: Some(error)), effect.none())
            }
          }
        }
      }
    }

    DepositMoney -> {
      // Debug the deposit conditions
      let ws_status = case model.websocket {
        Some(_) -> "✅ WebSocket"
        None -> "❌ No WebSocket"
      }
      let account_status = case model.current_account {
        Some(id) -> "✅ Account: " <> id
        None -> "❌ No Account"
      }
      let parsed_amount = case float.parse(model.deposit_amount) {
        Ok(amount) -> Ok(amount)
        Error(_) -> 
          model.deposit_amount |> int.parse |> result.map(int.to_float)
      }
      let amount_status = case parsed_amount {
        Ok(amount) if amount >. 0.0 -> "✅ Amount: " <> float.to_string(amount)
        Ok(amount) -> "❌ Amount not positive: " <> float.to_string(amount)
        Error(_) -> "❌ Invalid amount: '" <> model.deposit_amount <> "'"
      }

      case model.websocket, model.current_account, parsed_amount {
        Some(socket), Some(account_id), Ok(amount) if amount >. 0.0 -> {
          let command =
            json.object([
              #("type", json.string("execute_command")),
              #("aggregate_id", json.string(account_id)),
              #(
                "command",
                json.object([
                  #("type", json.string("deposit")),
                  #("amount", json.float(amount)),
                ]),
              ),
            ])

          let new_model = Model(..model, deposit_amount: "")
          #(new_model, send_websocket_message_effect(socket, command))
        }
        _, _, _ -> {
          let error =
            "Deposit failed - "
            <> ws_status
            <> " | "
            <> account_status
            <> " | "
            <> amount_status
          #(Model(..model, last_error: Some(error)), effect.none())
        }
      }
    }

    WithdrawMoney -> {
      let parsed_amount = case float.parse(model.withdraw_amount) {
        Ok(amount) -> Ok(amount)
        Error(_) -> 
          model.withdraw_amount |> int.parse |> result.map(int.to_float)
      }
      case
        model.websocket,
        model.current_account,
        parsed_amount
      {
        Some(socket), Some(account_id), Ok(amount) if amount >. 0.0 -> {
          let command =
            json.object([
              #("type", json.string("execute_command")),
              #("aggregate_id", json.string(account_id)),
              #(
                "command",
                json.object([
                  #("type", json.string("withdraw")),
                  #("amount", json.float(amount)),
                ]),
              ),
            ])

          let new_model = Model(..model, withdraw_amount: "")
          #(new_model, send_websocket_message_effect(socket, command))
        }
        _, _, _ -> {
          let error =
            "Please enter a valid positive amount and select an account"
          #(Model(..model, last_error: Some(error)), effect.none())
        }
      }
    }

    UpdateAccountBalance(account_id, balance, account_holder) -> {
      let account_data =
        AccountData(account_id, account_holder, balance, current_timestamp())
      let new_accounts = dict.insert(model.accounts, account_id, account_data)
      let new_model = Model(..model, accounts: new_accounts)
      #(new_model, effect.none())
    }

    AddTransaction(transaction) -> {
      let new_transactions = [
        transaction,
        ..list.take(model.recent_transactions, 19)
      ]
      let new_model = Model(..model, recent_transactions: new_transactions)
      #(new_model, effect.none())
    }

    ClearError -> {
      #(Model(..model, last_error: None), effect.none())
    }

    _ -> #(model, effect.none())
  }
}

fn handle_websocket_message(
  model: Model,
  message: String,
) -> #(Model, effect.Effect(Msg)) {
  // Debug: show all received messages
  let debug_model =
    Model(..model, last_error: Some("DEBUG: Received: " <> message))

  // Parse the incoming WebSocket message
  case parse_websocket_response(message) {
    Ok(parsed_message) -> {
      case parsed_message {
        "event_notification" -> {
          // Handle event notification from backend
          handle_event_notification(debug_model, message)
        }
        "account_snapshot" -> {
          // Handle account snapshot from backend
          handle_account_snapshot(debug_model, message)
        }
        "command_result" -> {
          // Handle command execution result
          handle_command_result(debug_model, message)
        }
        "connection_status" -> {
          // Handle connection status update
          #(debug_model, effect.none())
        }
        _ -> #(debug_model, effect.none())
      }
    }
    Error(error) -> {
      let new_model =
        Model(
          ..model,
          last_error: Some(
            "Failed to parse WebSocket message: "
            <> error
            <> " | Message: "
            <> message,
          ),
        )
      #(new_model, effect.none())
    }
  }
}

fn parse_websocket_response(message: String) -> Result(String, String) {
  // Simple JSON parsing to extract message type
  // In a real implementation, you'd use proper JSON parsing
  case string.contains(message, "\"type\":\"event_notification\"") {
    True -> Ok("event_notification")
    False ->
      case string.contains(message, "\"type\":\"account_snapshot\"") {
        True -> Ok("account_snapshot")
        False ->
          case string.contains(message, "\"type\":\"command_result\"") {
            True -> Ok("command_result")
            False ->
              case string.contains(message, "\"type\":\"connection_status\"") {
                True -> Ok("connection_status")
                False -> Error("Unknown message type")
              }
          }
      }
  }
}

fn parse_account_snapshot(
  message: String,
) -> Result(#(String, String, Float), String) {
  // Simple parsing for account snapshot messages
  // Expected format: {"type":"account_snapshot","account_id":"...","balance":0.0,"account_holder":"..."}

  // Extract account_id
  let account_id = case string.split(message, "\"account_id\":\"") {
    [_, rest, ..] ->
      case string.split(rest, "\"") {
        [id, ..] -> Ok(id)
        _ -> Error("Could not parse account_id")
      }
    _ -> Error("account_id not found")
  }

  // Extract account_holder
  let account_holder = case string.split(message, "\"account_holder\":\"") {
    [_, rest, ..] ->
      case string.split(rest, "\"") {
        [holder, ..] -> Ok(holder)
        _ -> Error("Could not parse account_holder")
      }
    _ -> Error("account_holder not found")
  }

  // Extract balance
  let balance = case string.split(message, "\"balance\":") {
    [_, rest, ..] ->
      case string.split(rest, ",") {
        [balance_str, ..] ->
          case string.split(balance_str, "}") {
            [balance_str, ..] ->
              case float.parse(balance_str) {
                Ok(balance) -> Ok(balance)
                Error(_) -> Error("Could not parse balance as float")
              }
            _ -> Error("Could not extract balance")
          }
        _ ->
          case float.parse(rest) {
            Ok(balance) -> Ok(balance)
            Error(_) -> Error("Could not parse balance")
          }
      }
    _ -> Error("balance not found")
  }

  // Combine results
  case account_id, account_holder, balance {
    Ok(id), Ok(holder), Ok(bal) -> Ok(#(id, holder, bal))
    Error(e), _, _ -> Error(e)
    _, Error(e), _ -> Error(e)
    _, _, Error(e) -> Error(e)
  }
}

fn handle_event_notification(
  model: Model,
  _message: String,
) -> #(Model, effect.Effect(Msg)) {
  // Parse event notification and update model accordingly
  // This is a simplified version - in reality you'd parse the full JSON
  let new_model = model
  // Placeholder
  #(new_model, effect.none())
}

fn handle_account_snapshot(
  model: Model,
  message: String,
) -> #(Model, effect.Effect(Msg)) {
  // Parse account snapshot JSON and extract account info
  case parse_account_snapshot(message) {
    Ok(#(account_id, account_holder, balance)) -> {
      let account_data =
        AccountData(account_id, account_holder, balance, current_timestamp())
      let new_accounts = dict.insert(model.accounts, account_id, account_data)
      let new_model = Model(..model, accounts: new_accounts, last_error: None)
      #(new_model, effect.none())
    }
    Error(error) -> {
      let new_model =
        Model(
          ..model,
          last_error: Some("Failed to parse account snapshot: " <> error),
        )
      #(new_model, effect.none())
    }
  }
}

fn handle_command_result(
  model: Model,
  _message: String,
) -> #(Model, effect.Effect(Msg)) {
  // Parse command result and show success/error messages
  let new_model = model
  // Placeholder
  #(new_model, effect.none())
}

/// Render the application UI
pub fn view(model: Model) -> element.Element(Msg) {
  html.div([], [
    render_header(model),
    render_connection_status(model),
    render_error_message(model),
    render_account_creation(model),
    render_account_selector(model),
    render_account_details(model),
    render_transaction_controls(model),
    render_transaction_history(model),
  ])
}

fn render_header(_model: Model) -> element.Element(Msg) {
  html.div([attribute.class("header")], [
    html.h1([], [element.text("Real-time Banking with eventsourcing_glyn")]),
    html.p([], [
      element.text(
        "Demonstrating distributed event sourcing with WebSocket integration",
      ),
    ]),
  ])
}

fn render_connection_status(model: Model) -> element.Element(Msg) {
  let status_text = case model.connection_status {
    Connected -> "Connected to real-time updates"
    Connecting -> "Connecting..."
    Reconnecting -> "Reconnecting..."
    Disconnected -> "Disconnected - Click to connect"
  }

  let status_class = case model.connection_status {
    Connected -> "status connected"
    Connecting | Reconnecting -> "status connecting"
    Disconnected -> "status disconnected"
  }

  html.div([attribute.class(status_class)], [
    element.text(status_text),
    case model.connection_status {
      Disconnected ->
        html.button([event.on_click(ConnectWebSocket)], [
          element.text("Connect"),
        ])
      _ -> element.text("")
    },
  ])
}

fn render_error_message(model: Model) -> element.Element(Msg) {
  case model.last_error {
    Some(error) ->
      html.div([attribute.class("error")], [
        element.text(error),
        html.button([event.on_click(ClearError)], [element.text("×")]),
      ])
    None -> element.text("")
  }
}

fn render_account_creation(model: Model) -> element.Element(Msg) {
  html.div([attribute.class("account-creation")], [
    html.h3([], [element.text("Create New Account")]),
    html.input([
      attribute.placeholder("Account ID"),
      attribute.value(model.new_account_id),
      event.on_input(SetNewAccountId),
    ]),
    html.input([
      attribute.placeholder("Account Holder Name"),
      attribute.value(model.new_account_holder),
      event.on_input(SetNewAccountHolder),
    ]),
    html.button([event.on_click(CreateAccount)], [
      element.text("Create Account"),
    ]),
  ])
}

fn render_account_selector(model: Model) -> element.Element(Msg) {
  let account_options =
    dict.to_list(model.accounts)
    |> list.map(fn(account_pair) {
      let #(account_id, account_data) = account_pair
      html.option(
        [attribute.value(account_id)],
        account_data.account_holder <> " (" <> account_id <> ")",
      )
    })

  html.div([attribute.class("account-selector")], [
    html.h3([], [element.text("Select Account")]),
    html.select([event.on_change(SetCurrentAccount)], [
      html.option([attribute.value("")], "Select an account..."),
      ..account_options
    ]),
  ])
}

fn render_account_details(model: Model) -> element.Element(Msg) {
  case model.current_account {
    Some(account_id) -> {
      case dict.get(model.accounts, account_id) {
        Ok(account_data) ->
          html.div([attribute.class("account-details")], [
            html.h3([], [element.text("Account Details")]),
            html.p([], [
              element.text("Account: " <> account_data.account_holder),
            ]),
            html.p([], [
              element.text(
                "Balance: $" <> float.to_string(account_data.balance),
              ),
            ]),
            html.p([], [element.text("ID: " <> account_data.account_id)]),
          ])
        Error(_) -> element.text("Account not found")
      }
    }
    None -> element.text("")
  }
}

fn render_transaction_controls(model: Model) -> element.Element(Msg) {
  case model.current_account {
    Some(_) ->
      html.div([attribute.class("transaction-controls")], [
        html.h3([], [element.text("Transactions")]),
        html.div([attribute.class("transaction-row")], [
          html.input([
            attribute.placeholder("Deposit amount"),
            attribute.value(model.deposit_amount),
            attribute.type_("number"),
            attribute.step("0.01"),
            event.on_input(SetDepositAmount),
          ]),
          html.button([event.on_click(DepositMoney)], [element.text("Deposit")]),
        ]),
        html.div([attribute.class("transaction-row")], [
          html.input([
            attribute.placeholder("Withdraw amount"),
            attribute.value(model.withdraw_amount),
            attribute.type_("number"),
            attribute.step("0.01"),
            event.on_input(SetWithdrawAmount),
          ]),
          html.button([event.on_click(WithdrawMoney)], [
            element.text("Withdraw"),
          ]),
        ]),
      ])
    None -> element.text("")
  }
}

fn render_transaction_history(model: Model) -> element.Element(Msg) {
  let transaction_items =
    list.map(model.recent_transactions, fn(transaction) {
      html.li([], [
        element.text(
          transaction.transaction_type
          <> ": $"
          <> float.to_string(transaction.amount),
        ),
        element.text(
          " → Balance: $" <> float.to_string(transaction.new_balance),
        ),
      ])
    })

  html.div([attribute.class("transaction-history")], [
    html.h3([], [element.text("Recent Transactions")]),
    html.ul([], transaction_items),
  ])
}

// Effect functions for WebSocket communication
fn send_websocket_message_effect(
  socket: ws.WebSocket,
  message: json.Json,
) -> effect.Effect(Msg) {
  let message_string = json.to_string(message)
  ws.send(socket, message_string)
}

fn current_timestamp() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds_and_nanoseconds
  |> pair.first
}

/// Main function to start the Lustre application
pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
