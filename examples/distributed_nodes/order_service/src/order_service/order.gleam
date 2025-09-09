import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/list

// Order domain types
pub type OrderId =
  String

pub type Product {
  Product(id: String, name: String, price: Int)
}

pub type Item {
  Item(product: Product, quantity: Int)
}

pub type State {
  NotFound
  Pending(id: OrderId, items: List(Item), total: Int)
  Confirmed(id: OrderId, items: List(Item), total: Int)
  Cancelled(id: OrderId, reason: String)
}

// Order commands
pub type Command {
  CreateOrder(id: OrderId, items: List(Item))
  ConfirmOrder(id: OrderId)
  CancelOrder(id: OrderId, reason: String)
}

// Order events
pub type Event {
  OrderCreated(id: OrderId, items: List(Item), total: Int)
  OrderConfirmed(id: OrderId)
  OrderCancelled(id: OrderId, reason: String)
}

// Service discovery types
pub type ServiceInfo {
  ServiceInfo(node_name: String, service_type: String, endpoint: String)
}

pub type ServiceDiscoveryMessage {
  RegisterService(service: ServiceInfo)
  DiscoverService(
    service_type: String,
    reply_to: process.Subject(List(ServiceInfo)),
  )
}

// JSON encoding/decoding for events
pub fn encode_order_event(event: Event) -> json.Json {
  case event {
    OrderCreated(id, items, total) ->
      json.object([
        #("type", json.string("OrderCreated")),
        #("id", json.string(id)),
        #("items", json.array(items, encode_order_item)),
        #("total", json.int(total)),
      ])
    OrderConfirmed(id) ->
      json.object([
        #("type", json.string("OrderConfirmed")),
        #("id", json.string(id)),
      ])
    OrderCancelled(id, reason) ->
      json.object([
        #("type", json.string("OrderCancelled")),
        #("id", json.string(id)),
        #("reason", json.string(reason)),
      ])
  }
}

pub fn encode_order_item(item: Item) -> json.Json {
  json.object([
    #("product", encode_product(item.product)),
    #("quantity", json.int(item.quantity)),
  ])
}

pub fn encode_product(product: Product) -> json.Json {
  json.object([
    #("id", json.string(product.id)),
    #("name", json.string(product.name)),
    #("price", json.int(product.price)),
  ])
}

fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
  use value <- decode.then(atom.decoder())
  case atom.to_string(value) == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected atom: " <> expected)
  }
}

pub fn decode_order_event() -> decode.Decoder(Event) {
  decode.one_of(
    {
      use _ <- decode.field(0, expect_atom("order_created"))
      use id <- decode.field(1, decode.string)
      use items <- decode.field(2, decode.list(decode_order_item()))
      use total <- decode.field(3, decode.int)
      decode.success(OrderCreated(id, items, total))
    },
    or: [
      {
        use _ <- decode.field(0, expect_atom("order_confirmed"))
        use id <- decode.field(1, decode.string)
        decode.success(OrderConfirmed(id))
      },
      {
        use _ <- decode.field(0, expect_atom("order_cancelled"))
        use id <- decode.field(1, decode.string)
        use reason <- decode.field(2, decode.string)
        decode.success(OrderCancelled(id, reason))
      },
    ],
  )
}

pub fn decode_order_item() {
  use product <- decode.field(1, decode_product())
  use quantity <- decode.field(2, decode.int)
  decode.success(Item(product, quantity))
}

pub fn decode_product() {
  use id <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use price <- decode.field(3, decode.int)
  decode.success(Product(id, name, price))
}

// Order business logic
pub fn handle_order_command(
  state: State,
  command: Command,
) -> Result(List(Event), String) {
  case state, command {
    NotFound, CreateOrder(id, items) -> {
      let total =
        list.fold(items, 0, fn(acc, item) {
          acc + item.product.price * item.quantity
        })
      Ok([OrderCreated(id, items, total)])
    }
    Pending(_, _, _), ConfirmOrder(id) -> {
      Ok([OrderConfirmed(id)])
    }
    Pending(_, _, _), CancelOrder(id, reason) -> {
      Ok([OrderCancelled(id, reason)])
    }
    _, _ -> Error("Invalid command for current state")
  }
}

pub fn apply_order_event(state: State, event: Event) -> State {
  case event {
    OrderCreated(id, items, total) -> Pending(id, items, total)
    OrderConfirmed(id) ->
      case state {
        Pending(_, items, total) -> Confirmed(id, items, total)
        _ -> state
      }
    OrderCancelled(id, reason) -> Cancelled(id, reason)
  }
}
