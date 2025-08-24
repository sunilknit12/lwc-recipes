@IsTest
private class DeactivatedOwnerAccountReassignmentBatch_TEST {

	private static Profile getAnyStandardProfile() {
		return [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
	}

	private static User createActiveUser(String uniqueAlias) {
		Profile standardProfile = getAnyStandardProfile();
		User newUserRecord = new User(
			Alias = uniqueAlias.left(8),
			Email = uniqueAlias + '@example.com',
			EmailEncodingKey = 'UTF-8',
			LastName = uniqueAlias,
			LanguageLocaleKey = 'en_US',
			LocaleSidKey = 'en_US',
			TimeZoneSidKey = 'America/Los_Angeles',
			ProfileId = standardProfile.Id,
			Username = uniqueAlias + '+' + System.currentTimeMillis() + '@example.com'
		);
		insert newUserRecord;
		return newUserRecord;
	}

	@IsTest
	static void testReassignmentFromDeactivatedOwner() {
		User oldOwnerUser = createActiveUser('oldowner1');
		User defaultOwnerUser = createActiveUser('newowner1');

		Account accOne = new Account(Name = 'Test A1', OwnerId = oldOwnerUser.Id);
		Account accTwo = new Account(Name = 'Test A2', OwnerId = oldOwnerUser.Id);
		insert new List<Account>{ accOne, accTwo };

		// Deactivate the old owner user
		System.runAs(defaultOwnerUser) {
			oldOwnerUser.IsActive = false;
			update oldOwnerUser;
		}

		Test.startTest();
		Database.executeBatch(new DeactivatedOwnerAccountReassignmentBatch(defaultOwnerUser.Id), 50);
		Test.stopTest();

		List<Account> updatedAccounts = [SELECT Id, OwnerId FROM Account WHERE Id IN :new List<Id>{ accOne.Id, accTwo.Id }];
		for (Account updatedAccount : updatedAccounts) {
			System.assertEquals(defaultOwnerUser.Id, updatedAccount.OwnerId, 'Owner should be reassigned to default owner');
		}
	}

	@IsTest
	static void testUserTriggerLaunchesBatch() {
		User oldOwnerUser = createActiveUser('oldowner2');
		User defaultOwnerUser = createActiveUser('newowner2');

		insert new Account(Name = 'FromTrigger', OwnerId = oldOwnerUser.Id);

		// Deactivate via update to fire trigger
		System.runAs(defaultOwnerUser) {
			oldOwnerUser.IsActive = false;
			update oldOwnerUser;
		}

		Test.startTest();
		// Trigger should enqueue batch; stopTest will run it
		Test.stopTest();

		Integer reassigned = [SELECT COUNT() FROM Account WHERE OwnerId = :defaultOwnerUser.Id];
		System.assert(reassigned > 0, 'Accounts should be reassigned by trigger-launched batch');
	}
}

