/**
 * Why a call was refused. Native code rejects with a message that starts
 * with `[RNCK:<code>]`, and `toCloudKitError` reads the code back.
 *
 * Sync trouble is never one of these. A write waits in the outbox, and the
 * reason is a `syncStatus` event.
 */
export type CloudKitErrorCode =
  /** `configure` has not run. */
  | 'notConfigured'
  /** A zone or record name is not ASCII, too long, or starts with `_`. */
  | 'invalidName'
  /** A record type or field name breaks the rules, or a value has the wrong type. */
  | 'invalidField'
  /** `saveRecords` named a record type that `configure` did not declare. */
  | 'unknownRecordType'
  /** The record is over CloudKit's 1 MB limit. */
  | 'recordTooLarge'
  /** The zone was purged. Call `ensureZone` to turn it on again. */
  | 'zoneNotSyncing'
  /** An owner action on a zone the current user does not own. */
  | 'notOwner'
  /** No share exists for the zone. */
  | 'shareNotFound'
  /** The invite token is unknown or already used. */
  | 'inviteNotFound'
  /** A CloudKit call failed. The message has the CloudKit error code. */
  | 'cloudKit'
  /** Anything else. */
  | 'unknown';

const KNOWN_CODES: readonly CloudKitErrorCode[] = [
  'notConfigured',
  'invalidName',
  'invalidField',
  'unknownRecordType',
  'recordTooLarge',
  'zoneNotSyncing',
  'notOwner',
  'shareNotFound',
  'inviteNotFound',
  'cloudKit',
  'unknown',
];

export class CloudKitError extends Error {
  readonly code: CloudKitErrorCode;

  constructor(code: CloudKitErrorCode, message: string) {
    super(message);
    this.name = 'CloudKitError';
    this.code = code;
  }
}

const PREFIX = /^\[RNCK:([A-Za-z]+)\]\s*/;

function isKnownCode(value: string): value is CloudKitErrorCode {
  return (KNOWN_CODES as readonly string[]).includes(value);
}

/** Any rejection from the bridge as a `CloudKitError`. */
export function toCloudKitError(error: unknown): CloudKitError {
  if (error instanceof CloudKitError) {
    return error;
  }

  const message =
    error instanceof Error ? error.message : String(error ?? 'Unknown error');
  const match = PREFIX.exec(message);
  const code = match?.[1];

  if (code !== undefined && isKnownCode(code)) {
    return new CloudKitError(code, message.replace(PREFIX, ''));
  }

  return new CloudKitError('unknown', message);
}
