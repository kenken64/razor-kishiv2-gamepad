package net.kishi.bridge;

import android.app.*;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.view.InputDevice;
import java.io.*;
import java.net.*;
import java.security.SecureRandom;
import java.util.Locale;

public class ReceiverService extends Service {
    static volatile ReceiverService active;
    static volatile String lastStatus = "Ready to start";
    volatile String status = "Starting receiver…", pairingCode = "";
    private final Socket helper = new Socket();
    private ServerSocket listener;
    private Socket client;
    private boolean closing;

    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public void onCreate() {
        super.onCreate();
        active=this;
        Notification.Builder notice;
        if (Build.VERSION.SDK_INT>=26) {
            String channel="gamepad_receiver";
            getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(channel,"Gamepad receiver",NotificationManager.IMPORTANCE_LOW));
            notice=new Notification.Builder(this,channel);
        } else notice=new Notification.Builder(this);
        PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,ReceiverActivity.class),
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        startForeground(1,notice.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("PadRelay receiver").setContentText("Tap to view pairing details or stop receiving.")
            .setOngoing(true).setContentIntent(open).build());
        new Thread(this::runReceiver,"PadRelay receiver").start();
    }
    @Override public int onStartCommand(Intent intent,int flags,int id) { return START_NOT_STICKY; }
    private boolean hasGamepad() {
        for (int id : InputDevice.getDeviceIds()) {
            InputDevice device=InputDevice.getDevice(id);
            if (device!=null && GamepadReport.NAME.equals(device.getName())
                    && device.supportsSource(InputDevice.SOURCE_GAMEPAD)) return true;
        }
        return false;
    }
    private void apply(byte[] frame) throws IOException {
        helper.getOutputStream().write(frame);
        if (helper.getInputStream().read()!=65) throw new EOFException("Helper disconnected");
    }
    private void runReceiver() {
        try {
            try {
                helper.connect(new InetSocketAddress("127.0.0.1",HelperLink.PORT),2000);
                helper.setTcpNoDelay(true);
                HelperLink.authenticate(helper,HelperSetup.key(this),false);
            } catch (IOException e) { throw new IOException("Enable the gamepad helper over USB, then start again."); }
            helper.setSoTimeout(2000);
            for (int i=0; i<50 && !hasGamepad(); i++) Thread.sleep(100);
            if (!hasGamepad()) throw new IOException("Android did not register the gamepad. Check the helper log.");
            apply(new byte[12]);
            try (ServerSocket server=new ServerSocket()) {
                synchronized (this) {
                    if (closing) return;
                    listener=server;
                    server.setReuseAddress(true);
                    server.bind(new InetSocketAddress(26760));
                }
                pairingCode=String.format(Locale.US,"%06d",new SecureRandom().nextInt(1000000));
                while (true) {
                    status="Waiting for sender";
                    try (Socket peer=server.accept()) {
                        synchronized(this) { if (closing) return; client=peer; }
                        try {
                            ReceiverProtocol.receive(peer,pairingCode,this::apply,
                                () -> status="Receiving from "+peer.getInetAddress().getHostAddress());
                        } catch (IOException e) {
                            // A dead sender is recoverable. A failed helper must surface in the UI.
                            apply(new byte[12]);
                        } finally { synchronized(this) { client=null; } }
                    }
                }
            }
        } catch (Exception e) {
            synchronized(this) { if (!closing) lastStatus="Receiver stopped. "+e.getMessage(); }
        } finally {
            try { helper.close(); } catch(IOException ignored) {}
            stopSelf();
        }
    }
    @Override public synchronized void onDestroy() {
        closing=true;
        try { if(listener!=null) listener.close(); } catch(IOException ignored) {}
        try { if(client!=null) client.close(); } catch(IOException ignored) {}
        try { helper.close(); } catch(IOException ignored) {}
        active=null;
        super.onDestroy();
    }
}
