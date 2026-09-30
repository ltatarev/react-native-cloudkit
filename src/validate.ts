import { CloudKitError } from './errors';
import type { RecordTypeConfig } from './types';

/** Every field the package writes starts with this. See the README. */
export const RESERVED_PREFIX = 'RNCK_';

const MAX_NAME_LENGTH = 255;

const ASCII = /^[\x20-\x7e]+$/;

const FIELD_NAME = /^[A-Za-z][A-Za-z0-9_]*$/;

/**
 * A zone or record name CloudKit accepts: ASCII, 255 characters or fewer, no
 * leading `_`. A user id starts with `_`, so an app puts it after a prefix
 * (`take-<userId>-…`).
 */
export function assertValidName(kind: 'zone' | 'record', name: string): void {
  if (
    name.length === 0 ||
    name.length > MAX_NAME_LENGTH ||
    !ASCII.test(name) ||
    name.startsWith('_')
  ) {
    throw new CloudKitError(
      'invalidName',
      `Invalid ${kind} name "${name}": use 1–255 ASCII characters, not starting with "_".`
    );
  }
}

/**
 * The record type config `configure` accepts. A field starts with a letter
 * and never with the reserved prefix: after a production deploy, CloudKit
 * cannot delete a field, so these names are permanent.
 */
export function assertValidRecordTypes(
  recordTypes: Record<string, RecordTypeConfig>
): void {
  for (const [recordType, config] of Object.entries(recordTypes)) {
    if (!FIELD_NAME.test(recordType)) {
      throw new CloudKitError(
        'invalidField',
        `Invalid record type "${recordType}": start with a letter, then letters, digits or "_".`
      );
    }

    for (const field of Object.keys(config.fields)) {
      if (!FIELD_NAME.test(field) || field.startsWith(RESERVED_PREFIX)) {
        throw new CloudKitError(
          'invalidField',
          `Invalid field "${recordType}.${field}": start with a letter, and do not use the "${RESERVED_PREFIX}" prefix.`
        );
      }
    }
  }
}
