import type { HybridObject } from 'react-native-nitro-modules';

/*
 * The bridge. Plain types only: epoch milliseconds, flat structs and string
 * unions. `src/index.ts` maps them to the public types (`Date`, discriminated
 * unions). Record fields and inbox payloads cross as one JSON string each, so
 * Swift decodes every field with the type from the record type config, and
 * `int` and `double` stay distinct.
 */

export type BridgeZoneScope = 'private' | 'shared';

export type BridgeAccountStatus =
  | 'available'
  | 'noAccount'
  | 'restricted'
  | 'temporarilyUnavailable'
  | 'couldNotDetermine';

export type BridgeSharePermission = 'readWrite' | 'readOnly';

export type BridgeShareSheetResult = 'shared' | 'cancelled';

/**
 * The events a listener can subscribe to. Each delivers one JSON payload,
 * which the TS layer parses into the public event type.
 */
export type BridgeEventName =
  | 'inboxChanged'
  | 'syncStatus'
  | 'accountChanged'
  | 'inviteReceived'
  | 'shareAccepted';

/** `owner` is set only for the shared scope: the zone owner's user id. */
export interface BridgeZoneRef {
  scope: BridgeZoneScope;
  name: string;
  owner?: string;
}

export interface BridgeZoneInfo {
  zone: BridgeZoneRef;
  isShared: boolean;
}

export interface BridgeRecordRef {
  zone: BridgeZoneRef;
  recordName: string;
}

export interface BridgeRecordInput {
  zone: BridgeZoneRef;
  recordName: string;
  recordType: string;
  /** `{ [field]: value }`. A date is epoch milliseconds. */
  fieldsJson: string;
}

export interface BridgeInboxEvent {
  id: string;
  /** `upsert`, `delete`, `zoneDeleted` or `conflictResolved`. */
  kind: string;
  /** The rest of the event, as the store holds it. */
  payloadJson: string;
}

export interface BridgeParticipant {
  id: string;
  userId?: string;
  name?: string;
  /** `owner`, `privateUser` or `publicUser`. */
  role: string;
  /** `readWrite`, `readOnly` or `none`. */
  permission: string;
  /** `pending`, `accepted`, `removed` or `unknown`. */
  status: string;
  isCurrentUser: boolean;
}

export interface BridgeShareInfo {
  zone: BridgeZoneRef;
  isOwner: boolean;
  url?: string;
  /** `none`, `readOnly` or `readWrite`. */
  publicPermission: string;
  participants: BridgeParticipant[];
}

export interface CloudKit extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  // setup
  isAvailable(): boolean;
  /** `recordTypesJson` is `{ [recordType]: RecordTypeConfig }`. */
  configure(containerId: string, recordTypesJson: string): Promise<void>;
  getAccountStatus(): Promise<BridgeAccountStatus>;
  getCurrentUserId(): Promise<string | undefined>;

  // zones
  ensureZone(name: string): Promise<void>;
  deleteZone(zone: BridgeZoneRef): Promise<void>;
  listZones(scope: BridgeZoneScope): Promise<BridgeZoneInfo[]>;

  // writing
  saveRecords(records: BridgeRecordInput[]): Promise<void>;
  deleteRecords(refs: BridgeRecordRef[]): Promise<void>;
  syncNow(): Promise<void>;

  // reading
  drainInbox(limit: number): Promise<BridgeInboxEvent[]>;
  ackInbox(ids: string[]): Promise<void>;

  // sharing
  presentShareSheet(
    zoneName: string,
    title: string,
    thumbnailUri: string | undefined,
    permission: BridgeSharePermission,
    allowOthersToInvite: boolean
  ): Promise<BridgeShareSheetResult>;
  presentManageSheet(zone: BridgeZoneRef): Promise<void>;
  getShare(zone: BridgeZoneRef): Promise<BridgeShareInfo | undefined>;
  setParticipantPermission(
    zoneName: string,
    participantId: string,
    permission: BridgeSharePermission
  ): Promise<void>;
  removeParticipant(zoneName: string, participantId: string): Promise<void>;
  stopSharing(zoneName: string): Promise<void>;
  leaveShare(zone: BridgeZoneRef): Promise<void>;
  acceptShareUrl(url: string): Promise<void>;
  acceptInvite(token: string): Promise<BridgeZoneInfo>;

  // events
  /** Returns a listener id for `removeListener`. */
  addListener(
    event: BridgeEventName,
    listener: (payloadJson: string) => void
  ): number;
  removeListener(id: number): void;
}
