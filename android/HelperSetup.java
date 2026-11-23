package net.kishi.bridge;

import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import java.security.SecureRandom;
import android.util.Base64;

/** The manifest restricts external calls to holders of the system DUMP permission (adb shell). */
public class HelperSetup extends ContentProvider {
    public boolean onCreate() { return true; }
    static synchronized String key(Context ctx) {
        SharedPreferences prefs=ctx.getSharedPreferences("receiver_helper",Context.MODE_PRIVATE);
        String value=prefs.getString("key",null);
        if (value==null) {
            byte[] bytes=new byte[32]; new SecureRandom().nextBytes(bytes);
            value=Base64.encodeToString(bytes,Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING);
            if (!prefs.edit().putString("key",value).commit()) throw new IllegalStateException("Cannot store helper key");
        }
        return value;
    }
    @Override public Bundle call(String method,String arg,Bundle extra) {
        if (!"setup".equals(method)) throw new IllegalArgumentException();
        getContext().enforceCallingPermission("android.permission.DUMP","ADB setup required");
        Bundle result=new Bundle(); result.putString("key",key(getContext())); return result;
    }
    public Cursor query(Uri u,String[] p,String s,String[] a,String o){throw new UnsupportedOperationException();}
    public String getType(Uri u){return null;}
    public Uri insert(Uri u,ContentValues v){throw new UnsupportedOperationException();}
    public int delete(Uri u,String s,String[] a){throw new UnsupportedOperationException();}
    public int update(Uri u,ContentValues v,String s,String[] a){throw new UnsupportedOperationException();}
}
