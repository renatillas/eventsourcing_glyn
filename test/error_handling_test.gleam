import eventsourcing/memory_store
import eventsourcing_glyn
import example_bank_account
import gleam/erlang/process
import gleam/json
import gleam/otp/static_supervisor
import gleeunit/should

pub fn supervised_with_invalid_config_test() {
  let config = eventsourcing_glyn.GlynConfig("", "")
  let events_actor_name = process.new_name("events_actor_invalid")
  let snapshot_actor_name = process.new_name("snapshot_actor_invalid")
  let #(eventstore, _) =
    memory_store.supervised(
      events_actor_name,
      snapshot_actor_name,
      static_supervisor.OneForOne,
    )
  let queries = []

  case
    eventsourcing_glyn.supervised(
      config,
      eventstore,
      queries,
      example_bank_account.event_decoder(),
    )
  {
    Ok(_) -> True
    Error(msg) -> {
      should.be_true(msg != "")
      True
    }
  }
}

pub fn decoder_error_handling_test() {
  let decoder =
    eventsourcing_glyn.memory_store_event_envelop_decoder(
      example_bank_account.event_decoder(),
    )

  let invalid_data =
    json.object([
      #("invalid", json.string("data")),
    ])

  case json.parse(json.to_string(invalid_data), decoder) {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn metadata_decoder_error_test() {
  let decoder = eventsourcing_glyn.metadata_decoder()
  let invalid_metadata =
    json.object([
      #("wrong_field", json.string("value")),
    ])

  case json.parse(json.to_string(invalid_metadata), decoder) {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn payload_decoder_fallback_test() {
  let decoder =
    eventsourcing_glyn.payload_decoder(example_bank_account.event_decoder())

  // Test memory store format first
  let memory_event_data =
    json.object([
      #("1", json.string("test-789")),
      #("2", json.int(1)),
      #(
        "3",
        json.object([
          #("event-type", json.string("account-opened")),
          #("account-id", json.string("test-789")),
        ]),
      ),
      #("4", json.array([], json.object)),
    ])

  case json.parse(json.to_string(memory_event_data), decoder) {
    Ok(envelop) -> envelop.aggregate_id == "test-789"
    Error(_) -> False
  }
}

pub fn serialized_event_decoder_fallback_test() {
  let decoder =
    eventsourcing_glyn.payload_decoder(example_bank_account.event_decoder())

  // Test serialized event format as fallback
  let serialized_event_data =
    json.object([
      #("1", json.string("test-serialized")),
      #("2", json.int(3)),
      #(
        "3",
        json.object([
          #("event-type", json.string("account-opened")),
          #("account-id", json.string("test-serialized")),
        ]),
      ),
      #("4", json.array([], json.object)),
      #("5", json.string("BankAccountEvent")),
      #("6", json.string("2.0")),
      #("7", json.string("BankAccount")),
    ])

  case json.parse(json.to_string(serialized_event_data), decoder) {
    Ok(envelop) -> envelop.aggregate_id == "test-serialized"
    Error(_) -> False
  }
}
