global without sharing class DeactivatedOwnerAccountReassignmentBatch implements Database.Batchable<SObject>, Database.Stateful {

	private Id defaultOwnerId;
	private Set<Id> ownerIdsToProcess;
	private static final Integer MAX_RETRIES = 3;

	public DeactivatedOwnerAccountReassignmentBatch(Id defaultOwnerIdParam) {
		this.defaultOwnerId = defaultOwnerIdParam;
		this.ownerIdsToProcess = null;
	}

	public DeactivatedOwnerAccountReassignmentBatch(Id defaultOwnerIdParam, Set<Id> ownerIdsToProcessParam) {
		this.defaultOwnerId = defaultOwnerIdParam;
		this.ownerIdsToProcess = ownerIdsToProcessParam;
	}

	global Database.QueryLocator start(Database.BatchableContext bc) {
		if (this.defaultOwnerId == null) {
			this.defaultOwnerId = resolveDefaultOwnerId();
		}

		if (this.defaultOwnerId == null) {
			// No default owner could be resolved; return empty locator to safely exit without processing
			return Database.getQueryLocator('SELECT Id FROM Account WHERE Id = null');
		}

		String query = 'SELECT Id, OwnerId FROM Account WHERE OwnerId IN (SELECT Id FROM User WHERE IsActive = false)';
		if (ownerIdsToProcess != null && !ownerIdsToProcess.isEmpty()) {
			query += ' AND OwnerId IN :ownerIdsToProcess';
		}
		query += ' AND OwnerId != :defaultOwnerId ORDER BY Id';
		return Database.getQueryLocator(query);
	}

	global void execute(Database.BatchableContext bc, List<SObject> scope) {
		if (scope.isEmpty()) {
			return;
		}

		List<Account> accountsToUpdate = new List<Account>();
		for (SObject s : scope) {
			Account accountFromScope = (Account) s;
			if (accountFromScope.OwnerId != this.defaultOwnerId) {
				accountsToUpdate.add(new Account(Id = accountFromScope.Id, OwnerId = this.defaultOwnerId));
			}
		}

		if (accountsToUpdate.isEmpty()) {
			return;
		}

		attemptUpdateWithRetry(accountsToUpdate);
	}

	global void finish(Database.BatchableContext bc) {
		// No-op; extend to add summary notifications if required
	}

	private static Id resolveDefaultOwnerId() {
		// Attempt to resolve from Custom Metadata (Owner_Default__mdt.Account_Default_Owner__c)
		try {
			List<SObject> cmdSettings = Database.query('SELECT Account_Default_Owner__c FROM Owner_Default__mdt LIMIT 1');
			if (!cmdSettings.isEmpty()) {
				Object valueFromCmd = cmdSettings[0].get('Account_Default_Owner__c');
				if (valueFromCmd != null) {
					return (Id) valueFromCmd;
				}
			}
		} catch (Exception ignoreCmd) {
			// Safe to ignore; org may not have this metadata
		}

		// Attempt to resolve from Custom Setting (Automation_Settings__c.Default_Account_Owner__c)
		try {
			List<SObject> csSettings = Database.query('SELECT Default_Account_Owner__c FROM Automation_Settings__c LIMIT 1');
			if (!csSettings.isEmpty()) {
				Object valueFromCs = csSettings[0].get('Default_Account_Owner__c');
				if (valueFromCs != null) {
					return (Id) valueFromCs;
				}
			}
		} catch (Exception ignoreCs) {
			// Safe to ignore; org may not have this setting
		}

		return null;
	}

	private void attemptUpdateWithRetry(List<Account> accountsToUpdate) {
		List<Account> remainingToUpdate = new List<Account>(accountsToUpdate);
		Integer attemptIndex = 0;
		while (!remainingToUpdate.isEmpty() && attemptIndex < MAX_RETRIES) {
			attemptIndex++;
			Database.SaveResult[] updateResults = Database.update(remainingToUpdate, false);
			List<Account> lockRetryRecords = new List<Account>();
			for (Integer i = 0; i < updateResults.size(); i++) {
				Database.SaveResult sr = updateResults[i];
				Account accountAttempted = remainingToUpdate[i];
				if (!sr.isSuccess()) {
					Boolean hasOnlyLockErrors = true;
					String combinedErrorMessage = '';
					for (Database.Error err : sr.getErrors()) {
						combinedErrorMessage += (combinedErrorMessage == '' ? '' : ' | ') + String.valueOf(err.getStatusCode()) + ': ' + err.getMessage();
						if (err.getStatusCode() != StatusCode.UNABLE_TO_LOCK_ROW) {
							hasOnlyLockErrors = false;
						}
					}
					if (hasOnlyLockErrors && attemptIndex < MAX_RETRIES) {
						lockRetryRecords.add(accountAttempted);
					} else {
						logExceptionForAccount(accountAttempted.Id, combinedErrorMessage);
					}
				}
			}
			remainingToUpdate = lockRetryRecords;
		}
		// After exhausting retries, any remaining records are logged as lock failures
		for (Account acc : remainingToUpdate) {
			logExceptionForAccount(acc.Id, 'UNABLE_TO_LOCK_ROW: Could not update after ' + String.valueOf(MAX_RETRIES) + ' attempts');
		}
	}

	private static void logExceptionForAccount(Id accountId, String errorMessage) {
		try {
			Schema.SObjectType exceptionLogType = Schema.getGlobalDescribe().get('Exception_Log__c');
			if (exceptionLogType == null) {
				return; // Log object not present in org
			}

			Schema.DescribeSObjectResult describeResult = exceptionLogType.getDescribe();
			Map<String, Schema.SObjectField> fieldMap = describeResult.fields.getMap();
			SObject logRecord = exceptionLogType.newSObject();

			if (fieldMap.containsKey('Name')) {
				logRecord.put('Name', 'AccountOwnerReassign ' + String.valueOf(accountId));
			}
			if (fieldMap.containsKey('Record_Id__c')) {
				logRecord.put('Record_Id__c', accountId);
			}
			if (fieldMap.containsKey('Related_Record_Id__c')) {
				logRecord.put('Related_Record_Id__c', accountId);
			}
			if (fieldMap.containsKey('SObject_Type__c')) {
				logRecord.put('SObject_Type__c', 'Account');
			}
			if (fieldMap.containsKey('Context__c')) {
				logRecord.put('Context__c', 'DeactivatedOwnerAccountReassignmentBatch');
			}
			if (fieldMap.containsKey('Error_Message__c')) {
				logRecord.put('Error_Message__c', errorMessage);
			} else if (fieldMap.containsKey('Message__c')) {
				logRecord.put('Message__c', errorMessage);
			}

			Database.insert(logRecord, false);
		} catch (Exception ignore) {
			// Swallow all exceptions during logging; avoid failing the batch due to logging
		}
	}
}

