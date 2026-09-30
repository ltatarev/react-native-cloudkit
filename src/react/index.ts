import { useCallback, useEffect, useState } from 'react';
import { AppState } from 'react-native';
import { addListener, getAccountStatus, getShare, isAvailable } from '../index';
import type { AccountStatus, ShareInfo, SyncStatus, ZoneRef } from '../types';

/*
 * Thin wrappers only. Each subscribes with `addListener` in an effect and
 * unsubscribes in the cleanup. There is no state library: the app owns its
 * own state.
 */

const IDLE: SyncStatus = { lastSyncedAt: null, state: 'idle' };

/** The live sync state. A new listener hears the current state at once. */
export function useSyncStatus(): SyncStatus {
  const [status, setStatus] = useState<SyncStatus>(IDLE);

  useEffect(() => addListener('syncStatus', setStatus), []);

  return status;
}

/**
 * The iCloud account state, read again when the account changes and when
 * the app comes back to the foreground, so a sign-out in Settings shows with
 * no relaunch. `undefined` until the first answer.
 */
export function useAccountStatus(): AccountStatus | undefined {
  const [status, setStatus] = useState<AccountStatus | undefined>(
    isAvailable() ? undefined : 'noAccount'
  );

  useEffect(() => {
    if (!isAvailable()) {
      return undefined;
    }

    let live = true;
    const read = () => {
      getAccountStatus()
        .then((next) => {
          if (live) setStatus(next);
        })
        .catch(() => {
          if (live) setStatus('couldNotDetermine');
        });
    };

    read();
    const unsubscribe = addListener('accountChanged', read);
    const appState = AppState.addEventListener('change', (state) => {
      if (state === 'active') read();
    });

    return () => {
      live = false;
      unsubscribe();
      appState.remove();
    };
  }, []);

  return status;
}

export type ShareState = {
  share: ShareInfo | null;
  isLoading: boolean;
  refresh: () => void;
};

/**
 * The zone's share and its participants, read again after an invite is
 * accepted and on `refresh`. `null` when the zone is not shared.
 */
export function useShare(zone: ZoneRef): ShareState {
  const [share, setShare] = useState<ShareInfo | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [version, setVersion] = useState(0);
  const refresh = useCallback(() => setVersion((value) => value + 1), []);

  const scope = zone.scope;
  const name = zone.name;
  const owner = zone.scope === 'shared' ? zone.owner : undefined;

  useEffect(() => {
    let live = true;
    const ref: ZoneRef =
      scope === 'shared'
        ? { name, owner: owner ?? '', scope: 'shared' }
        : { name, scope: 'private' };

    getShare(ref)
      .then((next) => {
        if (live) setShare(next);
      })
      .catch(() => {
        if (live) setShare(null);
      })
      .finally(() => {
        if (live) setIsLoading(false);
      });

    return () => {
      live = false;
    };
  }, [name, owner, scope, version]);

  useEffect(() => addListener('shareAccepted', refresh), [refresh]);

  return { isLoading, refresh, share };
}
