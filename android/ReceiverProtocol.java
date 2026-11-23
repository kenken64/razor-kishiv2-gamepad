package net.kishi.bridge;

import java.io.*;
import java.net.Socket;
import java.util.Arrays;

final class ReceiverProtocol {
    interface Output { void apply(byte[] frame) throws IOException; }
    static void receive(Socket peer, String pin, Output gamepad, Runnable connected) throws IOException {
        peer.setTcpNoDelay(true);
        peer.setSoTimeout(2000);
        DataInputStream in = new DataInputStream(peer.getInputStream());
        byte[] hello = new byte[10];
        in.readFully(hello);
        if (!Arrays.equals(hello, ("KSH1"+pin).getBytes("US-ASCII"))) return;
        OutputStream reply = peer.getOutputStream();
        reply.write(new byte[]{79,75,82});
        connected.run();
        peer.setSoTimeout(900);
        byte[] frame = new byte[12];
        try {
            while (true) {
                in.readFully(frame);
                gamepad.apply(frame);
                if ((frame[0] & 8)!=0) reply.write(65);
            }
        } finally { gamepad.apply(new byte[12]); }
    }
}
