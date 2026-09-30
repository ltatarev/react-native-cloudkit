# @ltatarev/react-native-cloudkit

CloudKit sync and zone-wide sharing for bare React Native apps, built on
`CKSyncEngine`. The package never learns what your data is. Your app's own
database stays the source of truth. The package only moves changes in and
out of iCloud.

- iOS 17 or later. On Android every call resolves with an empty or "not
  available" answer, and `isAvailable()` is `false`.
- One dependency: `react-native-nitro-modules`. Native code uses the system
  `sqlite3`, CloudKit, UIKit and Network only.
- No Expo config plugin. The setup below is by hand.

## Install

```sh
yarn add @ltatarev/react-native-cloudkit react-native-nitro-modules
cd ios && pod install
```

## Bare app setup

1. In the Apple Developer portal, create an iCloud container
   (`iCloud.com.example.app`). Enable iCloud (CloudKit) and Push
   Notifications on the app's bundle id.
2. Raise the iOS target to 17: `platform :ios, '17.0'` in the `Podfile`, and
   `IPHONEOS_DEPLOYMENT_TARGET = 17.0` on the app target.
3. Add an entitlements file, and set `CODE_SIGN_ENTITLEMENTS` to it:

   ```xml
   <key>aps-environment</key>
   <string>development</string>
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array><string>iCloud.com.example.app</string></array>
   <key>com.apple.developer.icloud-services</key>
   <array><string>CloudKit</string></array>
   ```

4. In `Info.plist`, add `CKSharingSupported` (`true`) and the background
   mode:

   ```xml
   <key>CKSharingSupported</key>
   <true/>
   <key>UIBackgroundModes</key>
   <array><string>remote-notification</string></array>
   ```

5. In the AppDelegate, add one method, so a tapped share link reaches the
   package. The app target cannot import the package module (it needs C++
   interop), so the method posts one notification:

   ```swift
   import CloudKit

   func application(
     _ application: UIApplication,
     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
   ) {
     NotificationCenter.default.post(
       name: Notification.Name("RNCKUserDidAcceptCloudKitShare"), object: metadata)
   }
   ```

   This works for an app without a scene manifest. An app with one gets the
   metadata in `windowScene(_:userDidAcceptCloudKitShareWith:)` and posts the
   same notification there.

6. Build and run on a device signed in to iCloud. `getAccountStatus()`
   resolves `available`.

## Configure

Call `configure` once at launch, before any other call.

```ts
import { configure } from '@ltatarev/react-native-cloudkit';

await configure({
  containerId: 'iCloud.com.example.app',
  recordTypes: {
    Note: {
      fields: { title: 'string', body: 'string', pinnedAt: 'date' },
      conflict: 'fieldMerge', // the default
    },
  },
});
```

Field types: `string`, `int`, `double`, `bool`, `date`, `stringList`. A
record type and a field start with a letter. The prefix `RNCK_` is
reserved: the package writes `RNCK_fieldTimes` on every record.

Names: a zone or record name is ASCII, 255 characters or fewer, and does not
start with `_`. A user id starts with `_`, so put it after a prefix
(`take-<userId>-…`).

## Write, then read the inbox

Writes go to a native outbox and return at once, online or offline. The
engine sends them when it can.

```ts
await saveRecords([
  { zone: { scope: 'private', name: 'notes' }, recordName: 'note-1',
    recordType: 'Note', fields: { title: 'Hi', body: '' } },
]);
```

Inbound changes wait in a durable inbox until you ack them. Apply them to
your database first, then ack:

```ts
addListener('inboxChanged', async () => {
  const events = await drainInbox();
  await applyToMyDatabase(events); // one transaction
  await ackInbox(events.map((event) => event.id));
});
```

Drain once at launch too: a push can fetch while JS is not running.

