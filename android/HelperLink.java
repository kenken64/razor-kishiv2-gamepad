package net.kishi.bridge;

import java.io.*;
import java.net.*;
import java.security.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

final class HelperLink {
    static final int PORT=26761;
    // Both peers prove possession of the per-install key without transmitting it over loopback.
    static void authenticate(Socket socket,String key,boolean server) throws IOException {
        socket.setSoTimeout(2000);
        DataInputStream in=new DataInputStream(socket.getInputStream());
        OutputStream out=socket.getOutputStream();
        byte[] mine=new byte[32], theirs=new byte[32], proof=new byte[32];
        new SecureRandom().nextBytes(mine);
        out.write(mine); in.readFully(theirs);
        try {
            Mac mac=Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key.getBytes("US-ASCII"),"HmacSHA256"));
            mac.update((byte)(server?1:0)); mac.update(theirs); out.write(mac.doFinal(mine));
            in.readFully(proof);
            mac.update((byte)(server?0:1)); mac.update(mine);
            if (!MessageDigest.isEqual(proof,mac.doFinal(theirs))) throw new IOException("Helper identity mismatch");
        } catch (GeneralSecurityException e) { throw new IOException(e); }
    }
}
