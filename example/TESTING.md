# Device checklist

Two iPhones. Private sync needs one Apple ID on both. Sharing needs two
Apple IDs. The container `iCloud.com.ltatarev.cloudkit-example` must exist,
and the bundle id `com.ltatarev.cloudkit-example` must have iCloud
(CloudKit) and Push Notifications.

## Account

- [x] Signed in: the screen shows `account: available` and a user id.
- [ ] Settings → sign out of iCloud → back to the app: `noAccount`, no
      relaunch. Sign in again: `available`.
- [x] The user id is the same on both devices with the same Apple ID.
- [ ] Android build: `isAvailable: false`.

## Private sync

- [x] Both in the foreground: add a note on A. It shows on B within 10 s.
- [x] Kill the app on B, add a note on A, open B: the note is there.
- [x] Airplane mode on A, add and edit three notes, airplane mode off: all
      three reach B.
- [x] Offline on both: edit the title on A and the body on B, reconnect:
      both devices show both edits.
- [ ] Kill A while "Syncing…" shows: after relaunch nothing is lost, and
      nothing shows twice on B.
- [x] Delete a note on A: it goes from B.
- [ ] Sign out on A, add a note, sign in with the same Apple ID: the note
      reaches B.
- [ ] Settings → Apple ID → iCloud → Manage Storage → the example app →
      Delete Data: the app gets `purged`, and the next save shows
      `zoneNotSyncing`.
- [ ] Push check: B fetches with no "Sync now". If it does not, record it
      here and in the README.

## Sharing

- [ ] A (Apple ID 1) taps Share and sends the invite to B (Apple ID 2)
      through Messages. B taps the link: the invite card shows. Join: B
      sees every note.
- [ ] Not now: nothing is joined. Tapping the link again shows the card.
- [ ] B adds a note: A sees it with B's user id as `createdBy`.
- [ ] A edits B's note: B sees it with A as `modifiedBy`.
- [ ] Manage → set B to read-only. B edits: B gets a `writeFailed` event,
      and A never gets the edit.
- [ ] Stop sharing on A: B gets `zoneDeleted` with `shareEnded`.
- [ ] Share again, then Leave on B: the zone goes from B and stays on A.
- [ ] A's participant list shows B's name when B is discoverable.

## Status

- [x] Airplane mode: `Waiting to sync: offline`. Off: `Syncing…`, then
      `Synced`.
- [ ] Full iCloud storage: `Waiting to sync: quotaExceeded` (or record why
      it was not tested).
- [ ] Switch Apple IDs on one device: no note from the first account shows.
- [x] A new bare app (`npx @react-native-community/cli init`) shows the
      account state after the README's setup, in 15 minutes or less.
