import { NitroModules } from 'react-native-nitro-modules';
import { toCloudKitError } from './errors';
import {
  encodeFields,
  fromBridgeInboxEvent,
  fromBridgeShare,
  fromBridgeZoneInfo,
  parseAccountChange,
  parseInvite,
  parseSyncStatus,
  parseZoneInfo,
  toBridgeZone,
} from './mapping';
import type { BridgeEventName, CloudKit } from './specs/CloudKit.nitro';
import type {
  AccountStatus,
  CloudKitEventName,
  CloudKitEvents,
  ConfigureOptions,
  InboxEvent,
  PrivateZoneRef,
  RecordInput,
  RecordRef,
  RecordTypeConfig,
  SharedZoneRef,
  ShareInfo,
  SharePermission,
  ShareSheetOptions,
  ZoneInfo,
  ZoneRef,
  ZoneScope,
} from './types';
import { assertValidName, assertValidRecordTypes } from './validate';

export { CloudKitError, toCloudKitError } from './errors';
export type { CloudKitErrorCode } from './errors';
export type * from './types';
export { RESERVED_PREFIX } from './validate';

/** The inbox page size when the app does not name one. */
const DEFAULT_DRAIN_LIMIT = 200;

let hybrid: CloudKit | undefined;

function native(): CloudKit {
  hybrid ??= NitroModules.createHybridObject<CloudKit>('CloudKit');

  return hybrid;
}

/*
 * The config from the last `configure`, so inbound `date` fields become
 * `Date` again. The native store holds its own copy for work without JS.
 */
let recordTypes: Record<string, RecordTypeConfig> = {};

/** Every rejection from the bridge becomes a `CloudKitError`. */
async function call<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (error) {
    throw toCloudKitError(error);
  }
}

// setup

/**
 * Opens the native store, writes the record type config, restores the
 * engine state and starts both engines. Call it once at launch, before any
 * other call. It also registers for remote notifications.
 */
export async function configure(options: ConfigureOptions): Promise<void> {
  assertValidRecordTypes(options.recordTypes);
  recordTypes = options.recordTypes;

  await call(() =>
    native().configure(options.containerId, JSON.stringify(options.recordTypes))
  );
}

/** `false` on Android and on every platform without CloudKit. */
export function isAvailable(): boolean {
  try {
    return native().isAvailable();
  } catch {
    return false;
  }
}

export function getAccountStatus(): Promise<AccountStatus> {
  return call(() => native().getAccountStatus());
}

/** The user record name. Stable per container and Apple ID. */
export async function getCurrentUserId(): Promise<string | null> {
  return (await call(() => native().getCurrentUserId())) ?? null;
}

// zones

/**
 * Creates a private zone if it does not exist. After a `purged` event it
 * also turns the zone back on for sync.
 */
export function ensureZone(zone: PrivateZoneRef): Promise<void> {
  assertValidName('zone', zone.name);

  return call(() => native().ensureZone(zone.name));
}

export function deleteZone(zone: ZoneRef): Promise<void> {
  return call(() => native().deleteZone(toBridgeZone(zone)));
}

export async function listZones(scope: ZoneScope): Promise<ZoneInfo[]> {
  const zones = await call(() => native().listZones(scope));

  return zones.map(fromBridgeZoneInfo);
}

// writing

/**
 * Queues records in the outbox and returns. The engine sends them when it
 * can, online or not. A newer save of the same record replaces the queued
 * one.
 */
export function saveRecords(changes: RecordInput[]): Promise<void> {
  for (const change of changes) {
    assertValidName('zone', change.zone.name);
    assertValidName('record', change.recordName);
  }

  return call(() =>
    native().saveRecords(
      changes.map((change) => ({
        fieldsJson: encodeFields(change.fields),
        recordName: change.recordName,
        recordType: change.recordType,
        zone: toBridgeZone(change.zone),
      }))
    )
  );
}

export function deleteRecords(refs: RecordRef[]): Promise<void> {
  for (const ref of refs) {
    assertValidName('record', ref.recordName);
  }

  return call(() =>
    native().deleteRecords(
      refs.map((ref) => ({
        recordName: ref.recordName,
        zone: toBridgeZone(ref.zone),
      }))
    )
  );
}

/** Send and fetch now: pull to refresh, and the app coming to the foreground. */
export function syncNow(): Promise<void> {
  return call(() => native().syncNow());
}

// reading

