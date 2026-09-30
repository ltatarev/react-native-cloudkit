/**
 * The public types. `Date` and the discriminated unions exist only here: the
 * bridge (`specs/CloudKit.nitro.ts`) uses epoch milliseconds, flat structs
 * and JSON strings, and `mapping.ts` turns one into the other.
 */

export type FieldValue = string | number | boolean | Date | string[] | null;

export type FieldType =
  'string' | 'int' | 'double' | 'bool' | 'date' | 'stringList';

export type ConflictPolicy = 'serverWins' | 'clientWins' | 'fieldMerge';

export interface RecordTypeConfig {
  fields: Record<string, FieldType>;
  /** The default is `fieldMerge`. */
  conflict?: ConflictPolicy;
}

export interface ConfigureOptions {
  /** For example `iCloud.com.ltatarev.cloudkit-example`. */
  containerId: string;
  recordTypes: Record<string, RecordTypeConfig>;
}

export type AccountStatus =
  | 'available'
  | 'noAccount'
  | 'restricted'
  | 'temporarilyUnavailable'
  | 'couldNotDetermine';

/*
 * A zone id in CloudKit is a name plus an owner. In the shared database two
 * owners can share zones with the same name, so a shared ref carries the
 * owner.
 */
export type PrivateZoneRef = { scope: 'private'; name: string };
/** `owner` is the zone owner's user id. */
export type SharedZoneRef = { scope: 'shared'; name: string; owner: string };
export type ZoneRef = PrivateZoneRef | SharedZoneRef;
export type ZoneScope = ZoneRef['scope'];

export interface ZoneInfo {
  zone: ZoneRef;
  /** A private zone that has a `CKShare`, or any shared zone. */
  isShared: boolean;
}

export interface RecordRef {
  zone: ZoneRef;
  recordName: string;
}

export interface RecordInput extends RecordRef {
  recordType: string;
  fields: Record<string, FieldValue>;
}

export interface RecordMeta {
  /** `creatorUserRecordID.recordName`, for "who added what". */
  createdBy: string | null;
  modifiedBy: string | null;
  createdAt: Date;
  modifiedAt: Date;
}

export type ZoneDeletedReason =
  'deleted' | 'purged' | 'encryptedDataReset' | 'shareEnded';

export type InboxEvent =
  | { id: string; kind: 'upsert'; record: RecordInput & RecordMeta }
  | { id: string; kind: 'delete'; ref: RecordRef; recordType: string }
  | {
      id: string;
      kind: 'zoneDeleted';
      zone: ZoneRef;
      reason: ZoneDeletedReason;
    }
  | {
      id: string;
      kind: 'conflictResolved';
      ref: RecordRef;
      winner: 'server' | 'client' | 'merged';
    }
  | {
      id: string;
      kind: 'writeFailed';
      ref: RecordRef;
      reason: 'permission' | 'other';
    };

export type AccountChange =
  | { kind: 'signIn'; userId: string }
  | { kind: 'signOut' }
  | { kind: 'switchAccounts'; userId: string };

export type SharePermission = 'readWrite' | 'readOnly';

export interface Participant {
  id: string;
  userId: string | null;
  /** From `nameComponents`, when the person is discoverable. */
  name: string | null;
  role: 'owner' | 'privateUser' | 'publicUser';
  permission: 'readWrite' | 'readOnly' | 'none';
  status: 'pending' | 'accepted' | 'removed' | 'unknown';
  isCurrentUser: boolean;
}

export interface ShareInfo {
  zone: ZoneRef;
  isOwner: boolean;
  url: string | null;
  publicPermission: 'none' | 'readOnly' | 'readWrite';
  participants: Participant[];
}

export interface ShareSheetOptions {
  title: string;
  thumbnailUri?: string;
  permission: SharePermission;
  allowOthersToInvite?: boolean;
}

export type WaitingReason =
  'offline' | 'quotaExceeded' | 'noAccount' | 'throttled' | 'other';

export type SyncStatus =
  | { state: 'idle'; lastSyncedAt: Date | null }
  | { state: 'syncing' }
  | { state: 'waiting'; reason: WaitingReason; retryAfter?: number };

export interface Invite {
  token: string;
  title: string | null;
  ownerName: string | null;
  participantCount: number;
}

export interface CloudKitEvents {
  inboxChanged: () => void;
  syncStatus: (status: SyncStatus) => void;
  accountChanged: (change: AccountChange) => void;
  inviteReceived: (invite: Invite) => void;
  shareAccepted: (zone: ZoneInfo) => void;
}

export type CloudKitEventName = keyof CloudKitEvents;
