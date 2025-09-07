# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-09-07

### Added
- Initial release of eventsourcing_glyn library
- `GlynStore` wrapper for existing event stores with distributed capabilities
- `GlynConfig` type for configuring PubSub topics and Registry scopes
- `supervised/4` function for creating supervised Glyn-enhanced event stores
- Query actor management with automatic PubSub subscription
- Event decoders for memory store and serialized event envelopes
- Metadata decoder for event envelope metadata
- Proxy functions for delegating to underlying event stores:
  - `proxy_load_events/3`
  - `proxy_load_snapshot/2`
  - `proxy_save_snapshot/2`
  - `proxy_execute_transaction/2`
  - `proxy_get_latest_snapshot_transaction/2`
  - `proxy_load_aggregate_transaction/2`
  - `proxy_load_events_transaction/2`
- `start_glyn_query_actor/3` for manual query actor creation
- `publish_to_glyn_pubsub/3` for event distribution
- Comprehensive supervision tree setup

### Features
- **Distributed Event Store**: Wraps any existing event store with Glyn PubSub/Registry
- **Query Actor Management**: Supervised query actors that automatically subscribe to events
- **Event Broadcasting**: Automatic distribution of committed events to all query subscribers
- **Registry Integration**: Distributed aggregate lookup capabilities
- **Fault Tolerance**: Full supervision tree with OneForOne restart strategy
- **Event Store Agnostic**: Works with memory, PostgreSQL, and other event store implementations

### Testing
- 20+ comprehensive test cases covering:
  - Core functionality and configuration
  - Decoder functions with error scenarios
  - Proxy function delegation
  - PubSub event distribution
  - Query actor lifecycle management
  - Transaction handling
  - Integration tests with bank account domain example
- 1000+ lines of test code across 5 test files
- Full end-to-end testing with real supervision trees

### Dependencies
- gleam_stdlib >= 0.52.0
- gleam_otp >= 1.1.0
- gleam_erlang >= 1.3.0
- eventsourcing >= 9.0.0
- glyn >= 2.0.0

### Development Dependencies
- gleeunit >= 1.2.0 (testing framework)
- gleam_json >= 3.0.2 (JSON encoding/decoding for tests)

### Documentation
- Complete README with quick start guide and examples
- Inline documentation for all public functions
- Example bank account domain for demonstration
- Integration patterns and best practices