import eventsourcing
import eventsourcing/memory_store
import example_bank_account
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/static_supervisor
import gleeunit

import eventsourcing_glyn

pub fn main() {
  gleeunit.main()
}

pub fn glyn_config_creation_test() {
  let config = eventsourcing_glyn.GlynConfig("test_scope", "test_group")

  config.pubsub_scope == "test_scope" && config.pubsub_group == "test_group"
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

pub fn pubsub_scope_group_integration_test() {
  let config =
    eventsourcing_glyn.GlynConfig("integration_scope", "integration_group")
  let events_actor_name = process.new_name("integration_events_actor")
  let snapshot_actor_name = process.new_name("integration_snapshot_actor")
  let #(eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let query_results = process.new_subject()
  let queries_glyn = [
    #(process.new_name("integration-query"), fn(aggregate_id, events) {
      process.send(query_results, #(
        aggregate_id,
        "integration_group",
        list.length(events),
      ))
    }),
  ]

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
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

  let name = process.new_name("integration-eventsourcing")

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

  eventsourcing.execute(
    eventsourcing,
    "integration-test-001",
    example_bank_account.OpenAccount("integration-test-001"),
  )

  let assert Ok(#("integration-test-001", "integration_group", 1)) =
    process.receive(query_results, 1000)
}

pub fn multiple_scopes_isolation_test() {
  let config_a = eventsourcing_glyn.GlynConfig("scope_a", "group_a")
  let config_b = eventsourcing_glyn.GlynConfig("scope_b", "group_b")

  let events_name_a = process.new_name("events_a")
  let snapshot_name_a = process.new_name("snapshot_a")
  let #(eventstore_a, memory_spec_a) =
    memory_store.supervised(
      events_name_a,
      snapshot_name_a,
      static_supervisor.OneForOne,
    )

  let events_name_b = process.new_name("events_b")
  let snapshot_name_b = process.new_name("snapshot_b")
  let #(eventstore_b, memory_spec_b) =
    memory_store.supervised(
      events_name_b,
      snapshot_name_b,
      static_supervisor.OneForOne,
    )

  let query_results_a = process.new_subject()
  let query_results_b = process.new_subject()

  let queries_a = [
    #(process.new_name("query_a"), fn(aggregate_id, events) {
      process.send(query_results_a, #(
        aggregate_id,
        "scope_a",
        list.length(events),
      ))
    }),
  ]

  let queries_b = [
    #(process.new_name("query_b"), fn(aggregate_id, events) {
      process.send(query_results_b, #(
        aggregate_id,
        "scope_b",
        list.length(events),
      ))
    }),
  ]

  let assert Ok(#(glyn_store_a, glyn_spec_a)) =
    eventsourcing_glyn.supervised(
      config_a,
      eventstore_a,
      queries_a,
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(#(glyn_store_b, glyn_spec_b)) =
    eventsourcing_glyn.supervised(
      config_b,
      eventstore_b,
      queries_b,
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup_a) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_spec_a)
    |> static_supervisor.add(glyn_spec_a)
    |> static_supervisor.start()

  let assert Ok(_sup_b) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_spec_b)
    |> static_supervisor.add(glyn_spec_b)
    |> static_supervisor.start()

  let name_a = process.new_name("eventsourcing_a")
  let name_b = process.new_name("eventsourcing_b")

  let assert Ok(spec_a) =
    eventsourcing.supervised(
      name: name_a,
      eventstore: glyn_store_a,
      handle: example_bank_account.handle,
      apply: example_bank_account.apply,
      empty_state: example_bank_account.UnopenedBankAccount,
      queries: [],
      snapshot_config: option.None,
    )

  let assert Ok(spec_b) =
    eventsourcing.supervised(
      name: name_b,
      eventstore: glyn_store_b,
      handle: example_bank_account.handle,
      apply: example_bank_account.apply,
      empty_state: example_bank_account.UnopenedBankAccount,
      queries: [],
      snapshot_config: option.None,
    )

  let assert Ok(_supervisor_a) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec_a)
    |> static_supervisor.start()

  let assert Ok(_supervisor_b) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec_b)
    |> static_supervisor.start()

  let eventsourcing_a = process.named_subject(name_a)
  let _eventsourcing_b = process.named_subject(name_b)
  process.sleep(100)

  // Test that events in scope_a don't trigger queries in scope_b
  eventsourcing.execute(
    eventsourcing_a,
    "isolation-test-a",
    example_bank_account.OpenAccount("isolation-test-a"),
  )

  // Only scope_a should receive the event
  let assert Ok(#("isolation-test-a", "scope_a", 1)) =
    process.receive(query_results_a, 1000)

  // scope_b should not receive anything
  let assert Error(Nil) = process.receive(query_results_b, 500)
}

