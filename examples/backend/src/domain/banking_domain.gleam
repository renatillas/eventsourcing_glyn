import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/json
import gleam/list
import gleam/result

/// Bank account aggregate state
pub type BankAccount {
  BankAccount(balance: Float, account_holder: String)
  UnopenedBankAccount
}

/// Commands that can be sent to a bank account
pub type BankAccountCommand {
  OpenAccount(account_id: String, account_holder: String)
  DepositMoney(amount: Float)
  WithDrawMoney(amount: Float)
  CloseAccount
}

/// Events that occur in the banking domain
pub type BankAccountEvent {
  AccountOpened(account_id: String, account_holder: String)
  CustomerDepositedCash(amount: Float, balance: Float)
  CustomerWithdrewCash(amount: Float, balance: Float)
  AccountClosed
}

/// Errors that can occur during command processing
pub type BankAccountError {
  CantDepositNegativeAmount
  CantWithdrawNegativeAmount
  CantOperateOnUnopenedAccount
  CantWithdrawMoreThanCurrentBalance
  AccountAlreadyClosed
}

/// WebSocket message types for client-server communication
pub type WebSocketMessage {
  // Client to Server
  ExecuteCommand(aggregate_id: String, command: BankAccountCommand)
  SubscribeToAccount(account_id: String)
  UnsubscribeFromAccount(account_id: String)
  RequestAccountSnapshot(account_id: String)

  // Server to Client  
  EventNotification(aggregate_id: String, events: List(BankAccountEvent))
  AccountSnapshot(account_id: String, balance: Float, account_holder: String)
  CommandResult(success: Bool, message: String)
  ConnectionStatus(connected: Bool)
}

/// Business logic for handling banking commands
pub fn handle(
  bank_account: BankAccount,
  command: BankAccountCommand,
) -> Result(List(BankAccountEvent), BankAccountError) {
  case bank_account, command {
    UnopenedBankAccount, OpenAccount(account_id, account_holder) ->
      Ok([AccountOpened(account_id, account_holder)])

    BankAccount(balance, _), DepositMoney(amount) -> {
      case amount >. 0.0 {
        True -> {
          let new_balance = balance +. amount
          Ok([CustomerDepositedCash(amount, new_balance)])
        }
        False -> Error(CantDepositNegativeAmount)
      }
    }

    BankAccount(balance, _), WithDrawMoney(amount) -> {
      case amount >. 0.0 && balance >=. amount {
        True -> {
          let new_balance = balance -. amount
          Ok([CustomerWithdrewCash(amount, new_balance)])
        }
        False ->
          case amount <=. 0.0 {
            True -> Error(CantWithdrawNegativeAmount)
            False -> Error(CantWithdrawMoreThanCurrentBalance)
          }
      }
    }

    BankAccount(_, _), CloseAccount -> Ok([AccountClosed])

    _, _ -> Error(CantOperateOnUnopenedAccount)
  }
}

/// Apply events to update account state
pub fn apply(bank_account: BankAccount, event: BankAccountEvent) -> BankAccount {
  case bank_account, event {
    UnopenedBankAccount, AccountOpened(_, account_holder) ->
      BankAccount(0.0, account_holder)

    BankAccount(_, account_holder), CustomerDepositedCash(_, new_balance) ->
      BankAccount(new_balance, account_holder)

    BankAccount(_, account_holder), CustomerWithdrewCash(_, new_balance) ->
      BankAccount(new_balance, account_holder)

    BankAccount(_, _), AccountClosed -> UnopenedBankAccount

    _, _ -> bank_account
  }
}

/// Calculate current balance from list of events
pub fn calculate_balance(events: List(BankAccountEvent)) -> Float {
  events
  |> list.fold(0.0, fn(_balance, event) {
    case event {
      AccountOpened(_, _) -> 0.0
      CustomerDepositedCash(_, new_balance) -> new_balance
      CustomerWithdrewCash(_, new_balance) -> new_balance
      AccountClosed -> 0.0
    }
  })
}

