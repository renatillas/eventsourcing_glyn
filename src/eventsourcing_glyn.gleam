import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import glyn/pubsub
import glyn/registry

import eventsourcing.{
  type Aggregate, type AggregateId, type EventEnvelop, type EventSourcingError,
  type Query, type QueryMessage, EventStore, ProcessEvents,
}

/// Glyn-enhanced event store that wraps an existing event store implementation
/// and adds distributed PubSub for query actors and Registry for command routing
pub opaque type GlynStore(
  underlying_store,
  entity,
  command,
  event,
  error,
  transaction_handle,
) {
  GlynStore(
    pubsub_topic: String,
    registry_scope: String,
    glyn_instances: GlynInstances(event),
    underlying_store: eventsourcing.EventStore(
      underlying_store,
      entity,
      command,
      event,
      error,
      transaction_handle,
    ),
  )
}

/// Configuration for Glyn-based distributed event sourcing
pub type GlynConfig {
  GlynConfig(pubsub_topic: String, registry_scope: String)
}

/// Internal type to wrap Glyn PubSub and Registry instances
pub opaque type GlynInstances(event) {
  GlynInstances(
    pubsub: pubsub.PubSub(QueryMessage(event)),
    registry: registry.Registry(QueryMessage(event), Nil),
  )
}

/// Creates a Glyn-enhanced event store that wraps an existing event store
/// and adds distributed PubSub for query actors and Registry for command routing.
/// 
/// This creates a supervision tree that includes:
/// - Query actors that subscribe to Glyn PubSub for event notifications
/// - The enhanced event store that publishes events to all subscribers
/// - Integration with Glyn's distributed registry for aggregate lookups
///
/// ## Example
/// ```gleam
/// import eventsourcing/memory_store
/// import eventsourcing/glyn_store
/// 
/// // Set up underlying store (memory, postgres, etc.)
/// let #(underlying_store, underlying_spec) = memory_store.supervised(...)
/// 
/// // Wrap with Glyn distributed capabilities
/// let config = glyn_store.GlynConfig("bank_events", "bank_aggregates")
/// let queries = [#("balance_query", balance_query_fn)]
/// let assert Ok(#(glyn_eventstore, glyn_spec)) = glyn_store.supervised(
///   config,
///   underlying_store,
///   queries
/// )
/// ```
pub fn supervised(
  config: GlynConfig,
  underlying_store: eventsourcing.EventStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  queries: List(#(process.Name(QueryMessage(event)), Query(event))),
  event_decoder: decode.Decoder(event),
) -> Result(
  #(
    eventsourcing.EventStore(
      GlynStore(
        underlying_store,
        entity,
        command,
        event,
        error,
        transaction_handle,
      ),
      entity,
      command,
      event,
      error,
      transaction_handle,
    ),
    supervision.ChildSpecification(static_supervisor.Supervisor),
  ),
  String,
) {
  let message_decoder = {
    use aggregate_id <- decode.field(1, decode.string)
    use events <- decode.field(2, decode.list(payload_decoder(event_decoder)))
    decode.success(ProcessEvents(aggregate_id, events))
  }

  let glyn_pubsub =
    pubsub.new(
      config.pubsub_topic,
      message_decoder,
      ProcessEvents(aggregate_id: "error", events: []),
    )
  let glyn_registry =
    registry.new(
      config.registry_scope,
      message_decoder,
      ProcessEvents("error", []),
    )
  let glyn_instances = GlynInstances(glyn_pubsub, glyn_registry)

  let glyn_store =
    GlynStore(
      pubsub_topic: config.pubsub_topic,
      registry_scope: config.registry_scope,
      glyn_instances: glyn_instances,
      underlying_store: underlying_store,
    )

  let query_specs =
    list.map(queries, fn(query_def) {
      let #(query_name, query_fn) = query_def
      supervision.worker(fn() {
        start_glyn_query_actor(glyn_instances, query_name, query_fn)
      })
    })

  let eventstore =
    EventStore(
      eventstore: glyn_store,
      commit_events: fn(tx, aggregate, events, metadata) {
        glyn_commit_events(glyn_store, tx, aggregate, events, metadata)
      },
      load_events: fn(glyn_store, _, aggregate_id, start_from) {
        proxy_load_events(glyn_store, aggregate_id, start_from)
      },
      load_snapshot: fn(_, aggregate_id) {
        proxy_load_snapshot(glyn_store, aggregate_id)
      },
      save_snapshot: fn(_, snapshot) {
        proxy_save_snapshot(glyn_store, snapshot)
      },
      execute_transaction: fn(f) { proxy_execute_transaction(glyn_store, f) },
      get_latest_snapshot_transaction: fn(f) {
        proxy_get_latest_snapshot_transaction(glyn_store, f)
      },
      load_aggregate_transaction: fn(f) {
        proxy_load_aggregate_transaction(glyn_store, f)
      },
      load_events_transaction: fn(f) {
        proxy_load_events_transaction(glyn_store, f)
      },
    )

  let supervisor_spec =
    static_supervisor.new(static_supervisor.OneForOne)
    |> list.fold(query_specs, _, fn(sup, spec) {
      static_supervisor.add(sup, spec)
    })
    |> static_supervisor.supervised()

  Ok(#(eventstore, supervisor_spec))
}

@internal
pub fn serialized_event_envelop_decoder(event_decoder) {
  use aggregate_id <- decode.field(1, decode.string)
  use sequence <- decode.field(2, decode.int)
  use payload <- decode.field(3, event_decoder)
  use metadata <- decode.field(4, decode.list(metadata_decoder()))
  use event_type <- decode.field(5, decode.string)
  use event_version <- decode.field(6, decode.string)
  use aggregate_type <- decode.field(7, decode.string)
  decode.success(eventsourcing.SerializedEventEnvelop(
    aggregate_id:,
    sequence:,
    payload:,
    metadata:,
    event_type:,
    event_version:,
    aggregate_type:,
  ))
}

@internal
pub fn memory_store_event_envelop_decoder(event_decoder) {
  use aggregate_id <- decode.field(1, decode.string)
  use sequence <- decode.field(2, decode.int)
  use payload <- decode.field(3, event_decoder)
  use metadata <- decode.field(4, decode.list(metadata_decoder()))
  decode.success(eventsourcing.MemoryStoreEventEnvelop(
    aggregate_id:,
    sequence:,
    payload:,
    metadata:,
  ))
}

@internal
pub fn payload_decoder(event_decoder) {
  decode.one_of(memory_store_event_envelop_decoder(event_decoder), or: [
    serialized_event_envelop_decoder(event_decoder),
  ])
}

@internal
pub fn metadata_decoder() {
  use key <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(key, value))
}

