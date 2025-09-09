# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2024-12-09

### Added
- Initial release of `eventsourcing_glyn` library
- Distributed event sourcing capabilities using Glyn PubSub and Registry
- `GlynStore` wrapper that enhances existing event stores with distributed features
- `supervised/4` function for creating supervised Glyn-enhanced event stores
- `publish/3` function for publishing events to distributed query subscribers
- Support for distributed query actors via PubSub subscriptions
- Event decoders for both memory store and serialized event formats
- Complete integration with the `eventsourcing` library ecosystem

### Features
- **Distributed PubSub**: Query actors subscribe to events across multiple nodes
- **Fault Tolerance**: Built-in supervision for all distributed components
- **Store Agnostic**: Works with any underlying event store (memory, postgres, etc.)
- **Type Safety**: Full Gleam type safety with generic event and entity types
- **Event Broadcasting**: Automatic distribution of events to all subscribers

### Documentation
- Comprehensive API documentation with examples
- Distributed nodes example demonstrating multi-service coordination
- Setup instructions for running services as distributed Erlang nodes

### Dependencies
- `gleam_stdlib` >= 0.52.0 and < 2.0.0
- `gleam_otp` >= 1.1.0 and < 2.0.0
- `gleam_erlang` >= 1.3.0 and < 2.0.0
- `eventsourcing` >= 9.0.0 and < 10.0.0
- `glyn` >= 2.0.0 and < 3.0.0