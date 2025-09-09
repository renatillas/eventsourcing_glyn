import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}

// Inventory domain types
pub type ProductId =
  String

pub type Item {
  Item(id: ProductId, name: String, stock_level: Int, reserved: Int)
}

pub type OrderItem {
  OrderItem(product: Product, quantity: Int)
}

pub type Product {
  Product(id: String, name: String, price: Int)
}

pub type InventoryState {
  InventoryNotFound
  InventoryActive(items: List(Item))
}

// Inventory commands
pub type InventoryCommand {
  InitializeInventory(items: List(Item))
  ReserveStock(product_id: ProductId, quantity: Int, order_id: String)
  ReleaseReservation(product_id: ProductId, quantity: Int, order_id: String)
  ConfirmReservation(product_id: ProductId, quantity: Int, order_id: String)
  RestockItem(product_id: ProductId, quantity: Int)
}

// Inventory events
pub type InventoryEvent {
  InventoryInitialized(items: List(Item))
  StockReserved(
    product_id: ProductId,
    quantity: Int,
    order_id: String,
    remaining_stock: Int,
  )
  StockReservationFailed(
    product_id: ProductId,
    quantity: Int,
    order_id: String,
    reason: String,
  )
  ReservationReleased(
    product_id: ProductId,
    quantity: Int,
    order_id: String,
    new_stock: Int,
  )
  ReservationConfirmed(
    product_id: ProductId,
    quantity: Int,
    order_id: String,
    new_stock: Int,
  )
  ItemRestocked(product_id: ProductId, quantity: Int, new_stock: Int)
  OrderCreated(id: String, items: List(OrderItem), total: Int)
}

// Service discovery types (shared with order service)
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

// JSON encoding/decoding for inventory events
pub fn encode_inventory_event(event: InventoryEvent) -> json.Json {
  case event {
    InventoryInitialized(items) ->
      json.object([
        #("type", json.string("InventoryInitialized")),
        #("items", json.array(items, encode_inventory_item)),
      ])
    StockReserved(product_id, quantity, order_id, remaining) ->
      json.object([
        #("type", json.string("StockReserved")),
        #("product_id", json.string(product_id)),
        #("quantity", json.int(quantity)),
        #("order_id", json.string(order_id)),
        #("remaining_stock", json.int(remaining)),
      ])
    StockReservationFailed(product_id, quantity, order_id, reason) ->
      json.object([
        #("type", json.string("StockReservationFailed")),
        #("product_id", json.string(product_id)),
        #("quantity", json.int(quantity)),
        #("order_id", json.string(order_id)),
        #("reason", json.string(reason)),
      ])
    ReservationReleased(product_id, quantity, order_id, new_stock) ->
      json.object([
        #("type", json.string("ReservationReleased")),
        #("product_id", json.string(product_id)),
        #("quantity", json.int(quantity)),
        #("order_id", json.string(order_id)),
        #("new_stock", json.int(new_stock)),
      ])
    ReservationConfirmed(product_id, quantity, order_id, new_stock) ->
      json.object([
        #("type", json.string("ReservationConfirmed")),
        #("product_id", json.string(product_id)),
        #("quantity", json.int(quantity)),
        #("order_id", json.string(order_id)),
        #("new_stock", json.int(new_stock)),
      ])
    ItemRestocked(product_id, quantity, new_stock) ->
      json.object([
        #("type", json.string("ItemRestocked")),
        #("product_id", json.string(product_id)),
        #("quantity", json.int(quantity)),
        #("new_stock", json.int(new_stock)),
      ])
    OrderCreated(id, items, total) ->
      json.object([
        #("type", json.string("OrderCreated")),
        #("id", json.string(id)),
        #("items", json.array(items, encode_order_item)),
        #("total", json.int(total)),
      ])
  }
}

pub fn encode_order_item(item: OrderItem) -> json.Json {
  json.object([
    #("product_id", encode_order_product(item.product)),
    #("quantity", json.int(item.quantity)),
  ])
}

pub fn encode_order_product(product: Product) -> json.Json {
  json.object([
    #("id", json.string(product.id)),
    #("name", json.string(product.name)),
    #("price", json.int(product.price)),
  ])
}

pub fn encode_inventory_item(item: Item) -> json.Json {
  json.object([
    #("id", json.string(item.id)),
    #("name", json.string(item.name)),
    #("stock_level", json.int(item.stock_level)),
    #("reserved", json.int(item.reserved)),
  ])
}

fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
  use value <- decode.then(atom.decoder())
  case atom.to_string(value) == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected atom: " <> expected)
  }
}

