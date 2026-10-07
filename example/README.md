# Example app

A notes app that shows every part of `@ltatarev/react-native-cloudkit`:
the account state, private sync through the outbox and the inbox, field
merge, sharing with an invite card, and the sync status. Notes are kept in
AsyncStorage (`src/notesStore.ts`), so the app owns its own data as a real
app does.

## Requirements

- A physical iPhone with iOS 17 or later, signed in to iCloud. The
  simulator can sign in to iCloud, but it gets no pushes.
- A paid Apple Developer account.
- Two iPhones for the checks in [`TESTING.md`](./TESTING.md).

## Set up signing

The project uses the container `iCloud.com.ltatarev.cloudkit-example` on
the bundle id `com.ltatarev.cloudkit-example`. To run it with your own
team:

1. Open `ios/ReactNativeCloudkitExample.xcworkspace` in Xcode.
2. Select your team on the app target.
3. Change the bundle id, and the container in
   `ReactNativeCloudkitExample.entitlements`, to ids your team owns.
4. Set `CONTAINER_ID` in `src/App.tsx` to the same container.

## Run

From the repository root:

```sh
yarn
yarn nitrogen
cd example && bundle install && bundle exec pod install --project-directory=ios && cd ..
yarn example ios --device
```

The app uses the local package source, so a JS change shows without a
rebuild. A native change needs a rebuild.

## Check on devices

Follow [`TESTING.md`](./TESTING.md). Mark each check that passes, and record
a check that you cannot do and the reason.
