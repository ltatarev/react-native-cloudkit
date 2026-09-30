package com.margelo.nitro.ltatarev.reactnativecloudkit

import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise

/**
 * CloudKit does not exist on Android. Every call resolves with an empty or
 * "not available" answer and never rejects, so an app is whole without it.
 */
@DoNotStrip
class HybridCloudKit : HybridCloudKitSpec() {
  private val none = BridgeZoneInfo(BridgeZoneRef(BridgeZoneScope.PRIVATE, "", null), false)

  override fun isAvailable(): Boolean = false

  override fun configure(containerId: String, recordTypesJson: String): Promise<Unit> = Promise.resolved(Unit)

  override fun getAccountStatus(): Promise<BridgeAccountStatus> = Promise.resolved(BridgeAccountStatus.NOACCOUNT)

  override fun getCurrentUserId(): Promise<String?> = Promise.resolved(null)

  override fun ensureZone(name: String): Promise<Unit> = Promise.resolved(Unit)

  override fun deleteZone(zone: BridgeZoneRef): Promise<Unit> = Promise.resolved(Unit)

  override fun listZones(scope: BridgeZoneScope): Promise<Array<BridgeZoneInfo>> = Promise.resolved(arrayOf())

  override fun saveRecords(records: Array<BridgeRecordInput>): Promise<Unit> = Promise.resolved(Unit)

  override fun deleteRecords(refs: Array<BridgeRecordRef>): Promise<Unit> = Promise.resolved(Unit)

  override fun syncNow(): Promise<Unit> = Promise.resolved(Unit)

  override fun drainInbox(limit: Double): Promise<Array<BridgeInboxEvent>> = Promise.resolved(arrayOf())

  override fun ackInbox(ids: Array<String>): Promise<Unit> = Promise.resolved(Unit)

  override fun presentShareSheet(
    zoneName: String,
    title: String,
    thumbnailUri: String?,
    permission: BridgeSharePermission,
    allowOthersToInvite: Boolean
  ): Promise<BridgeShareSheetResult> = Promise.resolved(BridgeShareSheetResult.CANCELLED)

  override fun presentManageSheet(zone: BridgeZoneRef): Promise<Unit> = Promise.resolved(Unit)

  override fun getShare(zone: BridgeZoneRef): Promise<BridgeShareInfo?> = Promise.resolved(null)

  override fun setParticipantPermission(
    zoneName: String,
    participantId: String,
    permission: BridgeSharePermission
  ): Promise<Unit> = Promise.resolved(Unit)

  override fun removeParticipant(zoneName: String, participantId: String): Promise<Unit> = Promise.resolved(Unit)

  override fun stopSharing(zoneName: String): Promise<Unit> = Promise.resolved(Unit)

  override fun leaveShare(zone: BridgeZoneRef): Promise<Unit> = Promise.resolved(Unit)

  override fun acceptShareUrl(url: String): Promise<Unit> = Promise.resolved(Unit)

  override fun acceptInvite(token: String): Promise<BridgeZoneInfo> = Promise.resolved(none)

  override fun addListener(event: BridgeEventName, listener: (payloadJson: String) -> Unit): Double = 0.0

  override fun removeListener(id: Double) {}
}