pub fn decode_inventory_event() -> decode.Decoder(InventoryEvent) {
  decode.one_of(
    {
      use _ <- decode.field(0, expect_atom("inventory_initialized"))
      use items <- decode.field(1, decode.list(decode_inventory_item()))
      decode.success(InventoryInitialized(items))
    },
    or: [
      {
        use _ <- decode.field(0, expect_atom("stock_reserved"))
        use product_id <- decode.field(1, decode.string)
        use quantity <- decode.field(2, decode.int)
        use order_id <- decode.field(3, decode.string)
        use remaining <- decode.field(4, decode.int)
        decode.success(StockReserved(product_id, quantity, order_id, remaining))
      },
      {
        use _ <- decode.field(0, expect_atom("stock_reservation_failed"))
        use product_id <- decode.field(1, decode.string)
        use quantity <- decode.field(2, decode.int)
        use order_id <- decode.field(3, decode.string)
        use reason <- decode.field(4, decode.string)
        decode.success(StockReservationFailed(
          product_id,
          quantity,
          order_id,
          reason,
        ))
      },
      {
        use _ <- decode.field(0, expect_atom("reservation_released"))
        use product_id <- decode.field(1, decode.string)
        use quantity <- decode.field(2, decode.int)
        use order_id <- decode.field(3, decode.string)
        use new_stock <- decode.field(4, decode.int)
        decode.success(ReservationReleased(
          product_id,
          quantity,
          order_id,
          new_stock,
        ))
      },
      {
        use _ <- decode.field(0, expect_atom("reservation_confirmed"))
        use product_id <- decode.field(1, decode.string)
        use quantity <- decode.field(2, decode.int)
        use order_id <- decode.field(3, decode.string)
        use new_stock <- decode.field(4, decode.int)
        decode.success(ReservationConfirmed(
          product_id,
          quantity,
          order_id,
          new_stock,
        ))
      },
      {
        use _ <- decode.field(0, expect_atom("item_restocked"))
        use product_id <- decode.field(1, decode.string)
        use quantity <- decode.field(2, decode.int)
        use new_stock <- decode.field(3, decode.int)
        decode.success(ItemRestocked(product_id, quantity, new_stock))
      },
      {
        use _ <- decode.field(0, expect_atom("order_created"))
        use id <- decode.field(1, decode.string)
        use items <- decode.field(2, decode.list(decode_order_item()))
        use total <- decode.field(3, decode.int)
        decode.success(OrderCreated(id, items, total))
      },
    ],
  )
}

pub fn decode_order_item() {
  use product <- decode.field(1, decode_order_product())
  use quantity <- decode.field(2, decode.int)
  decode.success(OrderItem(product, quantity))
}

pub fn decode_order_product() {
  use id <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use price <- decode.field(3, decode.int)
  decode.success(Product(id, name, price))
}

pub fn decode_inventory_item() {
  use id <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use stock_level <- decode.field(3, decode.int)
  use reserved <- decode.field(4, decode.int)
  decode.success(Item(id, name, stock_level, reserved))
}

// Inventory business logic
pub fn handle_inventory_command(
  state: InventoryState,
  command: InventoryCommand,
) -> Result(List(InventoryEvent), String) {
  case state, command {
    InventoryNotFound, InitializeInventory(items) -> {
      Ok([InventoryInitialized(items)])
    }
    InventoryActive(items), ReserveStock(product_id, quantity, order_id) -> {
      case find_item(items, product_id) {
        Some(item) -> {
          let available = item.stock_level - item.reserved
          case available >= quantity {
            True -> {
              let remaining_stock = item.stock_level - quantity
              Ok([
                StockReserved(product_id, quantity, order_id, remaining_stock),
              ])
            }
            False -> {
              Ok([
                StockReservationFailed(
                  product_id,
                  quantity,
                  order_id,
                  "Insufficient stock",
                ),
              ])
            }
          }
        }
        None -> {
          Ok([
            StockReservationFailed(
              product_id,
              quantity,
              order_id,
              "Product not found",
            ),
          ])
        }
      }
    }
    InventoryActive(items), ReleaseReservation(product_id, quantity, order_id) -> {
      case find_item(items, product_id) {
        Some(item) -> {
          let new_stock = item.stock_level + quantity
          Ok([ReservationReleased(product_id, quantity, order_id, new_stock)])
        }
        None -> Error("Product not found")
      }
    }
    InventoryActive(items), ConfirmReservation(product_id, quantity, order_id) -> {
      case find_item(items, product_id) {
        Some(item) -> {
          let new_stock = item.stock_level - quantity
          Ok([ReservationConfirmed(product_id, quantity, order_id, new_stock)])
        }
        None -> Error("Product not found")
      }
    }
    InventoryActive(items), RestockItem(product_id, quantity) -> {
      case find_item(items, product_id) {
        Some(item) -> {
          let new_stock = item.stock_level + quantity
          Ok([ItemRestocked(product_id, quantity, new_stock)])
        }
        None -> Error("Product not found")
      }
    }
    _, _ -> Error("Invalid command for current state")
  }
}

pub fn apply_inventory_event(
  state: InventoryState,
  event: InventoryEvent,
) -> InventoryState {
  case state, event {
    InventoryNotFound, InventoryInitialized(items) -> InventoryActive(items)
    InventoryActive(items),
      StockReserved(product_id, quantity, _order_id, _remaining)
    -> {
      let updated_items =
        list.map(items, fn(item) {
          case item.id == product_id {
            True -> Item(..item, reserved: item.reserved + quantity)
            False -> item
          }
        })
      InventoryActive(updated_items)
    }
    InventoryActive(items),
      ReservationReleased(product_id, quantity, _order_id, new_stock)
    -> {
      let updated_items =
        list.map(items, fn(item) {
          case item.id == product_id {
            True ->
              Item(
                ..item,
                stock_level: new_stock,
                reserved: item.reserved - quantity,
              )
            False -> item
          }
        })
      InventoryActive(updated_items)
    }
    InventoryActive(items),
      ReservationConfirmed(product_id, quantity, _order_id, new_stock)
    -> {
      let updated_items =
        list.map(items, fn(item) {
          case item.id == product_id {
            True ->
              Item(
                ..item,
                stock_level: new_stock,
                reserved: item.reserved - quantity,
              )
            False -> item
          }
        })
      InventoryActive(updated_items)
    }
    InventoryActive(items), ItemRestocked(product_id, _, new_stock) -> {
      let updated_items =
        list.map(items, fn(item) {
          case item.id == product_id {
            True -> Item(..item, stock_level: new_stock)
            False -> item
          }
        })
      InventoryActive(updated_items)
    }
    _, _ -> state
  }
}

fn find_item(items: List(Item), product_id: String) -> option.Option(Item) {
  list.find(items, fn(item) { item.id == product_id })
  |> option.from_result
}
