# ConvosConnectionsExample

A minimal iOS app that exercises the `ConvosConnections` package end-to-end. Useful for:

- Testing new `DataSource` implementations on a real device or simulator before the rest of the Convos app is ready.
- Demonstrating the "payload → conversation" delivery model without needing XMTP or a running Convos stack.
- Hand-testing authorization flows for sensitive frameworks like HealthKit and EventKit.

## Running it

```bash
open ConvosConnections/Example/ConvosConnectionsExample.xcodeproj
```

Select the `ConvosConnectionsExample` scheme, pick an iPhone simulator (iOS 26+), and run.

The first launch will:
1. Prompt for HealthKit when you toggle "Health" on.
2. Prompt for Calendar when you toggle "Calendar" on.

Decline either prompt to see denied-state behavior.

## Building from the command line

Xcode's Run button handles code signing automatically — just open the project and hit ⌘R. For CLI builds, you need to opt into ad-hoc simulator signing so the HealthKit entitlement sticks:

```bash
xcodebuild \
    -project ConvosConnectionsExample.xcodeproj \
    -scheme ConvosConnectionsExample \
    -sdk iphonesimulator \
    -destination 'id=<booted-simulator-udid>' \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build
```

Using `CODE_SIGNING_ALLOWED=NO` strips entitlements and HealthKit will refuse to authorize with "Missing com.apple.developer.healthkit entitlement."

## How it works

The app mirrors the real Convos flow but replaces XMTP with an in-memory store:

- `ExampleModel` owns a `ConnectionsManager` configured with `HealthDataSource` and `CalendarDataSource`.
- `MockMessageStore` stands in for XMTP. It implements `ConnectionDelivering` and keeps every payload in an in-memory dictionary keyed by mock conversation id.
- Each connection is mapped to a single mock conversation id: `example:health`, `example:calendar`, etc.
- Toggling a connection on enables that `(kind, conversationId)` pair in an `InMemoryEnablementStore` and starts the source (prompting for authorization if needed).
- The feed view for a connection is a chat-style list of every payload delivered to that connection's mock conversation — structurally identical to how a real conversation would render these messages in Convos.

## The "Simulate payload" button

Observer queries (HealthKit) and `EKEventStoreChanged` (EventKit) only fire when new data actually arrives. In a fresh simulator that rarely happens, so the feed view exposes a "Simulate payload" button that calls the source's snapshot method (`snapshotLast24Hours()` / `snapshotCurrentWindow()`) and delivers the result directly. This lets you verify end-to-end delivery without seeding the simulator with real data.

## Adding a new connection to the example

1. Implement the `DataSource` inside `ConvosConnections` (see `HealthDataSource` / `CalendarDataSource` for the pattern).
2. Add it to the `sources` array in `ExampleModel.init`.
3. If the source has a snapshot method, add a `case` for it to `ExampleModel.simulateSnapshot(for:)`.
4. If it has a new `ConnectionPayloadBody` case, add a matching body view to `ConnectionFeedView.MessageBubble.bodyDetails`.

The app picks up new source types automatically via `manager.availableKinds()`.

## Entitlements

`ConvosConnectionsExample.entitlements` declares HealthKit. EventKit does not require an entitlement — only the `NSCalendarsFullAccessUsageDescription` string in the generated Info.plist.

If you add a source that needs additional entitlements (Location background mode, HomeKit, etc.), extend `ConvosConnectionsExample.entitlements` and add the matching `INFOPLIST_KEY_*` build setting to both `Debug` and `Release` configurations in the pbxproj.
