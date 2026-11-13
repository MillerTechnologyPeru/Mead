package mead.server;

import android.content.pm.UserInfo;
import android.os.Bundle;
import android.os.UserHandle;
import java.util.Collections;
import java.util.List;
import mead.server.base.UserManagerBase;

/** Android's user manager for Mead: one user, the owner, running and unlocked, without restrictions. */
final class UserManagerService extends UserManagerBase {
    private static UserInfo owner() {
        return new UserInfo(UserHandle.USER_SYSTEM, "Owner",
                UserInfo.FLAG_PRIMARY | UserInfo.FLAG_ADMIN | UserInfo.FLAG_INITIALIZED);
    }

    private static boolean isOwner(int userId) {
        return userId == UserHandle.USER_SYSTEM;
    }

    @Override public UserInfo getPrimaryUser() { return owner(); }
    @Override public List<UserInfo> getUsers(boolean excludeDying) { return Collections.singletonList(owner()); }
    @Override public List<UserInfo> getProfiles(int userId, boolean enabledOnly) {
        return isOwner(userId) ? Collections.singletonList(owner()) : Collections.<UserInfo>emptyList();
    }
    @Override public UserInfo getProfileParent(int userId) { return null; }
    @Override public UserInfo getUserInfo(int userId) { return isOwner(userId) ? owner() : null; }
    @Override public String getUserAccount(int userId) { return null; }
    @Override public boolean isRestricted() { return false; }
    @Override public int getUserSerialNumber(int userId) { return isOwner(userId) ? 0 : -1; }
    @Override public int getUserHandle(int userSerialNumber) { return userSerialNumber == 0 ? UserHandle.USER_SYSTEM : -1; }
    @Override public Bundle getUserRestrictions(int userId) { return new Bundle(); }
    @Override public boolean hasUserRestriction(String restrictionKey, int userId) { return false; }
    @Override public Bundle getApplicationRestrictions(String packageName) { return new Bundle(); }
    @Override public boolean isManagedProfile(int userId) { return false; }
    @Override public boolean isDemoUser(int userId) { return false; }
    @Override public boolean isUserUnlockingOrUnlocked(int userId) { return isOwner(userId); }
    @Override public boolean isUserUnlocked(int userId) { return isOwner(userId); }
    @Override public boolean isUserRunning(int userId) { return isOwner(userId); }
    @Override public boolean isUserNameSet(int userId) { return true; }
}
