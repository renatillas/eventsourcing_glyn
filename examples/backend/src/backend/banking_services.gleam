import domain/banking_domain
import eventsourcing
import eventsourcing/memory_store
import eventsourcing_glyn
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/static_supervisor
import gleam/otp/supervision

/// Configuration for distributed banking services
pub type ServiceConfig {
  ServiceConfig(
    pubsub_group: String,
    pubsub_command: String,
    pubsub_balance: String,
    pubsub_transaction: String,
    pubsub_audit: String,
    pubsub_websocket: String,
    websocket_broadcaster: process.Subject(WebSocketBroadcast),
  )
}

/// Messages sent to WebSocket broadcaster
pub type WebSocketBroadcast {
  BroadcastEvent(
    aggregate_id: String,
    events: List(banking_domain.BankAccountEvent),
  )
  BroadcastSnapshot(account_id: String, balance: Float, account_holder: String)
}

/// Service results for monitoring and testing
pub type ServiceResult {
  CommandValidated(aggregate_id: String, event_count: Int)
  BalanceUpdated(account_id: String, balance: Float)
  TransactionLogged(account_id: String, transaction_type: String, amount: Float)
  AuditRecorded(account_id: String, event_count: Int)
}

/// Start all distributed banking services
pub fn start_banking_services(
  config: ServiceConfig,
  service_results: process.Subject(ServiceResult),
) -> Result(
  #(
    eventsourcing.EventStore(_, _, _, _, _, _),
    supervision.ChildSpecification(static_supervisor.Supervisor),
  ),
  String,
) {
  // Command Processing Service - handles business logic
  let command_events = process.new_name("command_events")
  let command_snapshots = process.new_name("command_snapshots")
  let #(command_eventstore, command_memory_spec) =
    memory_store.supervised(
      command_events,
      command_snapshots,
      static_supervisor.OneForOne,
    )

  let command_queries = [
    #(process.new_name("command-validator"), fn(aggregate_id, events) {
      // Validate commands and log successful operations
      process.send(
        service_results,
        CommandValidated(aggregate_id, list.length(events)),
      )
    }),
  ]

  let assert Ok(#(command_glyn_store, command_glyn_spec)) =
    eventsourcing_glyn.supervised(
      eventsourcing_glyn.GlynConfig(
        pubsub_group: config.pubsub_group,
        pubsub_scope: config.pubsub_command,
      ),
      command_eventstore,
      command_queries,
      banking_domain.event_decoder_gleam(),
    )

  // Balance Tracking Service - maintains real-time balances
  let balance_events = process.new_name("balance_events")
  let balance_snapshots = process.new_name("balance_snapshots")
  let #(balance_eventstore, balance_memory_spec) =
    memory_store.supervised(
      balance_events,
      balance_snapshots,
      static_supervisor.OneForOne,
    )

  let balance_queries = [
    #(
      process.new_name("balance-tracker"),
      fn(
        aggregate_id: String,
        events: List(
          eventsourcing.EventEnvelop(banking_domain.BankAccountEvent),
        ),
      ) -> Nil {
        let events = list.map(events, fn(envelope) { envelope.payload })
        // Calculate and track current balance
        let balance = banking_domain.calculate_balance(events)
        let account_holder = banking_domain.get_account_holder(events)

        process.send(service_results, BalanceUpdated(aggregate_id, balance))

        // Broadcast balance updates to WebSocket clients
        process.send(
          config.websocket_broadcaster,
          BroadcastSnapshot(aggregate_id, balance, account_holder),
        )
      },
    ),
  ]

  let assert Ok(#(_balance_glyn_store, balance_glyn_spec)) =
    eventsourcing_glyn.supervised(
      eventsourcing_glyn.GlynConfig(
        pubsub_group: config.pubsub_group,
        pubsub_scope: config.pubsub_balance,
      ),
      balance_eventstore,
      balance_queries,
      banking_domain.event_decoder_gleam(),
    )

  // Transaction History Service - tracks all transactions
  let transaction_events = process.new_name("transaction_events")
  let transaction_snapshots = process.new_name("transaction_snapshots")
  let #(transaction_eventstore, transaction_memory_spec) =
    memory_store.supervised(
      transaction_events,
      transaction_snapshots,
      static_supervisor.OneForOne,
    )

  let transaction_queries = [
    #(process.new_name("transaction-logger"), fn(aggregate_id, events) {
      // Log individual transactions for history tracking
      list.each(
        events,
        fn(
          envelope: eventsourcing.EventEnvelop(banking_domain.BankAccountEvent),
        ) -> Nil {
          case envelope.payload {
            banking_domain.CustomerDepositedCash(amount, _) ->
              process.send(
                service_results,
                TransactionLogged(aggregate_id, "deposit", amount),
              )
            banking_domain.CustomerWithdrewCash(amount, _) ->
              process.send(
                service_results,
                TransactionLogged(aggregate_id, "withdrawal", amount),
              )
            _ -> Nil
          }
        },
      )
    }),
  ]

  let assert Ok(#(_transaction_glyn_store, transaction_glyn_spec)) =
    eventsourcing_glyn.supervised(
      eventsourcing_glyn.GlynConfig(
        pubsub_group: config.pubsub_group,
        pubsub_scope: config.pubsub_transaction,
      ),
      transaction_eventstore,
      transaction_queries,
      banking_domain.event_decoder_gleam(),
    )

  // Audit Service - compliance and regulatory logging
  let audit_events = process.new_name("audit_events")
  let audit_snapshots = process.new_name("audit_snapshots")
  let #(audit_eventstore, audit_memory_spec) =
    memory_store.supervised(
      audit_events,
      audit_snapshots,
      static_supervisor.OneForOne,
    )

  let audit_queries = [
    #(process.new_name("audit-logger"), fn(aggregate_id, events) {
      // Comprehensive audit logging for compliance
      process.send(
        service_results,
        AuditRecorded(aggregate_id, list.length(events)),
      )
      // In a real implementation, this would write to a secure, immutable audit log
      // such as AWS CloudTrail, Azure Monitor, or a blockchain-based audit system
    }),
  ]

  let assert Ok(#(_audit_glyn_store, audit_glyn_spec)) =
    eventsourcing_glyn.supervised(
      eventsourcing_glyn.GlynConfig(
        pubsub_group: config.pubsub_group,
        pubsub_scope: config.pubsub_audit,
      ),
      audit_eventstore,
      audit_queries,
      banking_domain.event_decoder_gleam(),
    )

  // WebSocket Broadcasting Service - real-time client updates
  let websocket_events = process.new_name("websocket_events")
  let websocket_snapshots = process.new_name("websocket_snapshots")
  let #(websocket_eventstore, websocket_memory_spec) =
    memory_store.supervised(
      websocket_events,
      websocket_snapshots,
      static_supervisor.OneForOne,
    )

  let websocket_queries = [
    #(process.new_name("websocket-broadcaster"), fn(aggregate_id, events) {
      // Broadcast events to all connected WebSocket clients
      process.send(
        config.websocket_broadcaster,
        BroadcastEvent(
          aggregate_id,
          list.map(
            events,
            fn(
              envelope: eventsourcing.EventEnvelop(
                banking_domain.BankAccountEvent,
              ),
            ) -> banking_domain.BankAccountEvent {
              envelope.payload
            },
          ),
        ),
      )
    }),
  ]

  let assert Ok(#(_websocket_glyn_store, websocket_glyn_spec)) =
    eventsourcing_glyn.supervised(
      eventsourcing_glyn.GlynConfig(
        pubsub_group: config.pubsub_group,
        pubsub_scope: config.pubsub_websocket,
      ),
      websocket_eventstore,
      websocket_queries,
      banking_domain.event_decoder_gleam(),
    )

  // Create combined supervisor for all services
  let services_supervisor =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(command_memory_spec)
    |> static_supervisor.add(command_glyn_spec)
    |> static_supervisor.add(balance_memory_spec)
    |> static_supervisor.add(balance_glyn_spec)
    |> static_supervisor.add(transaction_memory_spec)
    |> static_supervisor.add(transaction_glyn_spec)
    |> static_supervisor.add(audit_memory_spec)
    |> static_supervisor.add(audit_glyn_spec)
    |> static_supervisor.add(websocket_memory_spec)
    |> static_supervisor.add(websocket_glyn_spec)
    |> static_supervisor.supervised()

  Ok(#(command_glyn_store, services_supervisor))
}

/// Start the main event sourcing command processor
pub fn start_command_processor(
  eventstore: eventsourcing.EventStore(_, _, _, _, _, _),
) -> Result(
  process.Subject(
    eventsourcing.AggregateMessage(
      banking_domain.BankAccount,
      banking_domain.BankAccountCommand,
      banking_domain.BankAccountEvent,
      banking_domain.BankAccountError,
    ),
  ),
  a,
) {
  let es_name = process.new_name("banking-command-processor")

  let assert Ok(frequency) = eventsourcing.frequency(1)
  let assert Ok(es_spec) =
    eventsourcing.supervised(
      name: es_name,
      eventstore: eventstore,
      handle: banking_domain.handle,
      apply: banking_domain.apply,
      empty_state: banking_domain.UnopenedBankAccount,
      queries: [],
      snapshot_config: option.Some(eventsourcing.SnapshotConfig(frequency)),
    )

  let assert Ok(_es_sup) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(es_spec)
    |> static_supervisor.start()

  Ok(process.named_subject(es_name))
}

/// Service health check - verify all services are responding
pub fn health_check_services(
  command_processor: process.Subject(
    eventsourcing.AggregateMessage(_, banking_domain.BankAccountCommand, _, _),
  ),
  service_results: process.Subject(ServiceResult),
) -> Bool {
  // Execute a test command to verify the entire pipeline
  let test_account_id = "health-check-" <> int.to_string(system_time_ms())

  eventsourcing.execute(
    command_processor,
    test_account_id,
    banking_domain.OpenAccount(test_account_id, "Health Check"),
  )

  // Verify we receive responses from all services within timeout
  let expected_services = ["command", "balance", "audit"]
  let received_services = []

  verify_service_responses(
    service_results,
    expected_services,
    received_services,
    2000,
  )
}

fn verify_service_responses(
  results: process.Subject(ServiceResult),
  expected: List(String),
  received: List(String),
  timeout_ms: Int,
) -> Bool {
  case list.length(received) >= list.length(expected) {
    True -> True
    False -> {
      case process.receive(results, timeout_ms) {
        Ok(CommandValidated(_, _)) ->
          verify_service_responses(
            results,
            expected,
            ["command", ..received],
            timeout_ms,
          )
        Ok(BalanceUpdated(_, _)) ->
          verify_service_responses(
            results,
            expected,
            ["balance", ..received],
            timeout_ms,
          )
        Ok(AuditRecorded(_, _)) ->
          verify_service_responses(
            results,
            expected,
            ["audit", ..received],
            timeout_ms,
          )
        Ok(_) ->
          verify_service_responses(results, expected, received, timeout_ms)
        Error(_) -> False
      }
    }
  }
}

// Helper function to get current system time in milliseconds
@external(erlang, "erlang", "system_time")
fn system_time_ms() -> Int
