import eventsourcing
import eventsourcing/memory_store
import example_bank_account
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/static_supervisor
import gleeunit

import eventsourcing_glyn

pub fn main() {
  gleeunit.main()
}

pub fn glyn_config_creation_test() {
  let config = eventsourcing_glyn.GlynConfig("test_topic", "test_scope")
  assert config.pubsub_topic == "test_topic"
  config.registry_scope == "test_scope"
}

pub fn glyn_store_supervised_creation_test() {
  let config = eventsourcing_glyn.GlynConfig("bank_events", "bank_aggregates")
  let events_actor_name = process.new_name("events_actor")
  let snapshot_actor_name = process.new_name("snapshot_actor")
  let #(eventstore, _) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )
  let queries = []

  let assert Ok(_) =
    eventsourcing_glyn.supervised(
      config,
      eventstore,
      queries,
      example_bank_account.event_decoder(),
    )
}

pub fn gyn_store_test() {
  let config = eventsourcing_glyn.GlynConfig("bank_events", "bank_aggregates")
  let events_actor_name = process.new_name("events_actor")
  let snapshot_actor_name = process.new_name("snapshot_actor")
  let #(eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let query_results = process.new_subject()
  let queries = [
    #(process.new_name("basic-commands-query"), fn(aggregate_id, events) {
      process.send(query_results, #(aggregate_id, list.length(events)))
    }),
  ]
  let query_results_glyn = process.new_subject()
  let queries_glyn = [
    #(process.new_name("basic-commands-query-glyn"), fn(aggregate_id, events) {
      process.send(query_results_glyn, #(
        aggregate_id,
        int.to_string(list.length(events)) <> " via glyn",
      ))
    }),
  ]

  let assert Ok(#(eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      eventstore,
      queries_glyn,
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  let name = process.new_name("basic-commands-eventsourcing")

  let assert Ok(eventsourcing_spec) =
    eventsourcing.supervised(
      name:,
      eventstore:,
      handle: example_bank_account.handle,
      apply: example_bank_account.apply,
      empty_state: example_bank_account.UnopenedBankAccount,
      queries:,
      snapshot_config: option.None,
    )

  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(eventsourcing_spec)
    |> static_supervisor.start()

  let eventsourcing = process.named_subject(name)

  process.sleep(100)

  // Open account
  eventsourcing.execute(
    eventsourcing,
    "test-001",
    example_bank_account.OpenAccount("test-001"),
  )
  let assert Ok(#("test-001", 1)) = process.receive(query_results, 1000)

  // Deposit money
  eventsourcing.execute(
    eventsourcing,
    "test-001",
    example_bank_account.DepositMoney(100.0),
  )
  let assert Ok(#("test-001", 1)) = process.receive(query_results, 1000)

  // Withdraw money
  eventsourcing.execute(
    eventsourcing,
    "test-001",
    example_bank_account.WithDrawMoney(50.0),
  )
  let assert Ok(#("test-001", 1)) = process.receive(query_results, 1000)

  let assert Ok(#("test-001", "1 via glyn")) =
    process.receive(query_results_glyn, 1000)
}

pub fn memory_store_event_envelop_decoder_test() {
  let decoder =
    eventsourcing_glyn.memory_store_event_envelop_decoder(
      example_bank_account.event_decoder(),
    )

  let event_data =
    json.object([
      #("event-type", json.string("account-opened")),
      #("account-id", json.string("test-123")),
    ])

  let envelop_data =
    json.object([
      #("1", json.string("test-123")),
      #("2", json.int(1)),
      #("3", event_data),
      #("4", json.array([], json.object)),
    ])

  case json.parse(json.to_string(envelop_data), decoder) {
    Ok(envelop) -> {
      envelop.aggregate_id == "test-123" && envelop.sequence == 1
    }
    Error(_) -> False
  }
}

pub fn serialized_event_envelop_decoder_test() {
  let decoder =
    eventsourcing_glyn.serialized_event_envelop_decoder(
      example_bank_account.event_decoder(),
    )

  let event_data =
    json.object([
      #("event-type", json.string("account-opened")),
      #("account-id", json.string("test-456")),
    ])

  let envelop_data =
    json.object([
      #("1", json.string("test-456")),
      #("2", json.int(2)),
      #("3", event_data),
      #("4", json.array([], json.object)),
      #("5", json.string("BankAccountEvent")),
      #("6", json.string("1.0")),
      #("7", json.string("BankAccount")),
    ])

  case json.parse(json.to_string(envelop_data), decoder) {
    Ok(envelop) -> {
      envelop.aggregate_id == "test-456"
      && envelop.sequence == 2
      && envelop.payload == example_bank_account.AccountOpened("test-456")
    }
    Error(_) -> False
  }
}

pub fn metadata_decoder_test() {
  let decoder = eventsourcing_glyn.metadata_decoder()
  let metadata_data =
    json.object([
      #("0", json.string("user_id")),
      #("1", json.string("user_123")),
    ])

  case json.parse(json.to_string(metadata_data), decoder) {
    Ok(#(key, value)) -> key == "user_id" && value == "user_123"
    Error(_) -> False
  }
}
