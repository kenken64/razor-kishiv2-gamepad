package net.kishi.bridge;

import android.app.Activity;
import android.content.Intent;
import android.os.*;
import android.widget.*;
import java.net.*;
import java.util.*;

public class ReceiverActivity extends Activity {
    private final Handler handler=new Handler(Looper.getMainLooper());
    private TextView state,details;
    private Button toggle;
    private String addresses;
    private String addresses() {
        ArrayList<String> list=new ArrayList<>();
        try {
            for (NetworkInterface net: Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!net.isUp() || net.isLoopback()) continue;
                for (InetAddress ip: Collections.list(net.getInetAddresses()))
                    if (ip instanceof Inet4Address && ip.isSiteLocalAddress()) list.add(ip.getHostAddress());
            }
        } catch (SocketException ignored) {}
        return list.isEmpty()?"Connect the Pixel to the sender’s Wi-Fi":android.text.TextUtils.join("  /  ",list);
    }
    private final Runnable refresh=new Runnable() {
        public void run() {
            ReceiverService service=ReceiverService.active;
            toggle.setText(service==null?"Start receiver":"Stop receiver");
            state.setText(service==null?ReceiverService.lastStatus:service.status);
            details.setText(service!=null && !service.pairingCode.isEmpty()
                ? "Receiver address   "+addresses+"\nPairing code   "+service.pairingCode
                : "Use Enable-PixelReceiver.ps1 over USB to enable the gamepad helper after each restart.");
            handler.postDelayed(this,500);
        }
    };
    public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN
            | android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        setTitle("Gamepad receiver");
        ScrollView scroll=new ScrollView(this);
        LinearLayout root=new LinearLayout(this); root.setOrientation(1);
        int pad=Math.round(24*getResources().getDisplayMetrics().density);
        root.setPadding(pad,pad,pad,pad); scroll.addView(root);
        TextView title=new TextView(this); title.setText("Gamepad receiver"); title.setTextSize(28); root.addView(title);
        state=new TextView(this); state.setTextSize(18); root.addView(state);
        details=new TextView(this); details.setTextSize(20); details.setPadding(0,pad,0,pad); root.addView(details);
        toggle=new Button(this); toggle.setOnClickListener(v -> {
            Intent intent=new Intent(this,ReceiverService.class);
            if (ReceiverService.active!=null) {
                ReceiverService.lastStatus="Stopped"; stopService(intent);
            } else {
                ReceiverService.lastStatus="Starting receiver";
                if (Build.VERSION.SDK_INT>=26) startForegroundService(intent); else startService(intent);
            }
        });
        root.addView(toggle);
        TextView hint=new TextView(this); hint.setText("Pair from the Kishi phone, then open a controller-compatible game on this device."); root.addView(hint);
        setContentView(scroll);
    }
    protected void onResume(){ super.onResume(); addresses=addresses(); refresh.run(); }
    protected void onPause(){ handler.removeCallbacks(refresh); super.onPause(); }
}