/// Extract account holder name from events
pub fn get_account_holder(events: List(BankAccountEvent)) -> String {
  events
  |> list.find_map(fn(event) {
    case event {
      AccountOpened(_, account_holder) -> Ok(account_holder)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("Unknown")
}

/// JSON encoding for WebSocket messages
pub fn encode_websocket_message(message: WebSocketMessage) -> String {
  case message {
    EventNotification(aggregate_id, events) ->
      json.object([
        #("type", json.string("event_notification")),
        #("aggregate_id", json.string(aggregate_id)),
        #("events", json.array(events, encode_event)),
      ])

    AccountSnapshot(account_id, balance, account_holder) ->
      json.object([
        #("type", json.string("account_snapshot")),
        #("account_id", json.string(account_id)),
        #("balance", json.float(balance)),
        #("account_holder", json.string(account_holder)),
      ])

    CommandResult(success, message) ->
      json.object([
        #("type", json.string("command_result")),
        #("success", json.bool(success)),
        #("message", json.string(message)),
      ])

    ConnectionStatus(connected) ->
      json.object([
        #("type", json.string("connection_status")),
        #("connected", json.bool(connected)),
      ])

    _ -> json.object([#("type", json.string("unknown"))])
  }
  |> json.to_string
}

fn encode_event(event: BankAccountEvent) -> json.Json {
  case event {
    AccountOpened(account_id, account_holder) ->
      json.object([
        #("type", json.string("account_opened")),
        #("account_id", json.string(account_id)),
        #("account_holder", json.string(account_holder)),
      ])

    CustomerDepositedCash(amount, balance) ->
      json.object([
        #("type", json.string("deposit")),
        #("amount", json.float(amount)),
        #("balance", json.float(balance)),
      ])

    CustomerWithdrewCash(amount, balance) ->
      json.object([
        #("type", json.string("withdrawal")),
        #("amount", json.float(amount)),
        #("balance", json.float(balance)),
      ])

    AccountClosed -> json.object([#("type", json.string("account_closed"))])
  }
}

/// Decoder for client commands
pub fn decode_websocket_message(
  json_string: String,
) -> Result(WebSocketMessage, String) {
  let message_decoder = {
    use message_type <- decode.field("type", decode.string)
    case message_type {
      "execute_command" -> {
        use aggregate_id <- decode.field("aggregate_id", decode.string)
        use command <- decode.field("command", decode_command())
        decode.success(ExecuteCommand(aggregate_id, command))
      }
      "subscribe_account" -> {
        use account_id <- decode.field("account_id", decode.string)
        decode.success(SubscribeToAccount(account_id))
      }
      "unsubscribe_account" -> {
        use account_id <- decode.field("account_id", decode.string)
        decode.success(UnsubscribeFromAccount(account_id))
      }
      "request_snapshot" -> {
        use account_id <- decode.field("account_id", decode.string)
        decode.success(RequestAccountSnapshot(account_id))
      }
      _ ->
        decode.failure(
          ExecuteCommand("unknown command type", OpenAccount("", "")),
          "Unknown message type",
        )
    }
  }

  json.parse(json_string, message_decoder)
  |> result.map_error(fn(_) { "Failed to parse WebSocket message" })
}

fn decode_command() -> decode.Decoder(BankAccountCommand) {
  use command_type <- decode.field("type", decode.string)
  case command_type {
    "open_account" -> {
      use account_id <- decode.field("account_id", decode.string)
      use account_holder <- decode.field("account_holder", decode.string)
      decode.success(OpenAccount(account_id, account_holder))
    }
    "deposit" -> {
      use amount <- decode.field(
        "amount",
        decode.one_of(decode.float, [
          {
            use decoded <- decode.then(decode.int)
            decode.success(int.to_float(decoded))
          },
        ]),
      )
      decode.success(DepositMoney(amount))
    }
    "withdraw" -> {
      use amount <- decode.field(
        "amount",
        decode.one_of(decode.float, [
          {
            use decoded <- decode.then(decode.int)
            decode.success(int.to_float(decoded))
          },
        ]),
      )
      decode.success(WithDrawMoney(amount))
    }
    "close_account" -> decode.success(CloseAccount)
    _ -> decode.failure(OpenAccount("", ""), "Unknown message type")
  }
}

/// Event decoder for Gleam native format (used by eventsourcing_glyn)
pub fn event_decoder_gleam() -> decode.Decoder(BankAccountEvent) {
  use tag <- decode.field(0, atom.decoder())
  case atom.to_string(tag) {
    "account_opened" -> {
      use account_id <- decode.field(1, decode.string)
      use account_holder <- decode.field(2, decode.string)
      decode.success(AccountOpened(account_id, account_holder))
    }
    "customer_deposited_cash" -> {
      use amount <- decode.field(1, decode.float)
      use balance <- decode.field(2, decode.float)
      decode.success(CustomerDepositedCash(amount, balance))
    }
    "customer_withdrew_cash" -> {
      use amount <- decode.field(1, decode.float)
      use balance <- decode.field(2, decode.float)
      decode.success(CustomerWithdrewCash(amount, balance))
    }
    "account_closed" -> decode.success(AccountClosed)
    _ -> decode.failure(AccountClosed, "Unknown event type")
  }
}
