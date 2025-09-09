import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import glyn/pubsub

import eventsourcing.{
  type Aggregate, type AggregateId, type EventEnvelop, type EventSourcingError,
  type Query, type QueryMessage, EventStore, ProcessEvents,
}

/// A Glyn-enhanced event store that wraps an existing event store implementation
/// and adds distributed PubSub capabilities for query actors and event broadcasting.
///
/// This opaque type maintains the same interface as the underlying event store
/// while transparently adding distributed features:
/// - Events committed to this store are automatically broadcast to all query subscribers
/// - Query actors across multiple nodes receive events via Glyn PubSub
/// - All event store operations are proxied to the underlying implementation
///
/// ## Type Parameters
/// - `underlying_store`: The type of the wrapped event store
/// - `entity`: The aggregate entity type
/// - `command`: The command type for this aggregate
/// - `event`: The event type for this aggregate
/// - `error`: The error type for this aggregate
/// - `transaction_handle`: The transaction handle type of the underlying store
pub opaque type GlynStore(
  underlying_store,
  entity,
  command,
  event,
  error,
  transaction_handle,
) {
  GlynStore(
    pubsub_scope: String,
    pubsub_group: String,
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

/// Configuration for Glyn-based distributed event sourcing.
///
/// This configuration determines how services discover each other and coordinate
/// event distribution across the cluster.
///
/// ## Fields
/// - `pubsub_scope`: A unique identifier for the PubSub topic namespace. All services
///   participating in the same event sourcing cluster should use the same scope.
/// - `pubsub_group`: The subscriber group name used for service discovery. Query actors
///   subscribe to this group to receive distributed events.
///
/// ## Example
/// ```gleam
/// let config = GlynConfig(
///   pubsub_scope: "banking_events",
///   pubsub_group: "banking_services"
/// )
/// ```
pub type GlynConfig {
  GlynConfig(pubsub_scope: String, pubsub_group: String)
}

/// Internal type to wrap Glyn PubSub and Registry instances
type GlynInstances(event) {
  GlynInstances(pubsub: pubsub.PubSub(QueryMessage(event)))
}

/// Creates a supervised Glyn-enhanced event store that wraps an existing event store
/// and adds distributed PubSub capabilities for query actors and event broadcasting.
/// 
/// This function creates a complete supervision tree that includes:
/// - Query actors that automatically subscribe to Glyn PubSub for event notifications
/// - The enhanced event store that publishes committed events to all subscribers
/// - Integration with Glyn's distributed coordination system
/// - Fault-tolerant supervision of all distributed components
///
/// ## Example
/// ```gleam
/// import eventsourcing_glyn
/// import eventsourcing/memory_store
/// import gleam/otp/static_supervisor
/// 
/// // 1. Set up underlying store
/// let #(underlying_store, memory_spec) = memory_store.supervised(
///   process.new_name("events"),
///   process.new_name("snapshots"), 
///   static_supervisor.OneForOne
/// )
/// 
/// // 2. Configure distributed capabilities
/// let config = eventsourcing_glyn.GlynConfig(
///   pubsub_scope: "bank_events",
///   pubsub_group: "bank_services"
/// )
/// 
/// // 3. Define query actors
/// let queries = [
///   #(process.new_name("balance_query"), balance_query_fn),
///   #(process.new_name("audit_query"), audit_query_fn),
/// ]
/// 
/// // 4. Create distributed event store
/// let assert Ok(#(glyn_eventstore, glyn_spec)) = eventsourcing_glyn.supervised(
///   config,
///   underlying_store,
///   queries,
///   my_event_decoder()
/// )
/// 
/// // 5. Start supervision tree
/// let assert Ok(_) =
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(memory_spec)
///   |> static_supervisor.add(glyn_spec)
///   |> static_supervisor.start()
/// ```
///
/// ## Query Actor Behavior
/// Each query actor receives a `QueryMessage(event)` containing:
/// - `ProcessEvents(aggregate_id, events)`: List of events to process
/// 
/// Query functions have the signature:
/// ```gleam
/// fn(aggregate_id: String, events: List(EventEnvelop(event))) -> Nil
/// ```
///
/// ## Distributed Event Flow
/// 1. Service A commits events via `eventsourcing.execute()`
/// 2. Events are persisted to the underlying store
/// 3. Events are automatically broadcast via Glyn PubSub
/// 4. All query actors across all nodes receive and process the events
/// 5. Query actors update their projections/views accordingly
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
      config.pubsub_scope,
      message_decoder,
      ProcessEvents(aggregate_id: "error", events: []),
    )

  let glyn_instances = GlynInstances(glyn_pubsub)

  let glyn_store =
    GlynStore(
      pubsub_scope: config.pubsub_scope,
      pubsub_group: config.pubsub_group,
      glyn_instances: glyn_instances,
      underlying_store: underlying_store,
    )

  let query_specs =
    list.map(queries, fn(query_def) {
      let #(query_name, query_fn) = query_def
      supervision.worker(fn() {
        start_glyn_query_actor(
          glyn_instances,
          query_name,
          query_fn,
          config.pubsub_group,
        )
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
pub fn get_glyn_store(
  eventstore: eventsourcing.EventStore(
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
) -> GlynStore(
  underlying_store,
  entity,
  command,
  event,
  error,
  transaction_handle,
) {
  eventstore.eventstore
}

@internal
pub fn serialized_event_envelop_decoder(
  event_decoder: decode.Decoder(a),
) -> decode.Decoder(EventEnvelop(a)) {
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
    metadata: metadata,
    event_type:,
    event_version:,
    aggregate_type:,
  ))
}

@internal
pub fn memory_store_event_envelop_decoder(
  event_decoder: decode.Decoder(event),
) -> decode.Decoder(EventEnvelop(event)) {
  use aggregate_id <- decode.field(1, decode.string)
  use sequence <- decode.field(2, decode.int)
  use payload <- decode.field(3, event_decoder)
  decode.success(
    eventsourcing.MemoryStoreEventEnvelop(
      aggregate_id: aggregate_id,
      sequence: sequence,
      payload:,
      metadata: [],
    ),
  )
}

@internal
pub fn payload_decoder(
  event_decoder: decode.Decoder(event),
) -> decode.Decoder(EventEnvelop(event)) {
  decode.one_of(memory_store_event_envelop_decoder(event_decoder), or: [
    serialized_event_envelop_decoder(event_decoder),
  ])
}

@internal
pub fn metadata_decoder() -> decode.Decoder(#(String, String)) {
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
  use #(events, version) <- result.try(
    glyn_store.underlying_store.commit_events(tx, aggregate, events, metadata),
  )

  use _ <- result.try(
    publish_to_glyn_pubsub(glyn_store, aggregate.aggregate_id, events)
    |> result.map_error(fn(_e) {
      eventsourcing.EventStoreError("Failed to publish to Glyn PubSub")
    }),
  )

  Ok(#(events, version))
}

/// Publish an event to Glyn PubSub for distribution to all query subscribers
fn publish_to_glyn_pubsub(
  glyn_instances: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  aggregate_id: AggregateId,
  events: List(EventEnvelop(event)),
) -> Result(Int, pubsub.PubSubError) {
  let message = ProcessEvents(aggregate_id, events)
  pubsub.publish(
    glyn_instances.glyn_instances.pubsub,
    glyn_instances.pubsub_group,
    message,
  )
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

fn start_glyn_query_actor(
  glyn_instances: GlynInstances(event),
  query_name: process.Name(QueryMessage(event)),
  query_fn: Query(event),
  pubsub_group: String,
) -> actor.StartResult(process.Subject(QueryMessage(event))) {
  use started_actor <- result.map(
    actor.new_with_initialiser(500, fn(subject) {
      let subscription_selector =
        pubsub.subscribe(glyn_instances.pubsub, pubsub_group)

      let selector =
        process.new_selector()
        |> process.merge_selector(subscription_selector)

      actor.initialised(subject)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(fn(state, message) {
      case message {
        ProcessEvents(aggregate_id, events) -> {
          io.println(
            "📥 Query actor received "
            <> int.to_string(list.length(events))
            <> " events for aggregate: "
            <> aggregate_id,
          )
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

/// Get the list of subscribers to this Glyn event store's PubSub scope.
///
/// This function returns information about all query actors currently subscribed
/// to receive events from this distributed event store across all connected nodes.
///
/// ## Example
/// ```gleam
/// let subscriber_info = eventsourcing_glyn.subscribers(glyn_eventstore)
/// // Use for monitoring or debugging distributed event flow
/// ```
///
/// ## Use Cases
/// - **Health Monitoring**: Check if expected query actors are connected
/// - **Debugging**: Verify event distribution is working correctly  
/// - **Load Balancing**: Understand the distribution of query actors
/// - **Troubleshooting**: Identify disconnected or failed nodes
pub fn subscribers(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
) -> List(process.Pid) {
  pubsub.subscribers(glyn_store.glyn_instances.pubsub, glyn_store.pubsub_scope)
}

/// Manually publish an event message to distributed query subscribers.
///
/// This function allows you to send custom messages to query actors without
/// going through the normal event store commit process. This is useful for:
/// - Broadcasting system events or notifications
/// - Triggering query actor maintenance or refresh operations
/// - Testing distributed event handling
///
/// ## Example
/// ```gleam
/// import eventsourcing_glyn
/// import eventsourcing.{ProcessEvents}
/// 
/// // Send a custom event to all query actors
/// let message = ProcessEvents("system", [maintenance_event])
/// case eventsourcing_glyn.publish(glyn_store, "bank_services", message) {
///   Ok(count) -> io.println("Notified " <> int.to_string(count) <> " subscribers")
///   Error(error) -> io.println("Failed to publish: " <> string.inspect(error))
/// }
/// ```
///
/// ## Important Notes
/// - **Normal Usage**: Most events should go through `eventsourcing.execute()` for proper persistence
/// - **Manual Publishing**: Only use this for system events or testing scenarios
/// - **Group Matching**: The group parameter should typically match your `GlynConfig.pubsub_group`
/// - **Return Value**: The count indicates how many query actors received the message
pub fn publish(
  glyn_store: GlynStore(
    underlying_store,
    entity,
    command,
    event,
    error,
    transaction_handle,
  ),
  group: String,
  message: QueryMessage(event),
) -> Result(Int, eventsourcing.EventSourcingError(error)) {
  pubsub.publish(glyn_store.glyn_instances.pubsub, group, message)
  |> result.map_error(fn(error) {
    case error {
      pubsub.PublishFailed(error) ->
        eventsourcing.EventStoreError(
          "Failed to publish to Glyn PubSub: " <> error,
        )
    }
  })
}