/**
 * The oldest unacked inbound changes. Apply them to the app's own database,
 * then `ackInbox` their ids. Rows stay until they are acked, so an event
 * comes back at the next drain if the app was killed first.
 */
export async function drainInbox(
  limit: number = DEFAULT_DRAIN_LIMIT
): Promise<InboxEvent[]> {
  const rows = await call(() => native().drainInbox(limit));
  const events: InboxEvent[] = [];
  const unknown: string[] = [];

  for (const row of rows) {
    const event = fromBridgeInboxEvent(row, recordTypes);

    if (event) {
      events.push(event);
    } else {
      unknown.push(row.id);
    }
  }

  /* A kind this version does not know is acked, so it never blocks the inbox. */
  if (unknown.length > 0) {
    await call(() => native().ackInbox(unknown));
  }

  return events;
}

export function ackInbox(ids: string[]): Promise<void> {
  return call(() => native().ackInbox(ids));
}

// sharing

/**
 * The system collaboration share sheet for a private zone. The zone-wide
 * `CKShare` is made when it is first needed. Defaults: invited people only.
 */
export function presentShareSheet(
  zone: PrivateZoneRef,
  options: ShareSheetOptions
): Promise<'shared' | 'cancelled'> {
  assertValidName('zone', zone.name);

  return call(() =>
    native().presentShareSheet(
      zone.name,
      options.title,
      options.thumbnailUri,
      options.permission,
      options.allowOthersToInvite ?? false
    )
  );
}

/** `UICloudSharingController` for the zone's existing share. */
export function presentManageSheet(zone: ZoneRef): Promise<void> {
  return call(() => native().presentManageSheet(toBridgeZone(zone)));
}

export async function getShare(zone: ZoneRef): Promise<ShareInfo | null> {
  const share = await call(() => native().getShare(toBridgeZone(zone)));

  return share ? fromBridgeShare(share) : null;
}

/** Owner only. */
export function setParticipantPermission(
  zone: PrivateZoneRef,
  participantId: string,
  permission: SharePermission
): Promise<void> {
  return call(() =>
    native().setParticipantPermission(zone.name, participantId, permission)
  );
}

/** Owner only. The participant gets `zoneDeleted` with `shareEnded`. */
export function removeParticipant(
  zone: PrivateZoneRef,
  participantId: string
): Promise<void> {
  return call(() => native().removeParticipant(zone.name, participantId));
}

/** Owner only. Deletes the `CKShare`; the zone and its records stay. */
export function stopSharing(zone: PrivateZoneRef): Promise<void> {
  return call(() => native().stopSharing(zone.name));
}

/** Participant only. Removes the zone from this user's shared database. */
export function leaveShare(zone: SharedZoneRef): Promise<void> {
  return call(() => native().leaveShare(toBridgeZone(zone)));
}

/**
 * The fallback when a share URL arrives through `Linking` rather than the
 * AppDelegate. It emits `inviteReceived`, the same as the system handoff.
 */
export function acceptShareUrl(url: string): Promise<void> {
  return call(() => native().acceptShareUrl(url));
}

/**
 * Accepts an invite that `inviteReceived` announced. The package never
 * accepts by itself, so the app can ask first. Emits `shareAccepted`.
 */
export async function acceptInvite(token: string): Promise<ZoneInfo> {
  return fromBridgeZoneInfo(await call(() => native().acceptInvite(token)));
}

// events

type Parser<E extends CloudKitEventName> = (
  json: string
) => Parameters<CloudKitEvents[E]>;

const PARSERS: { [E in CloudKitEventName]: Parser<E> } = {
  accountChanged: (json) => [parseAccountChange(json)],
  inboxChanged: () => [],
  inviteReceived: (json) => [parseInvite(json)],
  shareAccepted: (json) => [parseZoneInfo(json)],
  syncStatus: (json) => [parseSyncStatus(json)],
};

/**
 * Subscribes to one event and returns the unsubscribe function. Call it in
 * the effect cleanup, so the native side drops its reference to the
 * listener.
 */
export function addListener<E extends CloudKitEventName>(
  event: E,
  listener: CloudKitEvents[E]
): () => void {
  const parse = PARSERS[event] as Parser<E>;
  const handle = listener as (...args: Parameters<CloudKitEvents[E]>) => void;
  let id: number | undefined;

  try {
    id = native().addListener(event as BridgeEventName, (json) =>
      handle(...parse(json))
    );
  } catch {
    return () => {};
  }

  return () => {
    if (id !== undefined) {
      native().removeListener(id);
      id = undefined;
    }
  };
}
