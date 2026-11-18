package mead.server;

import android.accounts.Account;
import android.accounts.AccountManager;
import android.accounts.AuthenticatorDescription;
import android.accounts.IAccountManagerResponse;
import android.os.Bundle;
import android.os.RemoteException;
import java.util.HashMap;
import java.util.Map;
import mead.server.base.AccountManagerBase;

/**
 * Android's account manager for Mead: the device has no accounts and no
 * authenticators, as a phone that hasn't signed in to anything. Queries
 * answer with none, and what would need an authenticator fails as Android's
 * does when it finds none for the account's type. Apps that ask for the
 * service and don't check for null (YouTube) need it to exist.
 */
final class AccountManagerService extends AccountManagerBase {
    private static final Account[] NO_ACCOUNTS = new Account[0];

    @Override public AuthenticatorDescription[] getAuthenticatorTypes(int userId) {
        return new AuthenticatorDescription[0];
    }

    @Override public Account[] getAccounts(String accountType, String opPackageName) { return NO_ACCOUNTS; }

    @Override public Account[] getAccountsForPackage(String packageName, int uid, String opPackageName) {
        return NO_ACCOUNTS;
    }

    @Override public Account[] getAccountsByTypeForPackage(String type, String packageName,
            String opPackageName) {
        return NO_ACCOUNTS;
    }

    @Override public Account[] getAccountsAsUser(String accountType, int userId, String opPackageName) {
        return NO_ACCOUNTS;
    }

    @Override public Account[] getSharedAccountsAsUser(int userId) { return NO_ACCOUNTS; }

    @Override public Map getAccountsAndVisibilityForPackage(String packageName, String accountType) {
        return new HashMap<Account, Integer>();
    }

    @Override public int getAccountVisibility(Account account, String packageName) {
        return AccountManager.VISIBILITY_NOT_VISIBLE;
    }

    @Override public void getAccountsByFeatures(IAccountManagerResponse response, String accountType,
            String[] features, String opPackageName) throws RemoteException {
        Bundle result = new Bundle();
        result.putParcelableArray(AccountManager.KEY_ACCOUNTS, NO_ACCOUNTS);
        response.onResult(result);
    }

    @Override public void getAccountByTypeAndFeatures(IAccountManagerResponse response, String accountType,
            String[] features, String opPackageName) throws RemoteException {
        // No account name or type in the result: none matched.
        response.onResult(new Bundle());
    }

    @Override public void hasFeatures(IAccountManagerResponse response, Account account, String[] features,
            String opPackageName) throws RemoteException {
        noAuthenticator(response, account.type);
    }

    @Override public void getAuthToken(IAccountManagerResponse response, Account account, String authTokenType,
            boolean notifyOnAuthFailure, boolean expectActivityLaunch, Bundle options) throws RemoteException {
        noAuthenticator(response, account.type);
    }

    @Override public void addAccount(IAccountManagerResponse response, String accountType, String authTokenType,
            String[] requiredFeatures, boolean expectActivityLaunch, Bundle options) throws RemoteException {
        noAuthenticator(response, accountType);
    }

    @Override public void addAccountAsUser(IAccountManagerResponse response, String accountType,
            String authTokenType, String[] requiredFeatures, boolean expectActivityLaunch, Bundle options,
            int userId) throws RemoteException {
        noAuthenticator(response, accountType);
    }

    @Override public void removeAccount(IAccountManagerResponse response, Account account,
            boolean expectActivityLaunch) throws RemoteException {
        noAuthenticator(response, account.type);
    }

    private static void noAuthenticator(IAccountManagerResponse response, String type) throws RemoteException {
        if (response != null) {
            response.onError(AccountManager.ERROR_CODE_UNSUPPORTED_OPERATION, "no authenticator for " + type);
        }
    }
}
