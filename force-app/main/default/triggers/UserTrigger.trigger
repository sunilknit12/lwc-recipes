trigger UserTrigger on User (after update) {
	if (Trigger.isAfter && Trigger.isUpdate) {
		UserTriggerHandler.onAfterUpdate(Trigger.new, Trigger.oldMap);
	}
}

