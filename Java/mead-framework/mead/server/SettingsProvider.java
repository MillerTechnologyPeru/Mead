package mead.server;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import java.util.HashMap;
import java.util.Map;

/**
 * Android's settings provider for Mead: the system, secure and global
 * tables Settings reads and writes, through call() as Settings does, kept
 * in memory for now. Settings without a value read as their callers'
 * defaults.
 */
final class SettingsProvider extends ContentProvider {
    static final String AUTHORITY = Settings.AUTHORITY;

    private final Map<String, Map<String, String>> mTables = new HashMap<>();

    @Override
    public boolean onCreate() {
        return true;
    }

    private Map<String, String> table(String name) {
        synchronized (mTables) {
            Map<String, String> table = mTables.get(name);
            if (table == null) {
                table = new HashMap<>();
                mTables.put(name, table);
            }
            return table;
        }
    }

    /** GET_<table>, PUT_<table> and DELETE_<table>, as Settings calls them. */
    @Override
    public Bundle call(String method, String name, Bundle extras) {
        int separator = method.indexOf('_');
        if (separator < 0 || name == null) return null;
        String operation = method.substring(0, separator);
        Map<String, String> table = table(method.substring(separator + 1));
        synchronized (table) {
            switch (operation) {
                case "GET": {
                    Bundle result = new Bundle();
                    result.putString(Settings.NameValueTable.VALUE, table.get(name));
                    return result;
                }
                case "PUT":
                    table.put(name, extras != null ? extras.getString(Settings.NameValueTable.VALUE) : null);
                    return new Bundle();
                case "DELETE": {
                    Bundle result = new Bundle();
                    result.putInt("result", table.remove(name) != null ? 1 : 0);
                    return result;
                }
                default:
                    return null;
            }
        }
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        return new MatrixCursor(new String[] {Settings.NameValueTable.NAME, Settings.NameValueTable.VALUE});
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
