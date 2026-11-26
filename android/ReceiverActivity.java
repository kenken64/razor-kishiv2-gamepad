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
    private ImageButton qrButton;
    private android.app.AlertDialog qrDialog;
    private String qrPayload;

    private void showQr() {
        if (qrPayload==null) return;
        try {
            int side=Math.min(480,getResources().getDisplayMetrics().heightPixels / 2);
            com.google.zxing.common.BitMatrix bits=new com.google.zxing.qrcode.QRCodeWriter().encode(
                qrPayload,com.google.zxing.BarcodeFormat.QR_CODE,side,side);
            int[] pixels=new int[side*side];
            for (int y=0;y<side;y++) for (int x=0;x<side;x++)
                pixels[y*side+x]=bits.get(x,y)?0xff000000:0xffffffff;
            ImageView image=new ImageView(this);
            image.setImageBitmap(android.graphics.Bitmap.createBitmap(pixels,side,side,android.graphics.Bitmap.Config.ARGB_8888));
            image.setScaleType(ImageView.ScaleType.CENTER);
            image.setMinimumHeight(side);
            image.setContentDescription("Pairing QR code");
            qrDialog=new android.app.AlertDialog.Builder(this).setView(image)
                .setPositiveButton("Close",null).show();
        } catch (com.google.zxing.WriterException e) {
            Toast.makeText(this,"Enter the displayed address and code manually.",Toast.LENGTH_LONG).show();
        }
    }
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
            String payload=service==null?null:"kishi://pair/"+addresses.split("  /  ",2)[0]+"/"+service.pairingCode;
            if (PairingQr.parse(payload)==null) payload=null;
            if (!java.util.Objects.equals(payload,qrPayload) && qrDialog!=null) qrDialog.dismiss();
            qrPayload=payload;
            qrButton.setVisibility(payload==null?android.view.View.GONE:android.view.View.VISIBLE);
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
        details=new TextView(this); details.setTextSize(20); details.setPadding(0,pad,0,pad); LinearLayout pairing=new LinearLayout(this);
        pairing.setGravity(android.view.Gravity.CENTER_VERTICAL);
        pairing.addView(details);
        qrButton=new ImageButton(this);
        qrButton.setContentDescription("Show pairing QR code");
        qrButton.setImageResource(getResources().getIdentifier("ic_pair_qr","drawable",getPackageName()));
        qrButton.setOnClickListener(v -> showQr());
        pairing.addView(qrButton);
        root.addView(pairing);
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