fn glyn_commit_events(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  tx: transaction_handle,
  aggregate: Aggregate(entity, command, event, error),
  events: List(event),
  metadata: List(#(String, String)),
) -> Result(#(List(EventEnvelop(event)), Int), EventSourcingError(error)) {
  // For now, return a placeholder result - this would be implemented properly 
  // by calling the underlying store using the correct transaction pattern
  // In a production implementation, you'd need to:
  // 1. Correctly unwrap the transaction handle for the underlying store
  // 2. Call the underlying store's commit_events 
  // 3. Process the result and publish to Glyn PubSub
  use #(events, version) <- result.try(
    glyn_store.underlying_store.commit_events(tx, aggregate, events, metadata),
  )

  // Placeholder publish to Glyn PubSub
  use _ <- result.try(
    publish_to_glyn_pubsub(
      glyn_store.glyn_instances,
      aggregate.aggregate_id,
      events,
    )
    |> result.map_error(fn(_e) {
      eventsourcing.EventStoreError("Failed to publish to Glyn PubSub")
    }),
  )

  Ok(#(events, version))
}

// Proxy functions that delegate to the underlying event store
fn proxy_load_events(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  aggregate_id: AggregateId,
  start_from: Int,
) -> Result(List(EventEnvelop(event)), EventSourcingError(error)) {
  // Note: The tx parameter is the GlynStore itself, we need to get the underlying transaction
  // This is a simplified approach - in reality we'd need to properly handle transactions
  glyn_store.underlying_store.load_events_transaction(fn(underlying_tx) {
    glyn_store.underlying_store.load_events(
      glyn_store.underlying_store.eventstore,
      underlying_tx,
      aggregate_id,
      start_from,
    )
  })
}

fn proxy_load_snapshot(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  aggregate_id: AggregateId,
) -> Result(Option(eventsourcing.Snapshot(entity)), EventSourcingError(error)) {
  glyn_store.underlying_store.get_latest_snapshot_transaction(fn(underlying_tx) {
    glyn_store.underlying_store.load_snapshot(underlying_tx, aggregate_id)
  })
}

fn proxy_save_snapshot(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  snapshot: eventsourcing.Snapshot(entity),
) -> Result(Nil, EventSourcingError(error)) {
  glyn_store.underlying_store.execute_transaction(fn(underlying_tx) {
    glyn_store.underlying_store.save_snapshot(underlying_tx, snapshot)
  })
}

fn proxy_execute_transaction(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  transaction_fn,
) -> Result(Nil, EventSourcingError(error)) {
  glyn_store.underlying_store.execute_transaction(transaction_fn)
}

fn proxy_get_latest_snapshot_transaction(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  transaction_fn,
) -> Result(Option(eventsourcing.Snapshot(entity)), EventSourcingError(error)) {
  glyn_store.underlying_store.get_latest_snapshot_transaction(transaction_fn)
}

fn proxy_load_aggregate_transaction(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  transaction_fn,
) -> Result(Aggregate(entity, command, event, error), EventSourcingError(error)) {
  glyn_store.underlying_store.load_aggregate_transaction(transaction_fn)
}

fn proxy_load_events_transaction(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  transaction_fn,
) -> Result(List(EventEnvelop(event)), EventSourcingError(error)) {
  glyn_store.underlying_store.load_events_transaction(transaction_fn)
}

/// Start a query actor that subscribes to Glyn PubSub for event notifications
pub fn start_glyn_query_actor(
  glyn_instances: GlynInstances(event),
  query_name: process.Name(QueryMessage(event)),
  query_fn: Query(event),
) -> actor.StartResult(process.Subject(QueryMessage(event))) {
  use started_actor <- result.map(
    actor.new_with_initialiser(500, fn(subject) {
      let subscription_selector =
        pubsub.subscribe(glyn_instances.pubsub, "events")

      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.merge_selector(subscription_selector)

      actor.initialised(subject)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(fn(state, message) {
      case message {
        ProcessEvents(aggregate_id, events) -> {
          query_fn(aggregate_id, events)
          actor.continue(state)
        }
      }
    })
    |> actor.named(query_name)
    |> actor.start(),
  )

  started_actor
}

/// Publish an event to Glyn PubSub for distribution to all query subscribers
fn publish_to_glyn_pubsub(
  glyn_instances: GlynInstances(event),
  aggregate_id: AggregateId,
  events: List(EventEnvelop(event)),
) -> Result(Int, pubsub.PubSubError) {
  let message = ProcessEvents(aggregate_id, events)
  pubsub.publish(glyn_instances.pubsub, "events", message)
}
