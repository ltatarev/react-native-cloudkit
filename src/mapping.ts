import type {
  BridgeInboxEvent,
  BridgeParticipant,
  BridgeShareInfo,
  BridgeZoneInfo,
  BridgeZoneRef,
} from './specs/CloudKit.nitro';
import type {
  AccountChange,
  FieldValue,
  InboxEvent,
  Invite,
  Participant,
  RecordRef,
  RecordTypeConfig,
  ShareInfo,
  SyncStatus,
  ZoneDeletedReason,
  ZoneInfo,
  ZoneRef,
} from './types';

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseObject(json: string): Json {
  const value: unknown = JSON.parse(json);

  if (!isObject(value)) {
    throw new Error('Expected a JSON object from the bridge.');
  }

  return value;
}

function readString(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function readNumber(value: unknown): number {
  return typeof value === 'number' ? value : 0;
}

export function toBridgeZone(zone: ZoneRef): BridgeZoneRef {
  return zone.scope === 'shared'
    ? { name: zone.name, owner: zone.owner, scope: 'shared' }
    : { name: zone.name, scope: 'private' };
}

/**
 * A shared zone always carries its owner. A shared ref without one can only
 * come from a bug in the native side, and it is reported as an owner of `''`
 * so the app still sees a shared zone.
 */
export function fromBridgeZone(zone: BridgeZoneRef): ZoneRef {
  return zone.scope === 'shared'
    ? { name: zone.name, owner: zone.owner ?? '', scope: 'shared' }
    : { name: zone.name, scope: 'private' };
}

function readZone(value: unknown): ZoneRef {
  if (!isObject(value)) {
    throw new Error('Expected a zone in the bridge payload.');
  }

  return fromBridgeZone({
    name: readString(value.name) ?? '',
    owner: readString(value.owner) ?? undefined,
    scope: value.scope === 'shared' ? 'shared' : 'private',
  });
}

export function fromBridgeZoneInfo(info: BridgeZoneInfo): ZoneInfo {
  return { isShared: info.isShared, zone: fromBridgeZone(info.zone) };
}

/**
 * Fields as JSON for the bridge. A date is epoch milliseconds; Swift reads
 * it back as a date because the record type config says so.
 */
export function encodeFields(fields: Record<string, FieldValue>): string {
  const encoded: Record<string, unknown> = {};

  for (const [name, value] of Object.entries(fields)) {
    encoded[name] = value instanceof Date ? value.getTime() : value;
  }

  return JSON.stringify(encoded);
}

/** Fields from the bridge, with `date` fields turned back into `Date`. */
export function decodeFields(
  fields: unknown,
  config: RecordTypeConfig | undefined
): Record<string, FieldValue> {
  if (!isObject(fields)) {
    return {};
  }

  const decoded: Record<string, FieldValue> = {};

  for (const [name, value] of Object.entries(fields)) {
    if (config?.fields[name] === 'date' && typeof value === 'number') {
      decoded[name] = new Date(value);
    } else {
      decoded[name] = value as FieldValue;
    }
  }

  return decoded;
}

const ZONE_DELETED_REASONS: readonly ZoneDeletedReason[] = [
  'deleted',
  'purged',
  'encryptedDataReset',
  'shareEnded',
];

function readRef(payload: Json): RecordRef {
  return {
    recordName: readString(payload.recordName) ?? '',
    zone: readZone(payload.zone),
  };
}

/**
 * One inbox row as the public event. An event of a kind this version does
 * not know is dropped, and the caller acks it, so a newer native side never
 * blocks the inbox.
 */
export function fromBridgeInboxEvent(
  event: BridgeInboxEvent,
  recordTypes: Record<string, RecordTypeConfig>
): InboxEvent | undefined {
  const payload = parseObject(event.payloadJson);
  const { id } = event;

  switch (event.kind) {
    case 'upsert': {
      const recordType = readString(payload.recordType) ?? '';

      return {
        id,
        kind: 'upsert',
        record: {
          ...readRef(payload),
          createdAt: new Date(readNumber(payload.createdAt)),
          createdBy: readString(payload.createdBy),
          fields: decodeFields(payload.fields, recordTypes[recordType]),
          modifiedAt: new Date(readNumber(payload.modifiedAt)),
          modifiedBy: readString(payload.modifiedBy),
          recordType,
        },
      };
    }
    case 'delete':
      return {
        id,
        kind: 'delete',
        recordType: readString(payload.recordType) ?? '',
        ref: readRef(payload),
      };
    case 'zoneDeleted': {
      const reason = readString(payload.reason);

      return {
        id,
        kind: 'zoneDeleted',
        reason:
          ZONE_DELETED_REASONS.find((known) => known === reason) ?? 'deleted',
        zone: readZone(payload.zone),
      };
    }
    case 'conflictResolved': {
      const winner = readString(payload.winner);

      return {
        id,
        kind: 'conflictResolved',
        ref: readRef(payload),
        winner: winner === 'server' || winner === 'client' ? winner : 'merged',
      };
    }
    case 'writeFailed':
      return {
        id,
        kind: 'writeFailed',
        reason: payload.reason === 'permission' ? 'permission' : 'other',
        ref: readRef(payload),
      };
    default:
      return undefined;
  }
}

export function parseSyncStatus(json: string): SyncStatus {
  const payload = parseObject(json);

  if (payload.state === 'syncing') {
    return { state: 'syncing' };
  }

  if (payload.state === 'waiting') {
    const reason = readString(payload.reason);
    const retryAfter =
      typeof payload.retryAfter === 'number' ? payload.retryAfter : undefined;

    return {
      reason:
        reason === 'offline' ||
        reason === 'quotaExceeded' ||
        reason === 'noAccount' ||
        reason === 'throttled'
          ? reason
          : 'other',
      state: 'waiting',
      ...(retryAfter === undefined ? {} : { retryAfter }),
    };
  }

  return {
    lastSyncedAt:
      typeof payload.lastSyncedAt === 'number'
        ? new Date(payload.lastSyncedAt)
        : null,
    state: 'idle',
  };
}

export function parseAccountChange(json: string): AccountChange {
  const payload = parseObject(json);
  const userId = readString(payload.userId) ?? '';

  switch (payload.kind) {
    case 'signIn':
      return { kind: 'signIn', userId };
    case 'switchAccounts':
      return { kind: 'switchAccounts', userId };
    default:
      return { kind: 'signOut' };
  }
}

export function parseInvite(json: string): Invite {
  const payload = parseObject(json);

  return {
    ownerName: readString(payload.ownerName),
    participantCount: readNumber(payload.participantCount),
    title: readString(payload.title),
    token: readString(payload.token) ?? '',
  };
}

export function parseZoneInfo(json: string): ZoneInfo {
  const payload = parseObject(json);

  return { isShared: payload.isShared === true, zone: readZone(payload.zone) };
}

function oneOf<T extends string>(
  value: string,
  known: readonly T[],
  fallback: T
): T {
  return known.find((item) => item === value) ?? fallback;
}

function fromBridgeParticipant(participant: BridgeParticipant): Participant {
  return {
    id: participant.id,
    isCurrentUser: participant.isCurrentUser,
    name: participant.name ?? null,
    permission: oneOf(
      participant.permission,
      ['readWrite', 'readOnly', 'none'],
      'none'
    ),
    role: oneOf(
      participant.role,
      ['owner', 'privateUser', 'publicUser'],
      'privateUser'
    ),
    status: oneOf(
      participant.status,
      ['pending', 'accepted', 'removed', 'unknown'],
      'unknown'
    ),
    userId: participant.userId ?? null,
  };
}

export function fromBridgeShare(share: BridgeShareInfo): ShareInfo {
  return {
    isOwner: share.isOwner,
    participants: share.participants.map(fromBridgeParticipant),
    publicPermission: oneOf(
      share.publicPermission,
      ['none', 'readOnly', 'readWrite'],
      'none'
    ),
    url: share.url ?? null,
    zone: fromBridgeZone(share.zone),
  };
}
