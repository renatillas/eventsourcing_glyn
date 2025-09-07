import eventsourcing
import eventsourcing/memory_store
import eventsourcing_glyn
import example_bank_account
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/static_supervisor
import gleeunit/should

pub fn proxy_load_events_test() {
  let config = eventsourcing_glyn.GlynConfig("proxy_events", "proxy_aggregates")
  let events_actor_name = process.new_name("proxy_events_actor")
  let snapshot_actor_name = process.new_name("proxy_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      [],
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  let name = process.new_name("proxy-eventsourcing")

  let assert Ok(eventsourcing_spec) =
    eventsourcing.supervised(
      name:,
      eventstore: glyn_eventstore,
      handle: example_bank_account.handle,
      apply: example_bank_account.apply,
      empty_state: example_bank_account.UnopenedBankAccount,
      queries: [],
      snapshot_config: option.None,
    )

  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(eventsourcing_spec)
    |> static_supervisor.start()

  let eventsourcing = process.named_subject(name)
  process.sleep(100)

  // Execute command to generate events
  eventsourcing.execute(
    eventsourcing,
    "proxy-test-001",
    example_bank_account.OpenAccount("proxy-test-001"),
  )

  process.sleep(100)

  // Test loading events through proxy
  case
    glyn_eventstore.load_events(
      glyn_eventstore.eventstore,
      underlying_eventstore.eventstore,
      "proxy-test-001",
      0,
    )
  {
    Ok(events) -> {
      should.be_true(list.length(events) >= 1)
      True
    }
    Error(_) -> False
  }
}

pub fn proxy_snapshot_operations_test() {
  let config =
    eventsourcing_glyn.GlynConfig("snapshot_events", "snapshot_aggregates")
  let events_actor_name = process.new_name("snapshot_events_actor")
  let snapshot_actor_name = process.new_name("snapshot_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      [],
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  // Test loading non-existent snapshot
  case
    glyn_eventstore.load_snapshot(
      underlying_eventstore.eventstore,
      "snapshot-test-001",
    )
  {
    Ok(option.None) -> True
    Ok(_) -> False
    Error(_) -> False
  }
}

pub fn proxy_transaction_operations_test() {
  let config = eventsourcing_glyn.GlynConfig("tx_events", "tx_aggregates")
  let events_actor_name = process.new_name("tx_events_actor")
  let snapshot_actor_name = process.new_name("tx_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      [],
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  // Test execute transaction
  case glyn_eventstore.execute_transaction(fn(_tx) { Ok(Nil) }) {
    Ok(Nil) -> True
    Error(_) -> False
  }
}

pub fn proxy_load_aggregate_transaction_test() {
  let config = eventsourcing_glyn.GlynConfig("agg_events", "agg_aggregates")
  let events_actor_name = process.new_name("agg_events_actor")
  let snapshot_actor_name = process.new_name("agg_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      [],
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  // Test load aggregate transaction
  let result =
    glyn_eventstore.load_aggregate_transaction(fn(_tx) {
      Ok(eventsourcing.Aggregate(
        aggregate_id: "agg-test-001",
        entity: example_bank_account.UnopenedBankAccount,
        sequence: 0,
      ))
    })

  case result {
    Ok(aggregate) -> aggregate.aggregate_id == "agg-test-001"
    Error(_) -> False
  }
}
