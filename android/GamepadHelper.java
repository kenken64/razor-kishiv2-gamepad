package net.kishi.bridge;

import java.net.*;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Started by adb as shell. Authenticated loopback clients can only submit fixed-size reports. */
public final class GamepadHelper {
    public static void main(String[] args) throws Exception {
        String key = new BufferedReader(new InputStreamReader(System.in,"US-ASCII")).readLine();
        if (key==null || !key.matches("[A-Za-z0-9_-]{43}")) throw new IOException("Missing helper key");
        try (ServerSocket server = new ServerSocket(HelperLink.PORT,1,InetAddress.getByName("127.0.0.1"))) {
            System.out.println("Gamepad helper ready");
            while (true) {
                try (Socket client = server.accept()) {
                    HelperLink.authenticate(client,key,true);
                    client.setSoTimeout(0);
                    client.setTcpNoDelay(true);
                    serve(client);
                } catch (IOException ex) { System.err.println(ex); }
            }
        }
    }
    static void serve(Socket client) throws IOException {
        // Linux uhid.h accepts short packed events and zero-fills the unused tail.
        try (RandomAccessFile uhid = new RandomAccessFile("/dev/uhid","rw")) {
            ByteBuffer create=ByteBuffer.allocate(280+GamepadReport.DESCRIPTOR.length).order(ByteOrder.nativeOrder());
            create.putInt(11); // UHID_CREATE2
            create.put(GamepadReport.NAME.getBytes("US-ASCII"));
            create.position(260); // event type + name[128], phys[64], uniq[64]
            create.putShort((short)GamepadReport.DESCRIPTOR.length).putShort((short)3); // BUS_USB
            create.putInt(0x1209).putInt(1).putInt(1).putInt(0);
            for (int value: GamepadReport.DESCRIPTOR) create.put((byte)value);
            uhid.write(create.array());
            DataInputStream in=new DataInputStream(client.getInputStream());
            byte[] frame=new byte[12];
            while (true) {
                in.readFully(frame);
                int[] report=GamepadReport.convert(frame);
                ByteBuffer input=ByteBuffer.allocate(6+report.length).order(ByteOrder.nativeOrder());
                input.putInt(12).putShort((short)report.length); // UHID_INPUT2
                for (int value: report) input.put((byte)value);
                uhid.write(input.array());
                client.getOutputStream().write(65);
            }
        }
    }
}