pub fn glyn_store_test() {
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

pub fn pubsub_publishing_test() {
  let config = eventsourcing_glyn.GlynConfig("publish_scope", "publish_group")
  let events_actor_name = process.new_name("publish_events")
  let snapshot_actor_name = process.new_name("publish_snapshots")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let publish_results = process.new_subject()
  let queries_glyn = [
    #(process.new_name("publish-query"), fn(aggregate_id, events) {
      list.each(
        events,
        fn(
          event: eventsourcing.EventEnvelop(
            example_bank_account.BankAccountEvent,
          ),
        ) {
          case event.payload {
            example_bank_account.AccountOpened(account_id) -> {
              process.send(publish_results, #("opened", account_id))
            }
            example_bank_account.CustomerDepositedCash(amount, _balance) -> {
              process.send(publish_results, #(
                "deposited",
                float.to_string(amount),
              ))
            }
            example_bank_account.CustomerWithdrewCash(amount, _balance) -> {
              process.send(publish_results, #(
                "withdrew",
                float.to_string(amount),
              ))
            }
            example_bank_account.AccountClosed -> {
              process.send(publish_results, #("closed", aggregate_id))
            }
          }
        },
      )
    }),
  ]

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      queries_glyn,
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  let name = process.new_name("publish-eventsourcing")

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

  // Test multiple event types
  eventsourcing.execute(
    eventsourcing,
    "publish-test-001",
    example_bank_account.OpenAccount("publish-test-001"),
  )
  let assert Ok(#("opened", "publish-test-001")) =
    process.receive(publish_results, 1000)

  eventsourcing.execute(
    eventsourcing,
    "publish-test-001",
    example_bank_account.DepositMoney(100.0),
  )
  let assert Ok(#("deposited", "100.0")) =
    process.receive(publish_results, 1000)

  eventsourcing.execute(
    eventsourcing,
    "publish-test-001",
    example_bank_account.WithDrawMoney(25.0),
  )
  let assert Ok(#("withdrew", "25.0")) = process.receive(publish_results, 1000)
}

pub fn subscriber_management_test() {
  let config =
    eventsourcing_glyn.GlynConfig("subscriber_scope", "subscriber_group")
  let events_actor_name = process.new_name("subscriber_events")
  let snapshot_actor_name = process.new_name("subscriber_snapshots")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  // Start with no queries
  let assert Ok(#(glyn_eventstore_empty, glyn_child_spec_empty)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      [],
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup_empty) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec_empty)
    |> static_supervisor.start()

  process.sleep(100)

  // Check that there are no subscribers initially
  let glyn_store = eventsourcing_glyn.get_glyn_store(glyn_eventstore_empty)
  let subscribers_empty = eventsourcing_glyn.get_subscribers(glyn_store)
  subscribers_empty == []
}

pub fn query_actor_error_handling_test() {
  let config = eventsourcing_glyn.GlynConfig("error_scope", "error_group")
  let events_actor_name = process.new_name("error_events")
  let snapshot_actor_name = process.new_name("error_snapshots")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let error_results = process.new_subject()
  let queries_glyn = [
    #(process.new_name("error-handling-query"), fn(aggregate_id, events) {
      process.send(error_results, #(
        aggregate_id,
        list.length(events),
        "processed",
      ))
    }),
  ]

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      queries_glyn,
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  let name = process.new_name("error-eventsourcing")

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

  // Test normal operation
  eventsourcing.execute(
    eventsourcing,
    "error-test-001",
    example_bank_account.OpenAccount("error-test-001"),
  )
  let assert Ok(#("error-test-001", 1, "processed")) =
    process.receive(error_results, 1000)

  // Test with valid command sequence
  eventsourcing.execute(
    eventsourcing,
    "error-test-001",
    example_bank_account.DepositMoney(50.0),
  )
  let assert Ok(#("error-test-001", 1, "processed")) =
    process.receive(error_results, 1000)
}

pub fn cross_aggregate_communication_test() {
  let config = eventsourcing_glyn.GlynConfig("cross_scope", "cross_group")
  let events_actor_name = process.new_name("cross_events")
  let snapshot_actor_name = process.new_name("cross_snapshots")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let communication_results = process.new_subject()
  let queries_glyn = [
    #(process.new_name("cross-communication-query"), fn(aggregate_id, events) {
      list.each(
        events,
        fn(
          event: eventsourcing.EventEnvelop(
            example_bank_account.BankAccountEvent,
          ),
        ) {
          process.send(communication_results, #(aggregate_id, event.sequence))
        },
      )
    }),
  ]

  let assert Ok(#(glyn_eventstore, glyn_child_spec)) =
    eventsourcing_glyn.supervised(
      config,
      underlying_eventstore,
      queries_glyn,
      example_bank_account.event_decoder_gleam(),
    )

  let assert Ok(_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(memory_store_child_spec)
    |> static_supervisor.add(glyn_child_spec)
    |> static_supervisor.start()

  let name = process.new_name("cross-eventsourcing")

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

  // Test multiple aggregates receiving events
  eventsourcing.execute(
    eventsourcing,
    "cross-test-001",
    example_bank_account.OpenAccount("cross-test-001"),
  )
  let assert Ok(#("cross-test-001", 1)) =
    process.receive(communication_results, 1000)

  eventsourcing.execute(
    eventsourcing,
    "cross-test-002",
    example_bank_account.OpenAccount("cross-test-002"),
  )
  let assert Ok(#("cross-test-002", 1)) =
    process.receive(communication_results, 1000)
}

pub fn memory_store_event_envelop_decoder_test() {
  let decoder =
    eventsourcing_glyn.memory_store_event_envelop_decoder(
      example_bank_account.event_decoder_gleam(),
    )

  let envelop_data =
    eventsourcing.MemoryStoreEventEnvelop(
      "test-123",
      1,
      example_bank_account.AccountOpened("test-123"),
      [],
    )
    |> cast

  let assert Ok(envelop) = decode.run(envelop_data, decoder)
  assert envelop.aggregate_id == "test-123" && envelop.sequence == 1
}

pub fn serialized_event_envelop_decoder_test() {
  let decoder =
    eventsourcing_glyn.serialized_event_envelop_decoder(
      example_bank_account.event_decoder_gleam(),
    )

  let envelop_data =
    eventsourcing.SerializedEventEnvelop(
      "test_456",
      2,
      example_bank_account.AccountOpened("test-456"),
      [],
      "BankAccountEvent",
      "1.0",
      "BankAccount",
    )
    |> cast

  let assert Ok(envelop) = decode.run(envelop_data, decoder)
  envelop.aggregate_id == "test-456"
  && envelop.sequence == 2
  && envelop.payload == example_bank_account.AccountOpened("test-456")
}

pub fn metadata_decoder_test() {
  let decoder = eventsourcing_glyn.metadata_decoder()
  let metadata_data =
    dynamic.array([dynamic.string("user_id"), dynamic.string("user_123")])

  let assert Ok(#("user_id", "user_123")) = decode.run(metadata_data, decoder)
}

@external(erlang, "gleam_stdlib", "identity")
fn cast(a: anything) -> dynamic.Dynamic