Event kinds: `upsert` (with `createdBy`, `modifiedBy`, `createdAt`,
`modifiedAt`), `delete`, `zoneDeleted`, `conflictResolved`, and
`writeFailed` (for example a read-only participant's write).

### Conflicts

The policy is per record type:

- `fieldMerge` (default): each field keeps the newer edit, by the
  per-field time in `RNCK_fieldTimes`. A tie goes to the server.
- `serverWins`: the server's record wins.
- `clientWins`: this device's fields win.

The app gets `conflictResolved`, and an `upsert` with the result when the
record is not what the app holds. **Clock skew:** `fieldMerge` trusts the
device clocks. A device with a wrong clock can make an older edit win. This
is accepted, because most records have one writer.

### Zone deleted: the app's obligations

| Reason | Cause | The package | The app |
| --- | --- | --- | --- |
| `deleted` | Another device of the same reader deleted the zone. | Clears the zone's rows. | Deletes the zone's local data. |
| `purged` | The reader deleted the app's iCloud data in Settings. | Clears the zone's rows and marks the zone "do not sync". `saveRecords` into it fails with `zoneNotSyncing` until `ensureZone`. | Keeps local data. Does not upload it again. |
| `encryptedDataReset` | The reader reset the account's encryption keys. | Creates the zone again, clears its system fields and outbox. | Keeps local data and saves every record of the zone again. This is the only "send everything" signal. |
| `shareEnded` | The owner stopped sharing, or removed this participant. | Clears the zone's rows. | Offers "Keep a copy". |

### Account changed: the app's obligations

| Kind | The package | The app |
| --- | --- | --- |
| `signIn` | Keeps the outbox, so edits made while signed out are sent. | Saves again every local record it wants in iCloud. |
| `signOut` | Deletes the whole store, outbox included. | Decides about its local data. |
| `switchAccounts` | Deletes the whole store, outbox included. | Decides whether to upload its local data into the new account. The package never does this by itself. |

The data of one Apple ID never reaches another Apple ID inside the package.

## Sharing

One shared zone is one `CKShare(recordZoneID:)`. New records in the zone
are shared automatically.

```ts
await presentShareSheet({ scope: 'private', name: 'list-1' }, {
  title: 'Halloween 2026', permission: 'readWrite',
}); // 'shared' | 'cancelled'

const share = await getShare({ scope: 'private', name: 'list-1' });
await setParticipantPermission(zone, participantId, 'readOnly'); // owner
await removeParticipant(zone, participantId);                    // owner
await stopSharing(zone);                                         // owner
await leaveShare({ scope: 'shared', name: 'list-1', owner });    // participant
await presentManageSheet(zone); // UICloudSharingController
```

The package never accepts an invite by itself. A tapped link emits
`inviteReceived` with a token, the title, the owner's name and the
participant count. Show your own join screen, then call
`acceptInvite(token)`, which resolves the joined zone and emits
`shareAccepted`. An invite that arrives before `configure` is emitted after
it. A share URL that reaches the app through `Linking` goes to
`acceptShareUrl(url)`, with the same result.

A participant's name is `null` when the person is not discoverable.

## Sync status

`addListener('syncStatus', …)`, or `useSyncStatus()`:

- `idle` with `lastSyncedAt`
- `syncing`
- `waiting` with a reason: `offline`, `quotaExceeded`, `noAccount`,
  `throttled` (with `retryAfter` seconds), or `other`

A waiting state never rejects a write. The write waits in the outbox.

States that are hard to trigger on purpose:

- `quotaExceeded` needs an account with full iCloud storage. Untested until
  such an account exists.
- `throttled` comes from `requestRateLimited` or `zoneBusy`, which CloudKit
  sends under load only. It is covered by the Swift unit tests of the error
  map, not on a device.
- `other` for `participantMayNeedVerification` needs a participant whose
  Apple ID CloudKit asks to verify. Covered by the unit tests only.

## React hooks

```ts
import { useAccountStatus, useShare, useSyncStatus } from
  '@ltatarev/react-native-cloudkit/react';
```

Thin wrappers over `addListener`. `useAccountStatus` reads again when the
account changes and when the app comes to the foreground.

## Errors

A refused call rejects with `CloudKitError` and a `code`: `notConfigured`,
`invalidName`, `invalidField`, `unknownRecordType`, `recordTooLarge` (over
1 MB), `zoneNotSyncing`, `notOwner`, `shareNotFound`, `inviteNotFound`,
`cloudKit`, `unknown`. The network being down is never an error.

The package never logs record contents. Logs have record names, zone names
and error codes.

## Before release: deploy the schema

CloudKit creates record types in the development environment only. Before
you ship, deploy the schema to production in CloudKit Console. After a
production deploy, a record type or a field cannot be deleted, so every
field name is permanent.

## Develop

```sh
yarn typecheck && yarn lint && yarn test && yarn test:swift
yarn example ios
```

`yarn test:swift` compiles the pure Swift in `ios/Core` for macOS and runs
its tests. The example app uses its own container,
`iCloud.com.ltatarev.cloudkit-example`, on the bundle id
`com.ltatarev.cloudkit-example`. See `example/TESTING.md` for the
two-device checklist.
