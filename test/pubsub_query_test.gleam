import eventsourcing
import eventsourcing/memory_store
import eventsourcing_glyn
import example_bank_account
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/static_supervisor

pub fn query_actor_multiple_events_test() {
  let config = eventsourcing_glyn.GlynConfig("multi_events", "multi_aggregates")
  let events_actor_name = process.new_name("multi_events_actor")
  let snapshot_actor_name = process.new_name("multi_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let query_results = process.new_subject()
  let event_counter = process.new_subject()

  let queries_glyn = [
    #(process.new_name("multi-events-query"), fn(aggregate_id, events) {
      let event_count = list.length(events)
      process.send(query_results, #(aggregate_id, event_count))
      process.send(event_counter, event_count)
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

  let name = process.new_name("multi-eventsourcing")

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

  // Execute multiple commands
  eventsourcing.execute(
    eventsourcing,
    "multi-test-001",
    example_bank_account.OpenAccount("multi-test-001"),
  )
  let assert Ok(#("multi-test-001", 1)) = process.receive(query_results, 1000)

  eventsourcing.execute(
    eventsourcing,
    "multi-test-001",
    example_bank_account.DepositMoney(50.0),
  )
  let assert Ok(#("multi-test-001", 1)) = process.receive(query_results, 1000)

  eventsourcing.execute(
    eventsourcing,
    "multi-test-001",
    example_bank_account.DepositMoney(25.0),
  )
  let assert Ok(#("multi-test-001", 1)) = process.receive(query_results, 1000)

  // Verify we received 3 separate event notifications (each with 1 event)
  let assert Ok(1) = process.receive(event_counter, 1000)
  let assert Ok(1) = process.receive(event_counter, 1000)
  let assert Ok(1) = process.receive(event_counter, 1000)
}

pub fn query_actor_startup_test() {
  let config =
    eventsourcing_glyn.GlynConfig("startup_events", "startup_aggregates")
  let events_actor_name = process.new_name("startup_events_actor")
  let snapshot_actor_name = process.new_name("startup_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let startup_confirmation = process.new_subject()

  let queries_glyn = [
    #(process.new_name("startup-query"), fn(_aggregate_id, _events) {
      process.send(startup_confirmation, "query_actor_started")
    }),
  ]

  let assert Ok(#(_glyn_eventstore, glyn_child_spec)) =
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

  process.sleep(200)

  // Query actors should be started and supervised
  True
}

pub fn multiple_query_actors_test() {
  let config =
    eventsourcing_glyn.GlynConfig("multiple_events", "multiple_aggregates")
  let events_actor_name = process.new_name("multiple_events_actor")
  let snapshot_actor_name = process.new_name("multiple_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let query_results_a = process.new_subject()
  let query_results_b = process.new_subject()

  let queries_glyn = [
    #(process.new_name("query-a"), fn(aggregate_id, events) {
      process.send(query_results_a, #(
        aggregate_id,
        "query-a",
        list.length(events),
      ))
    }),
    #(process.new_name("query-b"), fn(aggregate_id, events) {
      process.send(query_results_b, #(
        aggregate_id,
        "query-b",
        list.length(events),
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

  let name = process.new_name("multiple-eventsourcing")

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

  // Execute command - both query actors should receive the event
  eventsourcing.execute(
    eventsourcing,
    "multiple-test-001",
    example_bank_account.OpenAccount("multiple-test-001"),
  )

  let assert Ok(#("multiple-test-001", "query-a", 1)) =
    process.receive(query_results_a, 1000)
  let assert Ok(#("multiple-test-001", "query-b", 1)) =
    process.receive(query_results_b, 1000)
}

pub fn pubsub_distribution_test() {
  let config =
    eventsourcing_glyn.GlynConfig(
      "distribution_events",
      "distribution_aggregates",
    )
  let events_actor_name = process.new_name("distribution_events_actor")
  let snapshot_actor_name = process.new_name("distribution_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  let aggregated_results = process.new_subject()
  let event_aggregate = fn(aggregate_id, events) {
    let event_types =
      list.map(
        events,
        fn(
          envelope: eventsourcing.EventEnvelop(
            example_bank_account.BankAccountEvent,
          ),
        ) {
          case envelope.payload {
            example_bank_account.AccountOpened(_) -> "opened"
            example_bank_account.CustomerDepositedCash(_, _) -> "deposit"
            example_bank_account.CustomerWithdrewCash(_, _) -> "withdraw"
            example_bank_account.AccountClosed -> "closed"
          }
        },
      )
    process.send(aggregated_results, #(aggregate_id, event_types))
  }

  let queries_glyn = [
    #(process.new_name("aggregate-query"), event_aggregate),
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

  let name = process.new_name("distribution-eventsourcing")

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

  // Execute command sequence
  eventsourcing.execute(
    eventsourcing,
    "distribution-test-001",
    example_bank_account.OpenAccount("distribution-test-001"),
  )
  let assert Ok(#("distribution-test-001", ["opened"])) =
    process.receive(aggregated_results, 1000)

  eventsourcing.execute(
    eventsourcing,
    "distribution-test-001",
    example_bank_account.DepositMoney(100.0),
  )
  let assert Ok(#("distribution-test-001", ["deposit"])) =
    process.receive(aggregated_results, 1000)

  eventsourcing.execute(
    eventsourcing,
    "distribution-test-001",
    example_bank_account.WithDrawMoney(25.0),
  )
  let assert Ok(#("distribution-test-001", ["withdraw"])) =
    process.receive(aggregated_results, 1000)
}

pub fn empty_queries_list_test() {
  let config = eventsourcing_glyn.GlynConfig("empty_events", "empty_aggregates")
  let events_actor_name = process.new_name("empty_events_actor")
  let snapshot_actor_name = process.new_name("empty_snapshot_actor")
  let #(underlying_eventstore, memory_store_child_spec) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )

  // Test with empty queries list
  let queries_glyn = []

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

  let name = process.new_name("empty-eventsourcing")

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

  // Execute command - should work even with no query actors
  eventsourcing.execute(
    eventsourcing,
    "empty-test-001",
    example_bank_account.OpenAccount("empty-test-001"),
  )

  process.sleep(100)
  True
}
