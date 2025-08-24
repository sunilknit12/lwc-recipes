public without sharing class UserTriggerHandler {

	public static void onAfterUpdate(List<User> newList, Map<Id, User> oldMap) {
		Set<Id> deactivatedUserIds = new Set<Id>();
		for (User u : newList) {
			User oldRecord = oldMap.get(u.Id);
			if (oldRecord != null && oldRecord.IsActive == true && u.IsActive == false) {
				deactivatedUserIds.add(u.Id);
			}
		}
		if (!deactivatedUserIds.isEmpty()) {
			Database.executeBatch(new DeactivatedOwnerAccountReassignmentBatch(null, deactivatedUserIds), 200);
		}
	}
}

